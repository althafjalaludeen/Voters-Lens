"""Tests for offline-only search indexing, query execution, and field status filtering."""

import socket
import pytest
from voterlens.database.database import DatabaseManager
from voterlens.database.models import FieldStatusType, RollVersionStatus
from voterlens.database.repository import (
    ElectoralRollRepository,
    FieldStatusRepository,
    VoterRepository,
)


@pytest.fixture
def populated_offline_db(file_db: DatabaseManager):
    """Populate database with synthetic voter records across diverse languages."""
    with file_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Final Roll 2026",
        )
        roll_id = roll.id

        records = [
            {
                "serial_number": 1,
                "epic_number": "KLM1092831",
                "name": "സുരേഷ് കുമാർ",
                "normalized_name": "സുരേഷ് കുമാർ",
                "relative_name": "വാസുദേവൻ",
                "normalized_relative_name": "വാസുദേവൻ",
                "relative_type": "FATHER",
                "house_number": "12/45A",
                "normalized_house_number": "12/45A",
                "age": 42,
                "gender": "M",
                "part_number": "42",
            },
            {
                "serial_number": 2,
                "epic_number": "KLM1092832",
                "name": "ഫാത്തിമ ബീവി",
                "normalized_name": "ഫാത്തിമ ബീവി",
                "relative_name": "അബ്ദുൾ റഹ്മാൻ",
                "normalized_relative_name": "അബ്ദുൾ റഹ്മാൻ",
                "relative_type": "HUSBAND",
                "house_number": "14/102",
                "normalized_house_number": "14/102",
                "age": 38,
                "gender": "F",
                "part_number": "42",
            },
            {
                "serial_number": 3,
                "epic_number": "KLM1092833",
                "name": "GEORGE THOMAS",
                "normalized_name": "GEORGE THOMAS",
                "relative_name": "THOMAS JOSEPH",
                "normalized_relative_name": "THOMAS JOSEPH",
                "relative_type": "FATHER",
                "house_number": "18/90",
                "normalized_house_number": "18/90",
                "age": 55,
                "gender": "M",
                "part_number": "42",
            },
        ]
        voter_repo.insert_voters_batch(roll_id, records)
        roll_repo.activate_roll(roll_id)

    return file_db, roll_id


def test_offline_search_without_network(populated_offline_db, monkeypatch):
    """Demonstrate searching executes completely offline with socket network blocked."""
    file_db, roll_id = populated_offline_db

    # Strict network prohibition: mock socket to raise exception if any network call is attempted
    def block_network(*args, **kwargs):
        raise RuntimeError("Network access attempted during offline search!")

    monkeypatch.setattr(socket, "socket", block_network)

    # Perform search queries using local SQLite
    with file_db.session() as session:
        voter_repo = VoterRepository(session)

        # 1. Search by Malayalam name
        results = voter_repo.search_voters(roll_version_id=roll_id, name="സുരേഷ്")
        assert len(results) == 1
        assert results[0].epic_number == "KLM1092831"

        # 2. Search by English name
        results_eng = voter_repo.search_voters(roll_version_id=roll_id, name="george")
        assert len(results_eng) == 1
        assert results_eng[0].epic_number == "KLM1092833"

        # 3. Search by EPIC prefix
        results_epic = voter_repo.search_voters(roll_version_id=roll_id, epic="KLM1092832")
        assert len(results_epic) == 1
        assert results_epic[0].name == "ഫാത്തിമ ബീവി"

        # 4. Search by House Number
        results_house = voter_repo.search_voters(roll_version_id=roll_id, house_number="18/90")
        assert len(results_house) == 1
        assert results_house[0].name == "GEORGE THOMAS"


def test_search_with_field_status_filters(populated_offline_db):
    """Verify searching and filtering by field-verification statuses."""
    file_db, roll_id = populated_offline_db

    with file_db.session() as session:
        voter_repo = VoterRepository(session)
        field_repo = FieldStatusRepository(session)

        voter_fatima = voter_repo.get_voter_by_epic("KLM1092832", roll_version_id=roll_id)[0]
        # Mark Fatima as AWAY
        field_repo.set_status(
            voter_id=voter_fatima.id,
            new_status=FieldStatusType.AWAY,
            notes="Relocated temporarily",
        )

        voter_george = voter_repo.get_voter_by_epic("KLM1092833", roll_version_id=roll_id)[0]
        # Mark George as REPORTED_DECEASED
        field_repo.set_status(
            voter_id=voter_george.id,
            new_status=FieldStatusType.REPORTED_DECEASED,
            notes="Passed away in 2025",
        )

    with file_db.session() as session:
        voter_repo = VoterRepository(session)

        # Filter by AWAY
        away_voters = voter_repo.search_voters(
            roll_version_id=roll_id, field_status=FieldStatusType.AWAY
        )
        assert len(away_voters) == 1
        assert away_voters[0].epic_number == "KLM1092832"

        # Filter by REPORTED_DECEASED
        deceased_voters = voter_repo.search_voters(
            roll_version_id=roll_id, field_status=FieldStatusType.REPORTED_DECEASED
        )
        assert len(deceased_voters) == 1
        assert deceased_voters[0].epic_number == "KLM1092833"
        # CRITICAL: Official record is NOT modified or deleted
        assert deceased_voters[0].name == "GEORGE THOMAS"

        # Filter by default NO_ISSUE
        no_issue_voters = voter_repo.search_voters(
            roll_version_id=roll_id, field_status=FieldStatusType.NO_ISSUE
        )
        assert len(no_issue_voters) == 1
        assert no_issue_voters[0].epic_number == "KLM1092831"

"""Tests for database models, repositories, and immutability guarantees."""

import pytest
from voterlens.database.database import DatabaseManager
from voterlens.database.models import FieldStatusType, RollVersionStatus
from voterlens.database.repository import (
    ElectoralRollRepository,
    FieldStatusRepository,
    ImmutableElectoralRollError,
    VoterRepository,
)


def test_database_creation(in_memory_db: DatabaseManager):
    """Verify that tables are created without errors."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        active_roll = roll_repo.get_active_roll("Kerala", "Pathanamthitta", "112 - Thiruvalla")
        assert active_roll is None


def test_roll_creation_and_activation(in_memory_db: DatabaseManager):
    """Verify roll lifecycle: IMPORTING -> ACTIVE, archiving previous active roll."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        # 1. Create first roll
        roll1 = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Draft Roll 2026",
            roll_type="GENERAL",
        )
        assert roll1.status == RollVersionStatus.IMPORTING
        roll1_id = roll1.id

        # 2. Activate first roll
        roll_repo.activate_roll(roll1_id)
        assert roll1.status == RollVersionStatus.ACTIVE

    # 3. Create second roll for the same area
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        roll2 = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Final Roll 2026",
            roll_type="GENERAL",
        )
        roll2_id = roll2.id
        roll_repo.activate_roll(roll2_id)

    # 4. Verify roll1 is now ARCHIVED and roll2 is ACTIVE
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        active = roll_repo.get_active_roll("Kerala", "Pathanamthitta", "112 - Thiruvalla")
        assert active is not None
        assert active.id == roll2_id
        assert active.status == RollVersionStatus.ACTIVE

        r1 = roll_repo.get_roll_by_id(roll1_id)
        assert r1.status == RollVersionStatus.ARCHIVED


def test_voter_insertion_and_immutability(in_memory_db: DatabaseManager):
    """Verify voter insertion during IMPORTING and immutability lock once ACTIVE."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Roll 2026",
        )
        roll_id = roll.id

        records = [
            {
                "serial_number": 1,
                "epic_number": "KLM1092831",
                "name": "സുരേഷ് കുമാർ",
                "normalized_name": "സുരേഷ് കുമാർ",
                "relative_name": "വാസുദേവൻ",
                "relative_type": "FATHER",
                "house_number": "12/45A",
                "age": 42,
                "gender": "M",
                "part_number": "42",
            }
        ]
        inserted = voter_repo.insert_voters_batch(roll_id, records)
        assert inserted == 1

        # Activate roll
        roll_repo.activate_roll(roll_id)

    with in_memory_db.session() as session:
        voter_repo = VoterRepository(session)
        voters = voter_repo.get_voter_by_epic("KLM1092831")
        assert len(voters) == 1
        voter = voters[0]
        assert voter.name == "സുരേഷ് കുമാർ"

        # Attempt to insert into ACTIVE roll must fail
        with pytest.raises(ImmutableElectoralRollError):
            voter_repo.insert_voters_batch(roll_id, records)

        # Disallowed mutation methods must raise error
        with pytest.raises(ImmutableElectoralRollError):
            voter_repo.update_voter_disallowed(voter.id)

        with pytest.raises(ImmutableElectoralRollError):
            voter_repo.delete_voter_disallowed(voter.id)


def test_field_status_and_audit_history(in_memory_db: DatabaseManager):
    """Verify field status changes create audit trail and never modify the voter record."""
    voter_id = None
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Test Roll",
        )
        records = [
            {
                "serial_number": 1,
                "epic_number": "KLM1092831",
                "name": "ഫാത്തിമ ബീവി",
                "age": 38,
                "gender": "F",
                "part_number": "42",
            }
        ]
        voter_repo.insert_voters_batch(roll.id, records)
        roll_repo.activate_roll(roll.id)

        voter = voter_repo.get_voter_by_epic("KLM1092831")[0]
        voter_id = voter.id

    # 1. Default status should be NO_ISSUE
    with in_memory_db.session() as session:
        field_repo = FieldStatusRepository(session)
        assert field_repo.get_status(voter_id) == FieldStatusType.NO_ISSUE

    # 2. Change 1: NO_ISSUE -> AWAY
    with in_memory_db.session() as session:
        field_repo = FieldStatusRepository(session)
        field_repo.set_status(
            voter_id=voter_id,
            new_status=FieldStatusType.AWAY,
            notes="Working in Bengaluru",
            reported_by="FieldWorker_1",
        )

    # 3. Change 2: AWAY -> REPORTED_DECEASED
    with in_memory_db.session() as session:
        field_repo = FieldStatusRepository(session)
        field_repo.set_status(
            voter_id=voter_id,
            new_status=FieldStatusType.REPORTED_DECEASED,
            notes="Reported deceased by neighbor",
            reported_by="Supervisor_A",
        )

    # 4. Verify history and voter integrity
    with in_memory_db.session() as session:
        field_repo = FieldStatusRepository(session)
        voter_repo = VoterRepository(session)

        current_status = field_repo.get_status(voter_id)
        assert current_status == FieldStatusType.REPORTED_DECEASED

        history = field_repo.get_history(voter_id)
        assert len(history) == 2
        assert history[0].old_status == "NO_ISSUE"
        assert history[0].new_status == "AWAY"
        assert history[1].old_status == "AWAY"
        assert history[1].new_status == "REPORTED_DECEASED"

        # Official voter record must remain intact and NOT deleted
        voter = voter_repo.get_voter_by_id(voter_id)
        assert voter is not None
        assert voter.name == "ഫാത്തിമ ബീവി"
        assert voter.epic_number == "KLM1092831"


def test_failed_import_safety(in_memory_db: DatabaseManager):
    """Verify that a failed import does not overwrite or impact the ACTIVE roll."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        active_roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Final Roll 2026",
        )
        active_id = active_roll.id
        roll_repo.activate_roll(active_id)

    # Attempt a new import that fails
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        bad_roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Corrupt Roll",
        )
        bad_id = bad_roll.id
        # Mark failed
        roll_repo.mark_roll_failed(bad_id)

    # Verify active roll remains untouched
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        current_active = roll_repo.get_active_roll("Kerala", "Pathanamthitta", "112 - Thiruvalla")
        assert current_active is not None
        assert current_active.id == active_id
        assert current_active.status == RollVersionStatus.ACTIVE

        bad_roll = roll_repo.get_roll_by_id(bad_id)
        assert bad_roll.status == RollVersionStatus.FAILED

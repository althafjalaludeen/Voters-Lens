"""Offline-First Guarantee tests: Enforces zero network/socket usage during normal operations."""

import socket
import pytest

from voterlens.database.database import DatabaseManager
from voterlens.database.models import FieldStatusType, ReviewStatusType
from voterlens.database.repository import ElectoralRollRepository, VoterRepository
from voterlens.dto.filter_dto import FieldStatusFilter, GenderFilter, SearchCriteria
from voterlens.services.field_service import FieldStatusService
from voterlens.services.review_service import ReviewService
from voterlens.services.roll_service import RollService
from voterlens.services.search_service import SearchService
from voterlens.services.security import SecurityContext
from voterlens.services.voter_service import VoterService


@pytest.fixture
def offline_rigorous_db(file_db: DatabaseManager):
    """Populate persistent SQLite database for offline operations testing."""
    with file_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Strictly Offline Roll 2026",
            checksum_hash="sha256_mock_offline_hash",
        )
        roll_id = roll.id

        records = [
            {
                "serial_number": 1,
                "epic_number": "OFF1001",
                "name": "രാജേഷ്",
                "normalized_name": "രാജേഷ്",
                "relative_name": "വേലായുധൻ",
                "normalized_relative_name": "വേലായുധൻ",
                "house_number": "100",
                "normalized_house_number": "100",
                "age": 45,
                "gender": "M",
                "part_number": "1",
            },
            {
                "serial_number": 2,
                "epic_number": "OFF1002",
                "name": "പ്രിയ",
                "normalized_name": "പ്രിയ",
                "relative_name": "രാജേഷ്",
                "normalized_relative_name": "രാജേഷ്",
                "house_number": "100",
                "normalized_house_number": "100",
                "age": 40,
                "gender": "F",
                "part_number": "1",
            },
        ]
        voter_repo.insert_voters_batch(roll_id, records)
        roll_repo.activate_roll(roll_id)

    return file_db, roll_id


def test_zero_network_all_operations(offline_rigorous_db, monkeypatch):
    """Enforce that every normal application operation runs without socket/network access."""
    file_db, roll_id = offline_rigorous_db

    # Strict network prohibition: intercept socket creation
    def forbidden_socket(*args, **kwargs):
        raise RuntimeError("CRITICAL ERROR: Network access attempted during normal offline operation!")

    monkeypatch.setattr(socket, "socket", forbidden_socket)

    with file_db.session() as session:
        admin_ctx = SecurityContext.admin()
        roll_svc = RollService(session)
        voter_svc = VoterService(session)
        search_svc = SearchService(session)
        field_svc = FieldStatusService(session)
        review_svc = ReviewService(session)

        # 1. Area configuration & Roll retrieval
        cfg = roll_svc.setup_electoral_area(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            context=admin_ctx,
        )
        assert cfg.state == "Kerala"
        active_roll = roll_svc.get_active_roll()
        assert active_roll is not None
        assert active_roll.id == roll_id

        # 2. Full Voter List retrieval
        voter_list = voter_svc.get_voters(roll_id, page=1, page_size=10)
        assert voter_list.total_count == 2
        v1_id = voter_list.items[0].voter_id

        # 3. Multi-criteria search (EPIC, Malayalam Name, House, Gender)
        search_res = search_svc.search(
            roll_id,
            SearchCriteria(
                name="രാജേഷ്",
                epic="OFF1001",
                gender=GenderFilter.MALE,
            ),
        )
        assert search_res.total_count == 1
        assert search_res.items[0].name == "രാജേഷ്"

        # 4. Household grouping view
        houses, total_h = voter_svc.get_household_groups(roll_id)
        assert total_h == 1
        assert houses[0].voter_count == 2

        # 5. Voter detail retrieval (clean official vs field split)
        detail = voter_svc.get_voter(v1_id)
        assert detail.official.name == "രാജേഷ്"
        assert detail.official.photo_available is False  # Offline check detects missing file cleanly

        # 6. Field status observation & audit history
        field_svc.set_status(v1_id, FieldStatusType.AWAY, notes="Working in Kochi", context=admin_ctx)
        history = field_svc.get_history(v1_id)
        assert len(history) == 1
        assert history[0].new_status == "AWAY"

        # 7. Area statistics
        stats = voter_svc.get_area_statistics(roll_id)
        assert stats.total_voters == 2
        assert stats.field_status_counts["AWAY"] == 1

        # 8. Review queue
        review_svc.auto_flag_roll_anomalies(roll_id)
        review_svc.get_review_queue(roll_id)

    # All operations completed with socket network strictly blocked!

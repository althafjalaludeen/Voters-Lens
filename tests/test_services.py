"""Tests for Phase 2 service layer: RollService, FieldStatusService, ReviewService, and Security."""

import pytest
from voterlens.database.database import DatabaseManager
from voterlens.database.models import FieldStatusType, ReviewStatusType, RollVersionStatus, UserRole
from voterlens.database.repository import ElectoralRollRepository, VoterRepository
from voterlens.dto.filter_dto import FieldStatusFilter, ReviewStatusFilter, SearchCriteria
from voterlens.services.field_service import FieldStatusService
from voterlens.services.review_service import ReviewService
from voterlens.services.roll_service import RollService
from voterlens.services.search_service import SearchService
from voterlens.services.security import Permission, PermissionDeniedError, SecurityContext
from voterlens.services.voter_service import VoterService


@pytest.fixture
def service_test_db(in_memory_db: DatabaseManager):
    """Populate database with synthetic voter records across diverse languages."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Final Roll 2026",
            checksum_hash="test_sha256_hash",
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
                "polling_station_name": "St. Marys HSS",
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
                "polling_station_name": "St. Marys HSS",
            },
            {
                "serial_number": 3,
                "epic_number": "KLM1092833",
                "name": "GEORGE THOMAS",
                "normalized_name": "GEORGE THOMAS",
                "relative_name": "THOMAS JOSEPH",
                "normalized_relative_name": "THOMAS JOSEPH",
                "relative_type": "FATHER",
                "house_number": "12/45A",  # Same house as voter 1
                "normalized_house_number": "12/45A",
                "age": 55,
                "gender": "M",
                "part_number": "42",
                "polling_station_name": "St. Marys HSS",
            },
            {
                "serial_number": 4,
                "epic_number": "UNKNOWN",  # Missing EPIC anomaly
                "name": "അനിത",
                "normalized_name": "അനിത",
                "relative_name": "",  # Missing relative anomaly
                "normalized_relative_name": "",
                "relative_type": "OTHER",
                "house_number": "",  # Missing house anomaly
                "normalized_house_number": "",
                "age": 0,  # Invalid age anomaly
                "gender": "F",
                "part_number": "42",
                "polling_station_name": "St. Marys HSS",
            },
        ]
        voter_repo.insert_voters_batch(roll_id, records)
        roll_repo.activate_roll(roll_id)

    return in_memory_db, roll_id


def test_area_configuration_and_active_roll(service_test_db):
    """Verify electoral area configuration setup and retrieval."""
    db, roll_id = service_test_db
    with db.session() as session:
        roll_svc = RollService(session)
        admin_ctx = SecurityContext.admin()

        # Setup area configuration
        cfg = roll_svc.setup_electoral_area(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            selected_part_number="42",
            context=admin_ctx,
        )
        assert cfg.state == "Kerala"
        assert cfg.district == "Pathanamthitta"
        assert cfg.assembly_constituency == "112 - Thiruvalla"
        assert cfg.selected_part_number == "42"

        # Retrieve active roll
        active_roll = roll_svc.get_active_roll()
        assert active_roll is not None
        assert active_roll.id == roll_id
        assert active_roll.status == "ACTIVE"


def test_field_status_transitions_and_history(service_test_db):
    """Verify field status transitions: NO_ISSUE -> AWAY -> ABROAD -> NO_ISSUE and immutability."""
    db, roll_id = service_test_db
    field_ctx = SecurityContext.field_user("worker_1")

    with db.session() as session:
        voter_svc = VoterService(session)
        field_svc = FieldStatusService(session)

        # Get voter 1
        voters = voter_svc.get_voters(roll_id, page=1, page_size=10).items
        v1_id = voters[0].voter_id

        # 1. Initial state is NO_ISSUE
        info = field_svc.get_field_info(v1_id)
        assert info.status == "NO_ISSUE"

        # 2. Transition to AWAY
        info_away = field_svc.set_status(v1_id, FieldStatusType.AWAY, notes="Working in Bangalore", context=field_ctx)
        assert info_away.status == "AWAY"
        assert info_away.notes == "Working in Bangalore"

        # 3. Transition to ABROAD
        info_abroad = field_svc.set_status(v1_id, FieldStatusType.ABROAD, notes="Moved to Dubai", context=field_ctx)
        assert info_abroad.status == "ABROAD"

        # 4. Transition to REPORTED_DECEASED
        info_dec = field_svc.set_status(v1_id, FieldStatusType.REPORTED_DECEASED, notes="Passed away", context=field_ctx)
        assert info_dec.status == "REPORTED_DECEASED"

        # 5. Transition to UNABLE_TO_VERIFY
        info_unv = field_svc.set_status(v1_id, FieldStatusType.UNABLE_TO_VERIFY, notes="House locked", context=field_ctx)
        assert info_unv.status == "UNABLE_TO_VERIFY"

        # 6. Verify audit history preserves ALL transitions
        history = field_svc.get_history(v1_id)
        assert len(history) == 4
        assert history[0].old_status == "NO_ISSUE" and history[0].new_status == "AWAY"
        assert history[1].old_status == "AWAY" and history[1].new_status == "ABROAD"
        assert history[2].old_status == "ABROAD" and history[2].new_status == "REPORTED_DECEASED"
        assert history[3].old_status == "REPORTED_DECEASED" and history[3].new_status == "UNABLE_TO_VERIFY"

        # 7. CRITICAL: Official voter information was NEVER modified
        detail = voter_svc.get_voter(v1_id)
        assert detail.official.name == "സുരേഷ് കുമാർ"
        assert detail.official.epic_number == "KLM1092831"
        assert detail.official.age == 42
        assert detail.field.status == "UNABLE_TO_VERIFY"


def test_review_service_anomaly_detection_and_resolution(service_test_db):
    """Verify review queue flags anomalies (missing EPIC, missing relative, missing house, age)."""
    db, roll_id = service_test_db
    with db.session() as session:
        review_svc = ReviewService(session)
        voter_svc = VoterService(session)
        admin_ctx = SecurityContext.admin("admin_user")

        # Scan and auto flag anomalies
        flagged_count = review_svc.auto_flag_roll_anomalies(roll_id)
        assert flagged_count == 1  # Voter 4 has anomalies

        # Query review queue
        queue = review_svc.get_review_queue(roll_id, review_status=ReviewStatusType.NEEDS_REVIEW)
        assert queue.total_count == 1
        anomalous_voter = queue.items[0]
        assert anomalous_voter.name == "അനിത"

        # Inspect voter detail review reasons
        detail = voter_svc.get_voter(anomalous_voter.voter_id)
        assert "MISSING_EPIC" in detail.field.review_reasons
        assert "MISSING_RELATIVE" in detail.field.review_reasons
        assert "MISSING_HOUSE" in detail.field.review_reasons
        assert "INVALID_AGE" in detail.field.review_reasons

        # Mark as REVIEWED
        review_svc.mark_as_reviewed(
            anomalous_voter.voter_id,
            notes="Manually verified with local BLO",
            context=admin_ctx,
        )

        # Verify queue is now empty
        updated_queue = review_svc.get_review_queue(roll_id, review_status=ReviewStatusType.NEEDS_REVIEW)
        assert updated_queue.total_count == 0

        # Official data remains untouched
        detail_after = voter_svc.get_voter(anomalous_voter.voter_id)
        assert detail_after.official.name == "അനിത"
        assert detail_after.field.review_status == "REVIEWED"


def test_security_role_based_permissions(service_test_db):
    """Verify that VIEWER and FIELD_USER cannot perform unauthorized administrative operations."""
    db, roll_id = service_test_db
    viewer_ctx = SecurityContext.viewer()
    field_ctx = SecurityContext.field_user()
    admin_ctx = SecurityContext.admin()

    with db.session() as session:
        roll_svc = RollService(session)
        review_svc = ReviewService(session)

        # 1. Viewer trying to update field status must fail
        field_svc = FieldStatusService(session)
        voters = roll_svc.roll_repo.session.execute(
            VoterRepository(session)._build_search_query(roll_id)
        ).scalars().all()
        v1_id = voters[0].id

        with pytest.raises(PermissionDeniedError):
            field_svc.set_status(v1_id, FieldStatusType.AWAY, context=viewer_ctx)

        # 2. Field user trying to activate roll must fail
        with pytest.raises(PermissionDeniedError):
            roll_svc.activate_roll(roll_id, context=field_ctx)

        # 3. Field user trying to review records must fail
        with pytest.raises(PermissionDeniedError):
            review_svc.mark_as_reviewed(v1_id, context=field_ctx)

        # 4. Admin succeeds
        assert roll_svc.activate_roll(roll_id, context=admin_ctx).status == "ACTIVE"


def test_roll_comparison(service_test_db):
    """Verify future-ready roll comparison detects added, removed, and modified records."""
    db, roll1_id = service_test_db

    # Create a second roll with changes
    with db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)
        roll_svc = RollService(session)

        roll2 = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="New Revision Roll 2027",
        )
        roll2_id = roll2.id

        # Roll 2 changes:
        # - KLM1092831 (Suresh): age 42 -> 43, house 12/45A -> 12/45B
        # - KLM1092832 (Fatima): unchanged
        # - KLM1092833 (George): removed
        # - KLM1092899 (New voter): added
        records = [
            {
                "serial_number": 1,
                "epic_number": "KLM1092831",
                "name": "സുരേഷ് കുമാർ",
                "relative_name": "വാസുദേവൻ",
                "house_number": "12/45B",  # Changed house
                "age": 43,  # Changed age
                "gender": "M",
                "part_number": "42",
                "polling_station_name": "St. Marys HSS",
            },
            {
                "serial_number": 2,
                "epic_number": "KLM1092832",
                "name": "ഫാത്തിമ ബീവി",
                "relative_name": "അബ്ദുൾ റഹ്മാൻ",
                "house_number": "14/102",
                "age": 38,
                "gender": "F",
                "part_number": "42",
                "polling_station_name": "St. Marys HSS",
            },
            {
                "serial_number": 3,
                "epic_number": "KLM1092899",  # Newly added voter
                "name": "MANOJ NAIR",
                "relative_name": "GOPALAN NAIR",
                "house_number": "19/3",
                "age": 29,
                "gender": "M",
                "part_number": "42",
                "polling_station_name": "St. Marys HSS",
            },
        ]
        voter_repo.insert_voters_batch(roll2_id, records)

        # Run comparison
        report = roll_svc.compare_rolls(old_roll_id=roll1_id, new_roll_id=roll2_id)
        assert report.added_count == 1
        assert report.removed_count == 2  # George (KLM1092833) and Anita (UNKNOWN)
        assert report.modified_count == 1  # Suresh (KLM1092831)
        assert report.unchanged_count == 1  # Fatima (KLM1092832)
        assert "Age changed: 42 -> 43" in report.differences[1].changes or any("Age changed" in c for diff in report.differences for c in diff.changes)

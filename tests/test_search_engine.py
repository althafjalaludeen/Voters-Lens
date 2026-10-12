"""Comprehensive tests for SearchEngine, multi-filter queries, sorting, and household grouping."""

import pytest
from voterlens.database.database import DatabaseManager
from voterlens.database.models import FieldStatusType, ReviewStatusType
from voterlens.database.repository import ElectoralRollRepository, FieldStatusRepository, VoterRepository
from voterlens.dto.filter_dto import (
    FieldStatusFilter,
    GenderFilter,
    ReviewStatusFilter,
    SearchCriteria,
    SortDirection,
    SortField,
    SortOptions,
)
from voterlens.services.field_service import FieldStatusService
from voterlens.services.search_service import SearchService
from voterlens.services.voter_service import VoterService


@pytest.fixture
def search_test_db(in_memory_db: DatabaseManager):
    """Setup database with realistic synthetic multilingual electoral records."""
    with in_memory_db.session() as session:
        roll_repo = ElectoralRollRepository(session)
        voter_repo = VoterRepository(session)
        field_repo = FieldStatusRepository(session)

        roll = roll_repo.create_roll_version(
            state="Kerala",
            district="Pathanamthitta",
            assembly_constituency="112 - Thiruvalla",
            roll_name="Search Benchmark Roll",
        )
        roll_id = roll.id

        records = [
            {
                "serial_number": 1,
                "epic_number": "KLM1092801",
                "name": "മുഹമ്മദ് ഷാഫി",
                "normalized_name": "മുഹമ്മദ് ഷാഫി",
                "relative_name": "അബ്ദുൾ റഹ്മാൻ",
                "normalized_relative_name": "അബ്ദുൾ റഹ്മാൻ",
                "relative_type": "FATHER",
                "house_number": "23",
                "normalized_house_number": "23",
                "age": 34,
                "gender": "M",
                "part_number": "10",
                "section_number": "1",
                "section_name": "Town Centre",
                "polling_station_name": "Govt High School",
            },
            {
                "serial_number": 2,
                "epic_number": "KLM1092802",
                "name": "ആമിന ഷാഫി",
                "normalized_name": "ആമിന ഷാഫി",
                "relative_name": "മുഹമ്മദ് ഷാഫി",
                "normalized_relative_name": "മുഹമ്മദ് ഷാഫി",
                "relative_type": "HUSBAND",
                "house_number": "23",
                "normalized_house_number": "23",
                "age": 30,
                "gender": "F",
                "part_number": "10",
                "section_number": "1",
                "section_name": "Town Centre",
                "polling_station_name": "Govt High School",
            },
            {
                "serial_number": 3,
                "epic_number": "KLM1092803",
                "name": "JOSEPH VARGHESE",
                "normalized_name": "JOSEPH VARGHESE",
                "relative_name": "VARGHESE MATHEW",
                "normalized_relative_name": "VARGHESE MATHEW",
                "relative_type": "FATHER",
                "house_number": "45/A",
                "normalized_house_number": "45/A",
                "age": 62,
                "gender": "M",
                "part_number": "10",
                "section_number": "2",
                "section_name": "Church Road",
                "polling_station_name": "St. Peters Hall",
            },
            {
                "serial_number": 4,
                "epic_number": "KLM1092804",
                "name": "MARY JOSEPH",
                "normalized_name": "MARY JOSEPH",
                "relative_name": "JOSEPH VARGHESE",
                "normalized_relative_name": "JOSEPH VARGHESE",
                "relative_type": "HUSBAND",
                "house_number": "45/A",
                "normalized_house_number": "45/A",
                "age": 58,
                "gender": "F",
                "part_number": "10",
                "section_number": "2",
                "section_name": "Church Road",
                "polling_station_name": "St. Peters Hall",
            },
            {
                "serial_number": 5,
                "epic_number": "KLM1092805",
                "name": "ലക്ഷ്മി നായർ",
                "normalized_name": "ലക്ഷ്മി നായർ",
                "relative_name": "രാഘവൻ നായർ",
                "normalized_relative_name": "രാഘവൻ നായർ",
                "relative_type": "FATHER",
                "house_number": "89",
                "normalized_house_number": "89",
                "age": 24,
                "gender": "F",
                "part_number": "11",
                "section_number": "1",
                "section_name": "Temple Lane",
                "polling_station_name": "Town Hall",
            },
        ]
        voter_repo.insert_voters_batch(roll_id, records)
        roll_repo.activate_roll(roll_id)

        # Mark Muhammad Shafi as AWAY with a phone number
        v1 = voter_repo.get_voter_by_epic("KLM1092801")[0]
        field_repo.update_field_information(
            voter_id=v1.id,
            status=FieldStatusType.AWAY,
            phone_number="9876543210",
            notes="Temporary assignment",
        )

        # Mark Mary Joseph as NEEDS_REVIEW
        v4 = voter_repo.get_voter_by_epic("KLM1092804")[0]
        field_repo.update_field_information(
            voter_id=v4.id,
            review_status=ReviewStatusType.NEEDS_REVIEW,
            review_reasons="PARSER_WARNING",
        )

    return in_memory_db, roll_id


def test_exact_epic_search(search_test_db):
    """Verify exact EPIC search returns exact match."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        res = search_svc.search(roll_id, SearchCriteria(epic="KLM1092801"))
        assert res.total_count == 1
        assert res.items[0].name == "മുഹമ്മദ് ഷാഫി"


def test_malayalam_name_search(search_test_db):
    """Verify Unicode Malayalam name search (exact and partial)."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        # Search by partial Malayalam name
        res = search_svc.search(roll_id, SearchCriteria(name="ഷാഫി"))
        assert res.total_count == 2  # Muhammad Shafi and Amina Shafi
        epics = {r.epic_number for r in res.items}
        assert epics == {"KLM1092801", "KLM1092802"}


def test_relative_name_search(search_test_db):
    """Verify relative name search."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        res = search_svc.search(roll_id, SearchCriteria(relative_name="അബ്ദുൾ റഹ്മാൻ"))
        assert res.total_count == 1
        assert res.items[0].epic_number == "KLM1092801"


def test_house_number_search(search_test_db):
    """Verify house number search returns all voters in the house."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        res = search_svc.search(roll_id, SearchCriteria(house_number="45/A"))
        assert res.total_count == 2
        names = {r.name for r in res.items}
        assert names == {"JOSEPH VARGHESE", "MARY JOSEPH"}


def test_gender_filter(search_test_db):
    """Verify gender filtering."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        res_m = search_svc.search(roll_id, SearchCriteria(gender=GenderFilter.MALE))
        assert res_m.total_count == 2
        res_f = search_svc.search(roll_id, SearchCriteria(gender=GenderFilter.FEMALE))
        assert res_f.total_count == 3


def test_simultaneous_multi_filter_search(search_test_db):
    """Verify Section 11 requirement:
    Name: Muhammad
    Relative: Abdul Rahman
    House: 23
    Gender: Male
    Field status: AWAY
    Result must satisfy all active filters simultaneously.
    """
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        criteria = SearchCriteria(
            name="മുഹമ്മദ്",
            relative_name="അബ്ദുൾ റഹ്മാൻ",
            house_number="23",
            gender=GenderFilter.MALE,
            field_status=FieldStatusFilter.AWAY,
        )
        res = search_svc.search(roll_id, criteria)
        assert res.total_count == 1
        assert res.items[0].epic_number == "KLM1092801"
        assert res.items[0].name == "മുഹമ്മദ് ഷാഫി"
        assert res.items[0].field_status == "AWAY"


def test_review_status_filter(search_test_db):
    """Verify review status filtering."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)
        res = search_svc.search(roll_id, SearchCriteria(review_status=ReviewStatusFilter.NEEDS_REVIEW))
        assert res.total_count == 1
        assert res.items[0].epic_number == "KLM1092804"


def test_household_view_grouping(search_test_db):
    """Verify Section 19: House view grouping query."""
    db, roll_id = search_test_db
    with db.session() as session:
        voter_svc = VoterService(session)
        groups, total_houses = voter_svc.get_household_groups(roll_id)
        assert total_houses == 3  # Houses: 23, 45/A, 89
        
        # Check house 23 group
        h23 = next(g for g in groups if g.normalized_house_number == "23")
        assert h23.voter_count == 2
        h23_names = {v.name for v in h23.voters}
        assert h23_names == {"മുഹമ്മദ് ഷാഫി", "ആമിന ഷാഫി"}


def test_sorting_and_pagination(search_test_db):
    """Verify Section 16 & 17: Sorting (by age, name, serial) and pagination."""
    db, roll_id = search_test_db
    with db.session() as session:
        search_svc = SearchService(session)

        # Sort by age descending
        res_age_desc = search_svc.search(
            roll_id,
            SearchCriteria(
                sort=SortOptions(field=SortField.AGE, direction=SortDirection.DESC),
                page=1,
                page_size=2,
            ),
        )
        assert len(res_age_desc.items) == 2
        assert res_age_desc.total_count == 5
        assert res_age_desc.total_pages == 3
        assert res_age_desc.has_next is True
        assert res_age_desc.items[0].age == 62  # Joseph Varghese (oldest)

        # Page 2
        res_p2 = search_svc.search(
            roll_id,
            SearchCriteria(
                sort=SortOptions(field=SortField.AGE, direction=SortDirection.DESC),
                page=2,
                page_size=2,
            ),
        )
        assert len(res_p2.items) == 2
        assert res_p2.items[0].age == 34  # Muhammad Shafi (34)


def test_area_statistics_breakdown(search_test_db):
    """Verify Section 20: Area statistics aggregation."""
    db, roll_id = search_test_db
    with db.session() as session:
        voter_svc = VoterService(session)
        stats = voter_svc.get_area_statistics(roll_id, part_number="10")
        assert stats.total_voters == 4
        assert stats.gender_counts.get("M", 0) == 2
        assert stats.gender_counts.get("F", 0) == 2
        assert stats.field_status_counts.get("AWAY", 0) == 1
        assert stats.field_status_counts.get("NO_ISSUE", 0) == 3
        assert stats.review_status_counts.get("NEEDS_REVIEW", 0) == 1

"""Automated pytest performance assertions ensuring all queries finish under 100 ms."""

import time
from pathlib import Path
import pytest
from sqlalchemy import text

from voterlens.database.database import DatabaseManager
from voterlens.database.fts import rebuild_fts_index
from voterlens.dto.filter_dto import GenderFilter, SearchCriteria
from voterlens.services.search_service import SearchService
from voterlens.services.voter_service import VoterService


@pytest.fixture(scope="module")
def benchmark_db():
    db_path = Path("validation-results/full-roll/validation.db")
    if not db_path.exists():
        pytest.skip("Full roll validation.db not found for benchmark.")
    manager = DatabaseManager(database_url=f"sqlite:///{db_path}")
    manager.create_tables()
    with manager.session() as session:
        rebuild_fts_index(session)
    yield manager
    manager.close()


def test_list_page_retrieval_under_100ms(benchmark_db):
    """Verify list page retrieval finishes under 100 ms."""
    with benchmark_db.session() as session:
        voter_svc = VoterService(session)
        roll_id = voter_svc.voter_repo.session.execute(
            text("SELECT id FROM roll_versions LIMIT 1")
        ).scalar()

        t0 = time.perf_counter()
        res = voter_svc.get_voters(roll_id, page=1, page_size=50)
        elapsed_ms = (time.perf_counter() - t0) * 1000

        assert len(res.items) == 50
        assert elapsed_ms < 100.0, f"List retrieval took {elapsed_ms:.2f}ms (>100ms)"


def test_exact_epic_search_under_100ms(benchmark_db):
    """Verify exact EPIC search finishes under 100 ms."""
    with benchmark_db.session() as session:
        search_svc = SearchService(session)
        voter_svc = VoterService(session)
        roll_id = voter_svc.voter_repo.session.execute(
            text("SELECT id FROM roll_versions LIMIT 1")
        ).scalar()
        sample_epic = voter_svc.voter_repo.session.execute(
            text("SELECT epic_number FROM voters LIMIT 1")
        ).scalar()

        t0 = time.perf_counter()
        res = search_svc.search(roll_id, SearchCriteria(epic=sample_epic))
        elapsed_ms = (time.perf_counter() - t0) * 1000

        assert res.total_count >= 1
        assert elapsed_ms < 100.0, f"EPIC search took {elapsed_ms:.2f}ms (>100ms)"


def test_malayalam_name_search_under_100ms(benchmark_db):
    """Verify Malayalam name search finishes under 100 ms."""
    with benchmark_db.session() as session:
        search_svc = SearchService(session)
        voter_svc = VoterService(session)
        roll_id = voter_svc.voter_repo.session.execute(
            text("SELECT id FROM roll_versions LIMIT 1")
        ).scalar()
        sample_name = voter_svc.voter_repo.session.execute(
            text("SELECT name FROM voters LIMIT 1")
        ).scalar().split()[0]

        t0 = time.perf_counter()
        res = search_svc.search(roll_id, SearchCriteria(name=sample_name))
        elapsed_ms = (time.perf_counter() - t0) * 1000

        assert res.total_count >= 1
        assert elapsed_ms < 100.0, f"Malayalam search took {elapsed_ms:.2f}ms (>100ms)"


def test_voter_detail_retrieval_under_100ms(benchmark_db):
    """Verify voter detail retrieval finishes under 100 ms."""
    with benchmark_db.session() as session:
        voter_svc = VoterService(session)
        voter_id = voter_svc.voter_repo.session.execute(
            text("SELECT id FROM voters LIMIT 1")
        ).scalar()

        t0 = time.perf_counter()
        detail = voter_svc.get_voter(voter_id)
        elapsed_ms = (time.perf_counter() - t0) * 1000

        assert detail is not None
        assert elapsed_ms < 100.0, f"Detail retrieval took {elapsed_ms:.2f}ms (>100ms)"


def test_fts5_vs_btree_search_under_100ms(benchmark_db):
    """Verify both FTS5 MATCH and B-Tree LIKE searches finish well under 100 ms."""
    with benchmark_db.session() as session:
        search_svc = SearchService(session)
        voter_svc = VoterService(session)
        roll_id = voter_svc.voter_repo.session.execute(
            text("SELECT id FROM roll_versions LIMIT 1")
        ).scalar()
        sample_name = voter_svc.voter_repo.session.execute(
            text("SELECT name FROM voters LIMIT 1")
        ).scalar().split()[0]

        # B-Tree
        t0 = time.perf_counter()
        res_btree = search_svc.search(roll_id, SearchCriteria(name=sample_name, use_fts=False))
        btree_ms = (time.perf_counter() - t0) * 1000

        # FTS5
        t0 = time.perf_counter()
        res_fts = search_svc.search(roll_id, SearchCriteria(query=sample_name, use_fts=True))
        fts_ms = (time.perf_counter() - t0) * 1000

        assert btree_ms < 100.0
        assert fts_ms < 100.0

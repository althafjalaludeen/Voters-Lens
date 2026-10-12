"""Benchmark script evaluating Phase 2 search performance and B-Tree vs FTS5 comparisons."""

import sys
import time
from pathlib import Path
from voterlens.database.database import DatabaseManager
from voterlens.database.fts import rebuild_fts_index
from voterlens.dto.filter_dto import GenderFilter, SearchCriteria
from voterlens.services.search_service import SearchService
from voterlens.services.voter_service import VoterService


def run_benchmark(db_path: str = "validation-results/full-roll/validation.db"):
    if sys.stdout.encoding.lower() != "utf-8":
        try:
            sys.stdout.reconfigure(encoding="utf-8")
        except Exception:
            pass
    print(f"=== VoterLens Phase 2 Performance Benchmark ===")
    print(f"Target Database: {db_path}")

    db = DatabaseManager(database_url=f"sqlite:///{db_path}")
    db.create_tables()

    session = db.session_factory()
    try:
        # Determine active roll
        from voterlens.database.models import RollVersion, RollVersionStatus
        from sqlalchemy import select
        roll = session.execute(
            select(RollVersion).where(RollVersion.status == RollVersionStatus.ACTIVE)
        ).scalars().first()
        if not roll:
            roll = session.execute(select(RollVersion)).scalars().first()
        if not roll:
            print("No roll version found in database.")
            return

        roll_id = roll.id
        print(f"Roll: '{roll.roll_name}' ({roll.record_count} voters)")

        # Sync FTS5 index
        indexed_fts = rebuild_fts_index(session, roll_version_id=roll_id)
        session.commit()
        print(f"FTS5 Virtual Index synchronized: {indexed_fts} records indexed.")

        voter_svc = VoterService(session)
        search_svc = SearchService(session)

        # Warm up
        voter_svc.get_voters(roll_id, page=1, page_size=50)

        benchmarks = {}

        # 1. Full voter list retrieval (page size 50)
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            res = voter_svc.get_voters(roll_id, page=1, page_size=50)
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks["List Page Retrieval (50 records)"] = sum(times) / len(times)

        # 2. Exact EPIC search
        first_epic = res.items[0].epic_number
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            r = search_svc.search(roll_id, SearchCriteria(epic=first_epic))
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks[f"Exact EPIC Search ('{first_epic}')"] = sum(times) / len(times)

        # 3. Malayalam Name search (B-Tree LIKE)
        name_sample = res.items[0].name.split()[0] if res.items[0].name else "ഷാ"
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            r_btree = search_svc.search(roll_id, SearchCriteria(name=name_sample, use_fts=False))
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks[f"Malayalam Name B-Tree LIKE ('{name_sample}')"] = sum(times) / len(times)

        # 4. Malayalam Name search (FTS5 MATCH)
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            r_fts = search_svc.search(roll_id, SearchCriteria(query=name_sample, use_fts=True))
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks[f"Malayalam Name FTS5 MATCH ('{name_sample}')"] = sum(times) / len(times)

        # 5. House Number search
        house_sample = res.items[0].house_number
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            r_house = search_svc.search(roll_id, SearchCriteria(house_number=house_sample))
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks[f"House Number Search ('{house_sample}')"] = sum(times) / len(times)

        # 6. Combined Multi-Criteria search
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            r_comb = search_svc.search(
                roll_id,
                SearchCriteria(
                    gender=GenderFilter.MALE,
                    house_number=house_sample,
                ),
            )
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks["Combined Multi-Criteria Search (House + Gender)"] = sum(times) / len(times)

        # 7. Voter Detail retrieval
        voter_id = res.items[0].voter_id
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            detail = voter_svc.get_voter(voter_id)
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks["Voter Detail Retrieval (Official + Field)"] = sum(times) / len(times)

        # 8. Household Grouping query
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            h_groups, total_h = voter_svc.get_household_groups(roll_id, page=1, page_size=20)
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks["Household Grouping View (20 houses)"] = sum(times) / len(times)

        # 9. Area Statistics query
        times = []
        for _ in range(10):
            t0 = time.perf_counter()
            stats = voter_svc.get_area_statistics(roll_id)
            times.append((time.perf_counter() - t0) * 1000)
        benchmarks["Area Statistics Aggregation"] = sum(times) / len(times)

        print("\n" + "=" * 65)
        print(f"{'Operation':<45} | {'Avg Latency':<10} | {'Status'}")
        print("-" * 65)
        all_passed = True
        for op, lat in benchmarks.items():
            status = "PASS (<100ms)" if lat < 100.0 else "FAIL (>100ms)"
            if lat >= 100.0:
                all_passed = False
            print(f"{op:<45} | {lat:6.2f} ms | {status}")
        print("=" * 65)

        if all_passed:
            print("\n>>> ALL PERFORMANCE BENCHMARKS SATISFIED (< 100 ms target).")
        else:
            print("\n>>> Some operations exceeded the 100ms target.")

    finally:
        session.close()
        db.close()


if __name__ == "__main__":
    run_benchmark()

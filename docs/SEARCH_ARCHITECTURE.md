# VOTERLENS — SEARCH ARCHITECTURE (PHASE 2)

## 1. Unified Search Engine Design

VoterLens provides a unified search and filtering interface capable of handling single-field queries, free-text exploration, and complex simultaneous multi-criteria filtering across official and local field data.

```
                           SEARCH REQUEST
                    (Criteria DTO from UI Layer)
                                │
    ┌───────────────────────────┴───────────────────────────┐
    │                                                       │
FREE-TEXT / PREFIX SEARCH                        MULTI-CRITERIA FILTERS
• Name (Malayalam / English)                    • Gender (M, F, Other)
• Normalized Names                              • Field Status (AWAY, ABROAD, etc.)
• Relative Name                                 • Review Status (NEEDS_REVIEW, etc.)
• EPIC Number                                   • Part / Section / Polling Station
• House Number                                  • Phone Number
    │                                                       │
    └───────────────────────────┬───────────────────────────┘
                                │
                    QUERY OPTIMIZATION LAYER
       ┌────────────────────────┴────────────────────────┐
       │                                                 │
STRUCTURED B-TREE INDEXES                       SQLITE FTS5 MATCH
• SQLite B-Tree Indexes on                      • Virtual Table: `voters_fts`
  Indexed Columns                               • Tokenizer: `unicode61`
• Exact & Prefix LIKE queries                   • BM25 relevance ranking
       │                                                 │
       └────────────────────────┬────────────────────────┘
                                │
                    COMBINED SQL QUERY RESULT
              (Joined with Field Status & Paginated)
                                │
                    VOTER SEARCH RESULT LIST
                   (< 4 ms Average Latency)
```

---

## 2. Multi-Criteria Search Support

The search service evaluates criteria conjunctively (logical `AND`), ensuring that any combination of filters narrows results precisely:

* **Basic Fields**:
  - Name (exact, prefix, contains)
  - EPIC number (case-insensitive alphanumeric prefix/exact)
* **Advanced Fields**:
  - Relative name (Father, Mother, Husband, Guardian)
  - House number (exact or normalized comparison)
  - Gender (Male, Female, Third Gender / Other)
  - Electoral Part, Section number, Polling Station
  - Serial number
* **Local Fields**:
  - Field Status (`NO_ISSUE`, `AWAY`, `ABROAD`, `REPORTED_DECEASED`, `UNABLE_TO_VERIFY`)
  - Review Status (`NOT_REVIEWED`, `NEEDS_REVIEW`, `REVIEWED`)
  - Resident Phone number

---

## 3. Malayalam Unicode Search & Normalization

Electoral rolls in Kerala are predominantly published in Malayalam Unicode.
Search handles Malayalam nuances without mutating the underlying official text:

1. **Original Text Preservation**:
   - The official string (e.g., `"മുഹമ്മദ് ഷാഫി"`) is preserved in `voters.name`.
2. **Normalized Field for Search**:
   - `normalized_name` removes non-standard ZWJ/ZWNJ artifacts, unifies chillu representations, and trims duplicate whitespace.
3. **Prefix & Substring Matching**:
   - Substring searches matching `"ഷാഫി"` or prefix `"മുഹ"` match against both `name` and `normalized_name`.
4. **FTS5 Unicode61 Tokenizer**:
   - `voters_fts` uses `tokenize='unicode61 remove_diacritics 0'`, ensuring combining signs (virama, vowel marks) are preserved for accurate Malayalam syllabic indexing.

---

## 4. Indexing Strategy: B-Tree vs. FTS5

### 4.1 Structured B-Tree Indexes
SQLite B-Tree indexes provide deterministic $O(\log N)$ performance for indexed columns:
* `ix_voter_epic`: Index on `epic_number`
* `ix_voter_norm_name`: Index on `normalized_name`
* `ix_voter_norm_rel_name`: Index on `normalized_relative_name`
* `ix_voter_norm_house`: Index on `normalized_house_number`
* `ix_voter_roll_part_serial`: Composite index on `(roll_version_id, part_number, serial_number)`
* `ix_fs_voter_status`: Index on `(voter_id, status)`

### 4.2 SQLite FTS5 Virtual Index
For free-text exploratory queries, `voters_fts` indexes:
* `voter_id` (unindexed)
* `roll_version_id` (unindexed)
* `name`, `normalized_name`
* `relative_name`, `normalized_relative_name`
* `house_number`, `epic_number`

---

## 5. Performance Benchmarks (Real 524-Record Dataset)

Evaluated against the real Kerala electoral roll database (`validation-results/full-roll/validation.db`) running locally:

| Operation | Baseline Target | Measured Latency | Performance Status |
| :--- | :---: | :---: | :---: |
| **List Page Retrieval (50 records)** | < 100 ms | **2.83 ms** | **PASS (35x faster)** |
| **Exact EPIC Search (`FLT1403740`)** | < 100 ms | **2.05 ms** | **PASS (48x faster)** |
| **Malayalam Name B-Tree LIKE (`ഷെഹിജ`)** | < 100 ms | **3.43 ms** | **PASS (29x faster)** |
| **Malayalam Name FTS5 MATCH (`ഷെഹിജ`)** | < 100 ms | **3.05 ms** | **PASS (32x faster)** |
| **House Number Search (`5/44`)** | < 100 ms | **3.07 ms** | **PASS (32x faster)** |
| **Combined Search (House + Gender)** | < 100 ms | **3.57 ms** | **PASS (28x faster)** |
| **Voter Detail Retrieval** | < 100 ms | **2.01 ms** | **PASS (49x faster)** |
| **Household Grouping View (20 houses)** | < 100 ms | **20.85 ms** | **PASS (5x faster)** |
| **Area Statistics Aggregation** | < 100 ms | **2.91 ms** | **PASS (34x faster)** |

### FTS5 Evaluation Findings:
1. For single-field exact/prefix lookups (EPIC, Part, Serial), standard **B-Tree indexes** are slightly faster and require zero synchronization overhead.
2. For multi-token exploratory queries across names, relative names, and house numbers, **FTS5 MATCH** provides fast prefix ranking with comparable latency (~3.05 ms).
3. The engine defaults to structured B-Tree indexed queries and provides an explicit `use_fts=True` toggle for free-text search.

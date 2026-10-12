# VOTERLENS — FLUTTER INTEGRATION ARCHITECTURE

## 1. Executive Summary & Selected Architecture

For Phase 3 of VoterLens, we evaluated four primary architectural integration options to bridge the Flutter UI with the local electoral-roll engine.

### **Selected Architecture: Option A & B (Shared Canonical SQLite Contract via Direct Dart SQLite Access)**

Flutter accesses the local SQLite database (`data/voterlens.db` or `validation-results/full-roll/validation.db`) directly using native SQLite bindings (`sqlite3` and `sqlite3_flutter_libs`). 
Python remains responsible for heavy processing, OCR, layout extraction, and initial PDF ingestion, writing to the canonical SQLite schema. Flutter reads and writes to this exact same SQLite database directly in process without any background daemon.

```
┌─────────────────────────────────────────────────────────────┐
│                       FLUTTER APP                           │
│  (UI / Presentation / Riverpod State / Local Repositories)  │
└──────────────────────────────┬──────────────────────────────┘
                               │ Direct in-process C-bindings
                               │ (sqlite3 FFI)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                  CANONICAL SQLITE DATABASE                  │
│       (data/voterlens.db with WAL mode & strict PRAGMAs)     │
│   • roll_versions             • field_status                │
│   • electoral_area_configs    • field_status_history        │
│   • voters (immutable)        • audit_logs                  │
│   • voters_fts (FTS5)         • users                       │
└──────────────────────────────▲──────────────────────────────┘
                               │ Direct SQLite connection
                               │ (SQLAlchemy / Python Pipeline)
┌──────────────────────────────┴──────────────────────────────┐
│                  PYTHON INGESTION PIPELINE                  │
│        (Official PDF Ingestion, Layout Analyzer, OCR)       │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Evaluation of Alternatives & Rejected Options

| Option | Description | Evaluation & Verdict |
| :--- | :--- | :--- |
| **Option A/B: Direct SQLite Contract (Selected)** | Flutter accesses canonical SQLite database directly via `sqlite3` FFI. | **ACCEPTED**: 100% offline, zero network ports, zero background processes, sub-millisecond query execution, shared database schema. |
| **Option C: Custom Native FFI Bridge** | Write custom C/C++ shared library wrappers between Python and Dart. | **REJECTED**: Unnecessary complexity. SQLite already provides an official, battle-tested C-FFI surface natively supported by Dart. |
| **Option D: Local IPC / Subprocess** | Spawn a persistent Python subprocess with stdin/stdout JSON-RPC pipes. | **REJECTED**: Fragile process lifecycle, high battery consumption on mobile, serialization overhead, startup delays. |
| **Localhost HTTP / REST Server** | Run a local Flask/FastAPI HTTP server on localhost. | **STRICTLY REJECTED**: Violates offline-first philosophy, trips OS firewalls and mobile networking permissions, introduces socket latency, risk of port collisions. |

---

## 3. Why the Choice Was Made

1. **True Local Application Execution**:
   The Flutter app launches instantly with zero dependence on a running Python runtime, localhost socket, or background thread.
2. **Zero Network Requirement**:
   Zero TCP sockets, loopback ports, or HTTP connections are opened. This strictly satisfies Section 1, Section 23, and Section 31.
3. **Database Compatibility**:
   The schema created in Phase 2 adheres to SQLite standards:
   - Foreign key constraints enabled (`PRAGMA foreign_keys = ON;`)
   - Write-Ahead Logging (`PRAGMA journal_mode = WAL;`)
   - B-Tree indexes on `epic_number`, `normalized_name`, `house_number`, `part_number`, `serial_number`, and `gender`
   - SQLite FTS5 virtual table (`voters_fts`) for full-text search with `unicode61`.
4. **Sub-Millisecond Query Speeds**:
   Direct in-process query execution eliminates inter-process communication serialization delays. Simple indexed queries run in **< 1 ms**.
5. **Strict Immutability Guarantee**:
   Flutter queries execute `SELECT` statements on the `voters` table and strictly execute `INSERT`/`UPDATE` operations only on `field_status`, `field_status_history`, `audit_logs`, and `electoral_area_configs`.

---

## 4. Database Compatibility & Migration Strategy

The database access layer in Dart mirrors the Python SQLAlchemy repository contracts:
* The `AppDatabase` class encapsulates table schema definitions, connection lifecycle, and transactional queries.
* Pre-existing databases (e.g. from Phase 1.5/2) are opened without alteration; any missing columns (e.g., `checksum_hash`, `review_status`, `phone_number`) are non-destructively verified on open.
* Both Python and Dart access the same file without concurrency lockouts thanks to SQLite **WAL (Write-Ahead Logging)** mode.

---

## 5. Offline Guarantees

* **No Cloud Sync**: Zero remote servers, cloud databases, or background sync services.
* **Local Images**: Photographs are loaded directly from local storage (`photos/...`) using standard `FileImage` and `Image.file`. If absent, a deterministic neutral icon placeholder is displayed.
* **Privacy Assurance**: No voter information is transmitted across any network interface.

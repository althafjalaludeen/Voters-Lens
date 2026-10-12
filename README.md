# VoterLens — Phase 1: Electoral Roll Import & Local Database Foundation

VoterLens is an offline-first, localized electoral-roll search and field-verification application.

This phase implements the **electoral-roll import engine, local SQLite database foundation, and supporting infrastructure**. It separates official immutable electoral data from editable local field verification data and operates with zero network dependencies after roll ingestion.

---

## Key Features

1. **Strict Offline Operation:** Once imported, searching, filtering, and portrait retrieval run 100% locally with zero internet access.
2. **Official vs. Field Data Separation:**
   - **Official Roll Data:** READ-ONLY and locked once a roll becomes `ACTIVE`.
   - **Local Field Verification:** Editable and auditable in `field_status` and `field_status_history` tables. Even observations such as `REPORTED_DECEASED` or `AWAY` leave official records intact.
3. **Modular OCR Architecture:** Pluggable engine interface supporting Tesseract (`mal+eng`), PaddleOCR, and Mock/Dual-mode digital PDF extraction.
4. **Malayalam + English Parsing & Normalization:** Robust extraction of names, relative names, relationships (അച്ഛൻ / ഭർത്താവ് / അമ്മ), house numbers, age, and gender, with Unicode NFC and Chillu letter normalization.
5. **Photograph Pipeline:** Automatic card portrait cropping, pixel variance validation (rejecting blank placeholders), normalization, and deterministic local storage.
6. **Pre-Commit Validation:** Generates structured validation reports checking duplicate EPICs, impossible age values, malformed house numbers, and missing photos.
7. **Fail-Safe Rollback:** If an import fails, the active roll remains untouched while the failed roll is marked `FAILED`.

---

## Project Structure

```
VotersLens/
├── voterlens/
│   ├── config/              # Application settings and directory paths
│   ├── downloader/          # Authorized PDF validation and SHA-256 integrity
│   ├── pdf/                 # PyMuPDF rendering and 3x10 card segmentation
│   ├── ocr/                 # Modular OCR abstractions (Tesseract, Paddle, Mock)
│   ├── parser/              # Malayalam/English voter card field parser
│   ├── normalizer/          # Unicode NFC, chillu, and whitespace normalizers
│   ├── validator/           # Pre-commit dataset validation and report generation
│   ├── photographs/         # Photo extraction, quality check, and local storage
│   ├── database/            # SQLAlchemy 2.0 models, SQLite WAL, and repositories
│   └── pipeline/            # End-to-end transactional import orchestrator
├── tests/
│   ├── conftest.py          # Pytest fixtures and isolated temporary databases
│   ├── test_database.py     # Schema, immutability, and field-status tests
│   ├── test_normalizer.py   # Malayalam Unicode and token normalizer tests
│   ├── test_validator.py    # Pre-commit validation and duplicate checks
│   ├── test_photos.py       # Portrait extraction and variance tests
│   ├── test_pipeline.py     # End-to-end import and failure safety tests
│   └── test_offline_search.py # Socket-isolated offline search queries
├── test-data/               # Synthetic electoral roll PDFs
├── scripts/
│   ├── generate_synthetic_roll.py # Generator for realistic synthetic Kerala rolls
│   └── run_import.py        # CLI runner for importing electoral roll PDFs
├── docs/
│   ├── ARCHITECTURE.md      # Detailed system architecture and principles
│   ├── DATA_MODEL.md        # Database schema, indexing, and ER diagram
│   ├── IMPORT_PIPELINE.md   # Step-by-step pipeline execution flow
│   └── OCR.md               # OCR engine setup and Malayalam language packs
├── requirements.txt         # Project dependencies
├── pyproject.toml           # Package configuration
└── README.md                # Project documentation
```

---

## Installation & Setup

### Prerequisites
- Python 3.11+
- Virtual environment (`venv`)

### 1. Install Dependencies
```powershell
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
pip install -e .
```

### 2. Optional: Tesseract OCR for Scanned PDFs
To OCR scanned paper rolls containing Malayalam:
1. Install Tesseract OCR on Windows.
2. Select **Malayalam script** and **Malayalam language data** during installation.
3. Add Tesseract to system `PATH` (see [docs/OCR.md](docs/OCR.md) for details).

---

## Running the Automated Test Suite

The test suite validates schema creation, immutability locks, field audit histories, Unicode normalization, offline search execution with network blocked, photo extraction, and pipeline fail-safe rollback:

```powershell
.venv\Scripts\pytest -v
```

All 21 test suites execute locally in ~1 second.

---

## Running an Import via CLI

Import an authorized electoral roll PDF into the local SQLite database:

```powershell
.venv\Scripts\python scripts/run_import.py \
    --pdf tests/test-data/synthetic_kerala_roll.pdf \
    --state Kerala \
    --district Pathanamthitta \
    --ac "112 - Thiruvalla" \
    --roll-name "Final Electoral Roll 2026" \
    --ocr-engine auto
```

### Sample Output:
```
============================================================
VOTERLENS IMPORT SUMMARY
============================================================
Roll Version ID:  0f95c64c-44cc-41aa-8a64-57b1dacd53d1
Status:           ACTIVE
Total Detected:   30
Valid Records:    30
Warnings:         70
Photos Saved:     6
============================================================

==================================================
IMPORT VALIDATION REPORT
==================================================
Total detected: 30
Valid:          30
Warnings:       70
Invalid:        0
--------------------------------------------------
Breakdown:
    24 missing photographs
    23 duplicate EPIC numbers
    23 duplicate-looking records
==================================================
```

---

## Known Limitations (Phase 1)
1. **Header Layout Variations:** Electoral rolls from different election cycles (e.g. 2014 vs 2026) occasionally vary header placement for part numbers and sections; the parser currently accommodates standard ECI Malayalam layouts.
2. **Low-Quality Paper Scans:** Extreme paper skew (> 15 degrees) requires an additional un-skewing step in the image pre-processing pipeline before card segmentation.
3. **No Network Access by Design:** The core search engine contains no network client code.

---

## Requirements for Phase 2
Phase 1 foundation is complete. When authorized to proceed to **Phase 2**, the following will be implemented:
1. High-performance offline voter search engine API layer (Full-Text Search / SQLite FTS5).
2. Advanced field-status sync protocol (local-first peer sync or export/import reconciliation).
3. Local audit log viewer and roll comparison tools (diffing active vs. newly staged rolls).
4. Flutter UI integration with SQLite via `sqlite3` / `sqflite_common_ffi`.

# Electoral Roll Import Pipeline Specification

## 1. Execution Stages

The import pipeline is implemented in [import_pipeline.py](file:///d:/VotersLens/voterlens/pipeline/import_pipeline.py) and executes the following sequential steps:

1. **Input File Verification:**
   - Validates file existence, non-zero size, and `.pdf` extension.
   - Computes SHA-256 digest to prevent duplicate imports and establish source provenance.

2. **PDF Inspection:**
   - Opens document using PyMuPDF.
   - Reads page count, encryption flags, and metadata.

3. **Staging Roll Version:**
   - Creates a new `roll_versions` record with `status = IMPORTING`.

4. **Page & Card Processing:**
   - Renders each voter page at 200 DPI into high-resolution RGB pixmaps.
   - Segments the page into a 3-column by 10-row grid of voter card regions (30 cards per page).
   - Extracts page-level metadata (Part Number, Section Name, Polling Station).

5. **Dual-Mode Text Extraction:**
   - **Mode A (Digital PDF):** Checks if the card bounding box contains digital text streams. If found, extracts directly with confidence 1.0.
   - **Mode B (Scanned PDF):** Passes the cropped card image to the modular OCR engine (`BaseOCREngine`).

6. **Field Extraction & Parsing:**
   - Evaluates multi-pattern regexes across Malayalam and English labels.
   - Extracts: Serial Number, EPIC, Name, Relative Name, Relative Relationship, House Number, Age, and Gender.

7. **Photograph Processing:**
   - Detects portrait bounding box on the card (right 28-30%).
   - Crops candidate photo region.
   - Computes pixel variance: rejects solid or blank placeholder boxes (`variance < 120.0`).
   - Normalizes to standard 240x300 RGB portrait.
   - Deterministically saves to `photos/<roll_version_id>/<voter_id>.jpg`.

8. **Normalization:**
   - Canonical Unicode NFC normalization.
   - Converts legacy Malayalam virama + ZWJ ligatures to atomic Unicode chillu letters (ൺ, ൻ, ർ, ൽ, ൾ, ൿ).
   - Cleans invisible zero-width characters (`\u200b`, `\u200c`, `\u200d`, `\ufeff`).
   - Standardizes EPIC numbers (uppercase, whitespace stripped).
   - Formats house numbers and relative types.

9. **Pre-Commit Validation:**
   - Validates age range (18–125).
   - Validates EPIC regex formatting.
   - Identifies duplicate EPICs and suspicious duplicate records.
   - Flags low OCR confidence.
   - Generates an `ImportValidationReport`.

10. **Database Insertion:**
    - Performs fast bulk insertion of voter records.
    - Persists validation report summary in `import_reports`.

11. **Activation & Locking:**
    - If `auto_activate=True` and no fatal errors occurred:
      - Any previous `ACTIVE` roll for the area transitions to `ARCHIVED`.
      - The new roll transitions to `ACTIVE`.
      - Official voter records are locked against future mutation.

---

## 2. Fail-Safe Guarantees

If an unexpected error occurs at any point during page rendering, OCR, parsing, or insertion:
1. The ongoing import transaction is rolled back.
2. The staging roll version is marked `FAILED`.
3. **The existing `ACTIVE` roll remains untouched and continues serving offline searches.**

# OCR Architecture & Setup Guide

## 1. Modular OCR Engine Design
VoterLens abstracts OCR behind the [BaseOCREngine](file:///d:/VotersLens/voterlens/ocr/engine.py) interface. This decouples the parser and import pipeline from any specific OCR implementation.

```
                      +-------------------+
                      |   BaseOCREngine   |
                      +-------------------+
                                ^
         +----------------------+----------------------+
         |                      |                      |
+------------------+  +-------------------+  +------------------+
| TesseractOCREngine|  |  PaddleOCREngine  |  |  MockOCREngine   |
+------------------+  +-------------------+  +------------------+
```

### Supported Engines:
1. **Tesseract OCR (`tesseract`):** Open-source optical character recognition engine. Supports multilingual packs (`mal` + `eng`).
2. **PaddleOCR (`paddle`):** Deep learning-based OCR framework with strong multilingual detection and angle classification.
3. **Mock OCR (`mock`):** Deterministic mock engine used for automated CI/CD and offline tests without external binaries.
4. **Auto-Detect (`auto`):** Dynamically probes the local host system in priority order: Tesseract -> PaddleOCR -> Mock fallback.

---

## 2. Kerala Electoral Rolls Language Requirements
Electoral rolls in Kerala require multilingual OCR:
- Malayalam (`mal`): Voter names, relative names, relationship titles, house names, and polling booth details.
- English (`eng`): EPIC numbers, alphanumeric house numbers, and bilingual headers.
- Mixed Mode (`mal+eng`): Cards frequently contain interleaved scripts (e.g., `പേര്: സുരേഷ് കുമാർ (Suresh Kumar)`).

---

## 3. Local Installation & Configuration

### 3.1 Tesseract OCR Setup on Windows
1. Download the official Windows installer from [UB-Mannheim/tesseract](https://github.com/UB-Mannheim/tesseract/wiki).
2. During installation, select **Additional script data** -> **Malayalam script** and **Additional language data** -> **Malayalam**.
3. Ensure `tesseract.exe` is added to your system `PATH`, or set `tesseract_cmd` in `voterlens/config/settings.py`:
   ```python
   Settings(tesseract_cmd=r"C:\Program Files\Tesseract-OCR\tesseract.exe")
   ```
4. Verify Malayalam language pack:
   ```powershell
   tesseract --list-langs
   # Expected output should include:
   # eng
   # mal
   # osd
   ```

### 3.2 PaddleOCR Setup (Optional)
To use PaddleOCR:
```powershell
pip install paddlepaddle paddleocr
```
PaddleOCR will be automatically discovered by the `auto` engine selector.

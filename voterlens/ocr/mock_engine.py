"""Mock OCR engine for deterministic unit tests and offline testing."""

from typing import Optional
import numpy as np
from PIL import Image

from voterlens.ocr.engine import BaseOCREngine, OCRResult, OCRTextBox


class MockOCREngine(BaseOCREngine):
    """Deterministic OCR engine used for automated tests and testing without OCR binaries."""

    def __init__(self, predefined_results: Optional[list[OCRResult]] = None):
        self.predefined_results = predefined_results or []
        self._call_count = 0

    def is_available(self) -> bool:
        return True

    def verify_malayalam_support(self) -> bool:
        return True

    def extract_text_and_boxes(
        self,
        image: Image.Image | np.ndarray,
        languages: str = "mal+eng",
    ) -> OCRResult:
        if self.predefined_results and self._call_count < len(self.predefined_results):
            res = self.predefined_results[self._call_count]
            self._call_count += 1
            return res

        # Default synthetic extraction with realistic Malayalam and English voter card text
        synthetic_text = (
            "123 KLM1452398\n"
            "പേര്: സുരേഷ് കുമാർ\n"
            "അച്ഛന്റെ പേര്: വാസുദേവൻ\n"
            "വീട്ടു നമ്പർ: 14/230 കാവ്യഭവൻ\n"
            "പ്രായം: 42 ലിംഗം: പുരുഷൻ"
        )
        boxes = [
            OCRTextBox("123", 0.98, (10, 10, 30, 20)),
            OCRTextBox("KLM1452398", 0.95, (180, 10, 90, 20)),
            OCRTextBox("പേര്:", 0.92, (10, 35, 40, 20)),
            OCRTextBox("സുരേഷ്", 0.94, (55, 35, 60, 20)),
            OCRTextBox("കുമാർ", 0.93, (120, 35, 50, 20)),
            OCRTextBox("അച്ഛന്റെ", 0.91, (10, 60, 60, 20)),
            OCRTextBox("പേര്:", 0.91, (75, 60, 40, 20)),
            OCRTextBox("വാസുദേവൻ", 0.94, (120, 60, 80, 20)),
            OCRTextBox("വീട്ടു", 0.90, (10, 85, 40, 20)),
            OCRTextBox("നമ്പർ:", 0.90, (55, 85, 50, 20)),
            OCRTextBox("14/230", 0.95, (110, 85, 50, 20)),
            OCRTextBox("കാവ്യഭവൻ", 0.92, (165, 85, 70, 20)),
            OCRTextBox("പ്രായം:", 0.95, (10, 110, 45, 20)),
            OCRTextBox("42", 0.97, (60, 110, 25, 20)),
            OCRTextBox("ലിംഗം:", 0.94, (100, 110, 45, 20)),
            OCRTextBox("പുരുഷൻ", 0.96, (150, 110, 55, 20)),
        ]
        return OCRResult(
            full_text=synthetic_text,
            boxes=boxes,
            average_confidence=0.94,
            engine_name="mock_ocr",
            language=languages,
        )

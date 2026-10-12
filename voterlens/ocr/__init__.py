"""OCR engine factory and exports."""

from typing import Optional
from voterlens.ocr.engine import BaseOCREngine, OCRResult, OCRTextBox
from voterlens.ocr.mock_engine import MockOCREngine
from voterlens.ocr.paddle_engine import PaddleOCREngine
from voterlens.ocr.tesseract_engine import TesseractOCREngine


def get_ocr_engine(
    engine_type: str = "auto",
    tesseract_cmd: Optional[str] = None,
) -> BaseOCREngine:
    """Factory to retrieve an OCR engine with automatic fallback."""
    eng_type = engine_type.lower().strip()

    if eng_type == "tesseract":
        return TesseractOCREngine(tesseract_cmd=tesseract_cmd)
    elif eng_type == "paddle":
        return PaddleOCREngine()
    elif eng_type == "mock":
        return MockOCREngine()
    elif eng_type == "auto":
        # Try Tesseract first
        tess = TesseractOCREngine(tesseract_cmd=tesseract_cmd)
        if tess.is_available():
            return tess
        # Try PaddleOCR
        paddle = PaddleOCREngine()
        if paddle.is_available():
            return paddle
        # Fallback to Mock
        return MockOCREngine()
    else:
        raise ValueError(f"Unknown OCR engine type '{engine_type}'. Choose 'auto', 'tesseract', 'paddle', or 'mock'.")


__all__ = [
    "BaseOCREngine",
    "OCRResult",
    "OCRTextBox",
    "TesseractOCREngine",
    "PaddleOCREngine",
    "MockOCREngine",
    "get_ocr_engine",
]

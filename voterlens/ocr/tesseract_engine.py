"""Tesseract OCR implementation supporting Malayalam and English."""

import logging
import shutil
from typing import Optional
import numpy as np
from PIL import Image
import pytesseract
from pytesseract import Output

from voterlens.ocr.engine import BaseOCREngine, OCRResult, OCRTextBox

logger = logging.getLogger(__name__)


class TesseractOCREngine(BaseOCREngine):
    """Tesseract implementation with support for multilingual (Malayalam + English) rolls."""

    def __init__(self, tesseract_cmd: Optional[str] = None):
        if tesseract_cmd:
            pytesseract.pytesseract.tesseract_cmd = tesseract_cmd
        self._available: Optional[bool] = None

    def is_available(self) -> bool:
        if self._available is not None:
            return self._available
        try:
            ver = pytesseract.get_tesseract_version()
            self._available = True
            logger.info("Tesseract found: %s", ver)
        except Exception:
            self._available = False
            logger.warning("Tesseract binary not found on PATH.")
        return self._available

    def verify_malayalam_support(self) -> bool:
        """Check if Malayalam traineddata ('mal') is present in Tesseract tessdata."""
        if not self.is_available():
            return False
        try:
            installed = pytesseract.get_languages()
            return "mal" in installed
        except Exception:
            return False

    def extract_text_and_boxes(
        self,
        image: Image.Image | np.ndarray,
        languages: str = "mal+eng",
    ) -> OCRResult:
        if not self.is_available():
            raise RuntimeError(
                "Tesseract is not available or not properly configured. "
                "Ensure tesseract binary and language packs ('mal', 'eng') are installed."
            )

        # Enforce strict Malayalam support requirement for Kerala rolls
        if "mal" in languages.split("+") and not self.verify_malayalam_support():
            raise RuntimeError(
                "CRITICAL OCR ERROR: Required Malayalam language model ('mal.traineddata') "
                "is NOT installed in Tesseract tessdata. Silent fallback to English-only OCR "
                "is strictly prohibited for Kerala electoral rolls."
            )

        if isinstance(image, np.ndarray):
            pil_img = Image.fromarray(image)
        else:
            pil_img = image

        try:
            installed_langs = pytesseract.get_languages()
        except Exception:
            installed_langs = ["eng"]

        selected_langs = [
            req.strip() for req in languages.split("+") if req.strip() in installed_langs
        ]
        if not selected_langs:
            selected_langs = ["eng"]

        lang_str = "+".join(selected_langs)

        # Page segmentation mode 11: Sparse text. Finds all text elements across multi-column layout
        config = r"--oem 1 --psm 11"

        data = pytesseract.image_to_data(pil_img, lang=lang_str, config=config, output_type=Output.DICT)
        
        boxes: list[OCRTextBox] = []
        text_parts: list[str] = []
        confidences: list[float] = []

        n_boxes = len(data["text"])
        for i in range(n_boxes):
            text = data["text"][i].strip()
            conf = float(data["conf"][i])
            if text and conf >= 0:
                box = (
                    int(data["left"][i]),
                    int(data["top"][i]),
                    int(data["width"][i]),
                    int(data["height"][i]),
                )
                boxes.append(
                    OCRTextBox(
                        text=text,
                        confidence=conf / 100.0,
                        box=box,
                        line_num=int(data["line_num"][i]),
                        word_num=int(data["word_num"][i]),
                    )
                )
                text_parts.append(text)
                confidences.append(conf / 100.0)

        # Preserve line breaks for parser regex and layout fidelity
        full_text = pytesseract.image_to_string(pil_img, lang=lang_str, config=config).strip()
        avg_conf = sum(confidences) / len(confidences) if confidences else 0.0

        return OCRResult(
            full_text=full_text,
            boxes=boxes,
            average_confidence=avg_conf,
            engine_name="tesseract",
            language=lang_str,
            raw_response=data,
        )

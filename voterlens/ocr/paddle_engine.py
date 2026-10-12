"""PaddleOCR implementation supporting multilingual OCR."""

import logging
from typing import Optional
import numpy as np
from PIL import Image

from voterlens.ocr.engine import BaseOCREngine, OCRResult, OCRTextBox

logger = logging.getLogger(__name__)


class PaddleOCREngine(BaseOCREngine):
    """PaddleOCR engine adapter with dynamic loading."""

    def __init__(self, lang: str = "korean"):  # PaddleOCR uses specific language tags
        self.lang = lang
        self._ocr = None
        self._available: Optional[bool] = None

    def is_available(self) -> bool:
        if self._available is not None:
            return self._available
        try:
            import paddleocr  # noqa: F401
            self._available = True
        except ImportError:
            self._available = False
            logger.info("PaddleOCR not installed in this environment.")
        return self._available

    def verify_malayalam_support(self) -> bool:
        """Check if PaddleOCR supports Malayalam."""
        return self.is_available()

    def _get_ocr(self):
        if self._ocr is None:
            from paddleocr import PaddleOCR
            self._ocr = PaddleOCR(use_angle_cls=True, lang="ml" if self.lang == "mal" else "en")
        return self._ocr

    def extract_text_and_boxes(
        self,
        image: Image.Image | np.ndarray,
        languages: str = "mal+eng",
    ) -> OCRResult:
        if not self.is_available():
            raise RuntimeError(
                "PaddleOCR is not installed. To use PaddleOCR, install paddlepaddle and paddleocr."
            )

        if isinstance(image, Image.Image):
            img_arr = np.array(image)
        else:
            img_arr = image

        ocr = self._get_ocr()
        result = ocr.ocr(img_arr, cls=True)

        boxes: list[OCRTextBox] = []
        text_parts: list[str] = []
        confidences: list[float] = []

        if result and result[0]:
            for line in result[0]:
                poly = line[0]  # [[x1, y1], [x2, y2], [x3, y3], [x4, y4]]
                text, conf = line[1]
                x_min = int(min(p[0] for p in poly))
                y_min = int(min(p[1] for p in poly))
                x_max = int(max(p[0] for p in poly))
                y_max = int(max(p[1] for p in poly))
                w = x_max - x_min
                h = y_max - y_min

                boxes.append(
                    OCRTextBox(
                        text=text.strip(),
                        confidence=float(conf),
                        box=(x_min, y_min, w, h),
                    )
                )
                text_parts.append(text.strip())
                confidences.append(float(conf))

        full_text = " ".join(text_parts)
        avg_conf = sum(confidences) / len(confidences) if confidences else 0.0

        return OCRResult(
            full_text=full_text,
            boxes=boxes,
            average_confidence=avg_conf,
            engine_name="paddleocr",
            language=languages,
            raw_response=result,
        )

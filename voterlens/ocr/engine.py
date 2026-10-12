"""Modular OCR interface and abstraction."""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any, Optional
import numpy as np
from PIL import Image


@dataclass
class OCRTextBox:
    """Bounding box and recognized text snippet."""
    text: str
    confidence: float
    box: tuple[int, int, int, int]  # (x, y, width, height)
    line_num: int = 0
    word_num: int = 0


@dataclass
class OCRResult:
    """Consolidated result from an OCR extraction pass."""
    full_text: str
    boxes: list[OCRTextBox] = field(default_factory=list)
    average_confidence: float = 0.0
    engine_name: str = ""
    language: str = ""
    raw_response: Any = None


class BaseOCREngine(ABC):
    """Abstract base class for OCR engines supporting Malayalam and English."""

    @abstractmethod
    def is_available(self) -> bool:
        """Check if engine runtime binaries and models are ready on this machine."""
        pass

    @abstractmethod
    def verify_malayalam_support(self) -> bool:
        """Check if Malayalam language data is installed and ready for OCR."""
        pass

    @abstractmethod
    def extract_text_and_boxes(
        self,
        image: Image.Image | np.ndarray,
        languages: str = "mal+eng",
    ) -> OCRResult:
        """Extract text and bounding boxes from an image or image region."""
        pass

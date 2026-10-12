"""Photograph processing, validation, normalization, and local deterministic storage."""

import logging
from pathlib import Path
from typing import Optional
import numpy as np
from PIL import Image, ImageOps

logger = logging.getLogger(__name__)


class PhotoValidationError(Exception):
    """Raised when a cropped or extracted photograph fails quality/dimension checks."""
    pass


class PhotoProcessor:
    """Validates, normalizes, and deterministically stores voter photographs locally."""

    def __init__(
        self,
        base_photos_dir: Optional[Path] = None,
        target_size: tuple[int, int] = (240, 300),  # width x height standard voter portrait
        min_size: tuple[int, int] = (30, 40),
        min_variance: float = 120.0,  # rejects blank or solid placeholder boxes
    ):
        self.base_photos_dir = base_photos_dir or (Path.cwd() / "photos")
        self.target_size = target_size
        self.min_size = min_size
        self.min_variance = min_variance

    def is_valid_photo(self, image: Image.Image) -> tuple[bool, str]:
        """Verify image meets dimension and content variance criteria."""
        if image is None:
            return False, "Image object is None"

        w, h = image.size
        if w < self.min_size[0] or h < self.min_size[1]:
            return False, f"Image dimensions ({w}x{h}) smaller than minimum ({self.min_size[0]}x{self.min_size[1]})"

        # Content variance check: reject blank boxes, solid white or solid black
        gray = image.convert("L")
        arr = np.array(gray)
        variance = float(np.var(arr))
        if variance < self.min_variance:
            return False, f"Image pixel variance ({variance:.1f}) is too low (blank/solid box detected)"

        # Reject official withheld photo placeholder text ("ഫോട്ടോ ലഭ്യമാണ്‌" / "Photo Available")
        try:
            import pytesseract
            import re
            p_txt = pytesseract.image_to_string(image, lang="mal+eng", config="--psm 6").strip()
            if re.search(r"(?:ഫോട്ടോ|ലഭ്യമാണ്|photo|available)", p_txt, re.IGNORECASE):
                return False, "Official electoral roll withheld photo placeholder ('ഫോട്ടോ ലഭ്യമാണ്‌')"
        except Exception:
            pass

        return True, "Valid"

    def normalize_photo(self, image: Image.Image) -> Image.Image:
        """Standardize image to RGB, auto-orient, and fit to uniform portrait size."""
        # Auto rotate based on EXIF if present
        img = ImageOps.exif_transpose(image)
        if img.mode != "RGB":
            img = img.convert("RGB")

        # High-quality thumbnail/resize
        resized = ImageOps.fit(img, self.target_size, method=Image.Resampling.LANCZOS)
        return resized

    def save_voter_photo(
        self,
        image: Image.Image,
        roll_version_id: str,
        voter_id: str,
    ) -> Optional[str]:
        """Validate, normalize, and save image to photos/<roll_version_id>/<voter_id>.jpg.
        
        Returns the relative path string, or None if the image is invalid.
        """
        valid, reason = self.is_valid_photo(image)
        if not valid:
            logger.debug("Voter %s photo skipped: %s", voter_id, reason)
            return None

        # Build deterministic directory structure
        roll_dir = self.base_photos_dir / roll_version_id
        roll_dir.mkdir(parents=True, exist_ok=True)

        file_name = f"{voter_id}.jpg"
        abs_target_path = roll_dir / file_name

        normalized = self.normalize_photo(image)
        normalized.save(abs_target_path, "JPEG", quality=85, optimize=True)

        # Store relative path for portability across environments
        return f"photos/{roll_version_id}/{file_name}"

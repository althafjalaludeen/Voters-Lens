"""Tests for photo extraction, variance validation, and deterministic storage."""

from pathlib import Path
import numpy as np
from PIL import Image

from voterlens.photographs.processor import PhotoProcessor


def test_photo_processor_rejects_blank_placeholder(temp_photo_processor: PhotoProcessor):
    """Verify solid color or low-variance placeholder boxes are rejected."""
    # Solid white placeholder (variance 0.0)
    white_box = Image.new("RGB", (100, 120), color=(255, 255, 255))
    valid, reason = temp_photo_processor.is_valid_photo(white_box)
    assert not valid
    assert "variance" in reason.lower()


def test_photo_processor_normalizes_and_saves(temp_photo_processor: PhotoProcessor):
    """Verify genuine portrait image is normalized to standard portrait and saved locally."""
    # Create image with gradients/features (high variance)
    arr = np.random.randint(50, 200, (120, 100, 3), dtype=np.uint8)
    portrait = Image.fromarray(arr)

    valid, reason = temp_photo_processor.is_valid_photo(portrait)
    assert valid

    rel_path = temp_photo_processor.save_voter_photo(
        image=portrait,
        roll_version_id="roll_123",
        voter_id="v_00001",
    )
    assert rel_path == "photos/roll_123/v_00001.jpg"

    # Verify physical file existence and dimensions
    abs_path = temp_photo_processor.base_photos_dir / "roll_123" / "v_00001.jpg"
    assert abs_path.exists()

    with Image.open(abs_path) as saved_img:
        assert saved_img.size == temp_photo_processor.target_size

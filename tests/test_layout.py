"""Unit tests for Phase 1.5 layout profiling and adaptive grid analysis."""

from PIL import Image, ImageDraw
from voterlens.pdf.layout import (
    LayoutAnalyzer,
    LayoutProfile,
    STANDARD_KERALA_3X10,
    SUPPLEMENTARY_KERALA_2X10,
)


def test_layout_profiles():
    """Verify standard and supplementary layout profile parameters."""
    std = STANDARD_KERALA_3X10
    assert std.columns == 3
    assert std.rows == 10
    assert std.name == "ECI_KERALA_STANDARD_3X10"

    supp = SUPPLEMENTARY_KERALA_2X10
    assert supp.columns == 2
    assert supp.rows == 10
    assert supp.name == "ECI_KERALA_SUPPLEMENTARY_2X10"


def test_layout_analyzer_on_synthetic_grid():
    """Verify layout analyzer detects bounding cards and produces analysis metrics."""
    # Create an image with drawn grid boxes
    img = Image.new("RGB", (600, 800), color=(255, 255, 255))
    draw = ImageDraw.Draw(img)

    # Draw 3 columns x 10 rows boxes
    col_w = 180
    row_h = 70
    for r in range(10):
        for c in range(3):
            x1 = 30 + c * col_w
            y1 = 50 + r * row_h
            draw.rectangle([x1, y1, x1 + col_w - 10, y1 + row_h - 10], outline=(0, 0, 0), width=2)

    analyzer = LayoutAnalyzer(default_profile=STANDARD_KERALA_3X10)
    result = analyzer.analyze_page(img, page_number=0)

    assert result.page_number == 0
    assert result.expected_grid == (3, 10)
    assert result.detected_box_count >= 10
    assert result.is_grid_reliable is True
    assert result.confidence >= 0.5

"""Layout profiling, adaptive grid detection, and layout anomaly validation."""

from dataclasses import dataclass, field
import logging
from typing import Optional
import cv2
import numpy as np
from PIL import Image

logger = logging.getLogger(__name__)


@dataclass
class LayoutProfile:
    """Configurable layout specifications for diverse electoral roll formats."""
    name: str = "ECI_KERALA_STANDARD_3X10"
    columns: int = 3
    rows: int = 10
    content_margin_top: float = 0.07
    content_margin_bottom: float = 0.05
    content_margin_left: float = 0.03
    content_margin_right: float = 0.03
    photo_relative_box: tuple[float, float, float, float] = (0.70, 0.12, 0.98, 0.88)
    text_relative_box: tuple[float, float, float, float] = (0.02, 0.12, 0.69, 0.98)
    header_margin: float = 0.07
    footer_margin: float = 0.05


STANDARD_KERALA_3X10 = LayoutProfile(
    name="ECI_KERALA_STANDARD_3X10",
    columns=3,
    rows=10,
    content_margin_top=0.07,
    content_margin_bottom=0.05,
    content_margin_left=0.03,
    content_margin_right=0.03,
)

SUPPLEMENTARY_KERALA_2X10 = LayoutProfile(
    name="ECI_KERALA_SUPPLEMENTARY_2X10",
    columns=2,
    rows=10,
    photo_relative_box=(0.75, 0.12, 0.98, 0.88),
)


@dataclass
class LayoutAnalysisResult:
    """Report on page visual geometry and grid consistency."""
    page_number: int
    expected_layout: str
    expected_grid: tuple[int, int]  # (cols, rows)
    detected_grid: tuple[int, int]
    detected_box_count: int
    is_grid_reliable: bool
    confidence: float
    mismatch_warning: Optional[str] = None
    detected_rectangles: list[tuple[int, int, int, int]] = field(default_factory=list)


class LayoutAnalyzer:
    """Analyzes page layout geometry using computer vision to detect cards and anomalies."""

    def __init__(self, default_profile: Optional[LayoutProfile] = None):
        self.profile = default_profile or STANDARD_KERALA_3X10

    def analyze_page(
        self,
        page_image: Image.Image,
        page_number: int,
        target_profile: Optional[LayoutProfile] = None,
    ) -> LayoutAnalysisResult:
        """Inspect rendered page lines and contours to verify voter-card grid alignment."""
        profile = target_profile or self.profile
        img_np = np.array(page_image)
        gray = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY) if len(img_np.shape) == 3 else img_np

        h, w = gray.shape

        # Adaptive thresholding to isolate grid lines
        thresh = cv2.adaptiveThreshold(
            gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 15, 2
        )

        # Morphological kernels to detect horizontal and vertical borders
        scale = 30
        h_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (int(w / scale), 1))
        v_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, int(h / scale)))

        h_lines = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, h_kernel)
        v_lines = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, v_kernel)

        table_structure = cv2.add(h_lines, v_lines)

        # Use RETR_EXTERNAL to isolate outer borders of table cells and avoid duplicate inner/outer detections
        contours, _ = cv2.findContours(
            table_structure, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )

        # Expected card dimension thresholds
        expected_cols = profile.columns
        expected_rows = profile.rows
        expected_total = expected_cols * expected_rows

        min_area = (w * h) / (expected_total * 4)
        max_area = (w * h) / 4

        candidate_rects = []
        for c in contours:
            x, y, cw, ch = cv2.boundingRect(c)
            area = cw * ch
            aspect = cw / float(ch) if ch > 0 else 0
            # Card aspect ratio is typically between 1.0 and 3.5
            if min_area < area < max_area and 1.5 < aspect < 3.5:
                candidate_rects.append((x, y, cw, ch))

        detected_count = len(candidate_rects)

        # Estimate rows and columns from detected box centers
        if detected_count >= 6:
            x_centers = sorted([r[0] + r[2] // 2 for r in candidate_rects])
            y_centers = sorted([r[1] + r[3] // 2 for r in candidate_rects])

            # Cluster centers within threshold
            x_clusters = self._cluster_1d(x_centers, threshold=w * 0.08)
            y_clusters = self._cluster_1d(y_centers, threshold=h * 0.05)

            det_cols = len(x_clusters)
            det_rows = len(y_clusters)
        else:
            # Insufficient line detection (possibly non-bordered roll or title/map page)
            det_cols = expected_cols
            det_rows = expected_rows

        # Evaluate reliability
        is_reliable = (
            abs(det_cols - expected_cols) <= 0
            and abs(det_rows - expected_rows) <= 1
        ) or (detected_count == 0)  # zero detected lines may mean borderless layout fallback

        warning = None
        if detected_count >= 6 and not is_reliable:
            warning = (
                f"Layout mismatch detected on page {page_number + 1}: "
                f"Expected {expected_cols}x{expected_rows} grid ({expected_total} cards), "
                f"detected approximately {det_cols}x{det_rows} layout with {detected_count} bounded cells."
            )
            logger.warning(warning)

        confidence = 1.0 if is_reliable else 0.5

        return LayoutAnalysisResult(
            page_number=page_number,
            expected_layout=profile.name,
            expected_grid=(expected_cols, expected_rows),
            detected_grid=(det_cols, det_rows),
            detected_box_count=detected_count,
            is_grid_reliable=is_reliable,
            confidence=confidence,
            mismatch_warning=warning,
            detected_rectangles=candidate_rects,
        )

    @staticmethod
    def _cluster_1d(points: list[int], threshold: float) -> list[int]:
        """Cluster points along 1D axis within a distance threshold."""
        if not points:
            return []
        clusters = [[points[0]]]
        for p in points[1:]:
            if p - clusters[-1][-1] < threshold:
                clusters[-1].append(p)
            else:
                clusters.append([p])
        return [int(sum(c) / len(c)) for c in clusters]

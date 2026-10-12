"""PDF inspection, page rendering, and voter-card layout segmentation."""

from dataclasses import dataclass, field
import io
import logging
from pathlib import Path
from typing import Optional
import cv2
import numpy as np
from PIL import Image
import pymupdf  # PyMuPDF

logger = logging.getLogger(__name__)


@dataclass
class CardRegion:
    """Represents a cropped voter card region from a page."""
    image: Image.Image
    bbox: tuple[int, int, int, int]  # (x, y, w, h)
    page_number: int
    grid_col: int = 0
    grid_row: int = 0


import hashlib
from voterlens.pdf.layout import LayoutProfile, STANDARD_KERALA_3X10


@dataclass
class PDFInspectionResult:
    """Summary of PDF properties before processing."""
    file_path: str
    file_size_bytes: int = 0
    sha256: str = ""
    page_count: int = 0
    is_encrypted: bool = False
    title: str = ""
    author: str = ""
    subject: str = ""
    pdf_version: str = "1.4"
    nature: str = "DIGITAL"  # "DIGITAL", "SCANNED", "MIXED"
    has_digital_text: bool = True
    has_scanned_images: bool = False
    page_dimensions: list[tuple[float, float]] = field(default_factory=list)
    detected_dpi: float = 200.0


class PDFProcessor:
    """Handles PDF loading, rendering, and voter-card grid segmentation."""

    def __init__(self, dpi: int = 200, default_profile: Optional[LayoutProfile] = None):
        self.dpi = dpi
        self.zoom = dpi / 72.0  # 72 is standard PDF DPI
        self.profile = default_profile or STANDARD_KERALA_3X10

    def inspect(self, pdf_path: str | Path) -> PDFInspectionResult:
        """Inspect PDF file, compute SHA-256, and determine if digital, scanned, or mixed."""
        path = Path(pdf_path)
        file_size = path.stat().st_size if path.exists() else 0

        # Compute SHA-256
        hasher = hashlib.sha256()
        with open(path, "rb") as f:
            while chunk := f.read(65536):
                hasher.update(chunk)
        sha256_hash = hasher.hexdigest()

        doc = pymupdf.open(str(path))
        meta = doc.metadata or {}

        page_count = len(doc)
        digital_pages = 0
        scanned_pages = 0
        dimensions: list[tuple[float, float]] = []

        sample_pages = range(min(page_count, 5))
        for p_idx in sample_pages:
            p = doc[p_idx]
            rect = p.rect
            dimensions.append((rect.width, rect.height))
            text = p.get_text().strip()
            images = p.get_images()

            if len(text) > 80:
                digital_pages += 1
            if len(images) > 0 and len(text) < 40:
                scanned_pages += 1

        if digital_pages > 0 and scanned_pages == 0:
            nature = "DIGITAL"
        elif scanned_pages > 0 and digital_pages == 0:
            nature = "SCANNED"
        else:
            nature = "MIXED" if (digital_pages > 0 or scanned_pages > 0) else "DIGITAL"

        result = PDFInspectionResult(
            file_path=str(path),
            file_size_bytes=file_size,
            sha256=sha256_hash,
            page_count=page_count,
            is_encrypted=doc.is_encrypted,
            title=meta.get("title", "") or "",
            author=meta.get("author", "") or "",
            subject=meta.get("subject", "") or "",
            pdf_version=getattr(doc, "version", "1.4") or "1.4",
            nature=nature,
            has_digital_text=(digital_pages > 0),
            has_scanned_images=(scanned_pages > 0),
            page_dimensions=dimensions,
            detected_dpi=float(self.dpi),
        )
        doc.close()
        return result

    def render_page(self, doc: pymupdf.Document, page_number: int) -> Image.Image:
        """Render a specific PDF page to a high-resolution PIL Image."""
        page = doc[page_number]
        matrix = pymupdf.Matrix(self.zoom, self.zoom)
        pix = page.get_pixmap(matrix=matrix, alpha=False)
        img = Image.open(io.BytesIO(pix.tobytes("png")))
        return img

    def segment_grid_cards(
        self,
        page_image: Image.Image,
        page_number: int,
        cols: int = 3,
        rows: int = 10,
        content_margin_top: float = 0.032,   # Header margin ratio
        content_margin_bottom: float = 0.030, # Footer margin ratio
        content_margin_left: float = 0.022,
        content_margin_right: float = 0.024,
        profile: Optional[LayoutProfile] = None,
    ) -> list[CardRegion]:
        """Segment an electoral page into individual voter card regions using adaptive CV or configured LayoutProfile."""
        prof = profile or self.profile
        if prof:
            cols = cols if cols != 3 else prof.columns
            rows = rows if rows != 10 else prof.rows
            content_margin_top = prof.content_margin_top
            content_margin_bottom = prof.content_margin_bottom
            content_margin_left = prof.content_margin_left
            content_margin_right = prof.content_margin_right

        w, h = page_image.size

        # Try adaptive line detection first for precise cell alignment
        try:
            img_np = np.array(page_image)
            gray = cv2.cvtColor(img_np, cv2.COLOR_RGB2GRAY) if len(img_np.shape) == 3 else img_np
            thresh = cv2.adaptiveThreshold(
                gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY_INV, 15, 2
            )
            scale = 30
            h_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (int(w / scale), 1))
            v_kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, int(h / scale)))
            h_lines = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, h_kernel)
            v_lines = cv2.morphologyEx(thresh, cv2.MORPH_OPEN, v_kernel)
            table_structure = cv2.add(h_lines, v_lines)
            contours, _ = cv2.findContours(table_structure, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

            detected_rects = []
            for c in contours:
                x, y, cw, ch = cv2.boundingRect(c)
                area = cw * ch
                aspect = cw / float(ch) if ch > 0 else 0
                if 400 < cw < 600 and 160 < ch < 250 and 1.8 < aspect < 3.2:
                    detected_rects.append((x, y, cw, ch))

            if 0 < len(detected_rects) <= rows * cols:
                # Sort row-by-row, then column-by-column
                detected_rects = sorted(
                    detected_rects,
                    key=lambda r: (round(r[1] / 50) * 50, r[0])
                )
                cards: list[CardRegion] = []
                for idx, (bx, by, bw, bh) in enumerate(detected_rects):
                    pad_x = int(bw * 0.01)
                    pad_y = int(bh * 0.01)
                    card_crop = page_image.crop(
                        (bx + pad_x, by + pad_y, bx + bw - pad_x, by + bh - pad_y)
                    )
                    cards.append(
                        CardRegion(
                            image=card_crop,
                            bbox=(bx + pad_x, by + pad_y, bw - 2 * pad_x, bh - 2 * pad_y),
                            page_number=page_number,
                            grid_col=idx % cols,
                            grid_row=idx // cols,
                        )
                    )
                return cards
        except Exception as e:
            logger.debug("Adaptive table segmentation skipped: %s", e)

        # Fallback: profile-based mathematical grid
        left = int(w * content_margin_left)
        right = int(w * (1.0 - content_margin_right))
        top = int(h * content_margin_top)
        bottom = int(h * (1.0 - content_margin_bottom))

        grid_width = right - left
        grid_height = bottom - top

        card_w = grid_width / cols
        card_h = grid_height / rows

        cards = []
        for r in range(rows):
            for c in range(cols):
                c_x1 = int(left + (c * card_w))
                c_y1 = int(top + (r * card_h))
                c_x2 = int(left + ((c + 1) * card_w))
                c_y2 = int(top + ((r + 1) * card_h))

                pad_x = int(card_w * 0.01)
                pad_y = int(card_h * 0.01)
                box = (
                    c_x1 + pad_x,
                    c_y1 + pad_y,
                    (c_x2 - c_x1) - (2 * pad_x),
                    (c_y2 - c_y1) - (2 * pad_y),
                )

                card_crop = page_image.crop((c_x1 + pad_x, c_y1 + pad_y, c_x2 - pad_x, c_y2 - pad_y))
                cards.append(
                    CardRegion(
                        image=card_crop,
                        bbox=box,
                        page_number=page_number,
                        grid_col=c,
                        grid_row=r,
                    )
                )

        return cards

    def extract_card_digital_text(
        self, page: pymupdf.Page, bbox_pt: tuple[float, float, float, float]
    ) -> str:
        """Extract digital text within a card rectangle if present in the PDF layer."""
        rect = pymupdf.Rect(*bbox_pt)
        return page.get_text("text", clip=rect).strip()

    def detect_and_segment_cards(
        self,
        page_image: Image.Image,
        page_number: int,
        cols: int = 3,
        rows: int = 10,
    ) -> list[CardRegion]:
        """Detect and segment voter cards using adaptive grid segmentation."""
        return self.segment_grid_cards(page_image, page_number=page_number, cols=cols, rows=rows)

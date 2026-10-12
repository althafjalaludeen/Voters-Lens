"""Voter card and photograph extraction from PDF pages and rendered pixmaps."""

import io
import logging
from typing import Optional
import numpy as np
from PIL import Image

logger = logging.getLogger(__name__)


class PhotoExtractor:
    """Extracts voter portrait sub-images from PDF pages or rendered page buffers."""

    def __init__(self):
        pass

    def crop_photo_from_card(
        self,
        card_image: Image.Image,
        rel_box: tuple[float, float, float, float] = (0.70, 0.15, 0.98, 0.85),
    ) -> Optional[Image.Image]:
        """Extract photograph from standard voter card layout.
        
        rel_box: (left_ratio, top_ratio, right_ratio, bottom_ratio)
        In standard Kerala electoral roll voter cards, photograph is on the right 28-30%.
        """
        w, h = card_image.size
        left = int(w * rel_box[0])
        top = int(h * rel_box[1])
        right = int(w * rel_box[2])
        bottom = int(h * rel_box[3])

        if right <= left or bottom <= top:
            return None

        cropped = card_image.crop((left, top, right, bottom))
        return cropped

    def extract_embedded_images_from_page(self, pdf_page, pdf_doc) -> list[Image.Image]:
        """Extract embedded bitmap images directly from PyMuPDF page if available."""
        extracted: list[Image.Image] = []
        try:
            image_list = pdf_page.get_images(full=True)
            for img_info in image_list:
                xref = img_info[0]
                base_image = pdf_doc.extract_image(xref)
                image_bytes = base_image["image"]
                pil_img = Image.open(io.BytesIO(image_bytes))
                extracted.append(pil_img)
        except Exception as e:
            logger.debug("Failed extracting embedded images directly: %s", e)
        return extracted

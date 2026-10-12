"""Generate a realistic synthetic Kerala Electoral Roll PDF for offline testing and pipeline demonstration."""

from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import pymupdf


def create_synthetic_portrait(name: str, color: tuple[int, int, int]) -> bytes:
    """Create a synthetic voter portrait image with non-zero pixel variance."""
    w, h = 120, 150
    img = Image.new("RGB", (w, h), color=(240, 240, 240))
    draw = ImageDraw.Draw(img)

    # Draw head / silhouette
    draw.ellipse([30, 20, 90, 85], fill=color, outline=(40, 40, 40), width=2)
    # Draw body / shoulders
    draw.polygon([(10, 150), (30, 95), (90, 95), (110, 150)], fill=color, outline=(40, 40, 40))
    # Eyes
    draw.ellipse([45, 45, 55, 55], fill=(255, 255, 255))
    draw.ellipse([65, 45, 75, 55], fill=(255, 255, 255))
    draw.ellipse([48, 48, 52, 52], fill=(20, 20, 20))
    draw.ellipse([68, 48, 72, 52], fill=(20, 20, 20))

    import io
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


def generate_synthetic_roll_pdf(output_path: str | Path, num_voters: int = 6) -> Path:
    """Generate a multi-page synthetic Kerala electoral roll PDF."""
    out_file = Path(output_path)
    out_file.parent.mkdir(parents=True, exist_ok=True)

    doc = pymupdf.open()

    # Detect font for Indic / Malayalam support
    font_kwargs = {}
    nirmala_path = Path("C:/Windows/Fonts/Nirmala.ttc")
    if nirmala_path.exists():
        font_kwargs = {"fontname": "nirmala", "fontfile": str(nirmala_path)}

    # --- Page 1: Title / Summary Page ---
    p1 = doc.new_page(width=595, height=842)  # A4 size
    p1.insert_text(
        (50, 60),
        "ELECTION COMMISSION OF INDIA - ELECTORAL ROLL 2026",
        fontsize=16,
        color=(0, 0, 0),
        **font_kwargs,
    )
    p1.insert_text(
        (50, 90),
        "State: Kerala  |  District: Pathanamthitta  |  Assembly Constituency: 112 - Thiruvalla",
        fontsize=11,
        color=(0.2, 0.2, 0.2),
        **font_kwargs,
    )
    p1.insert_text(
        (50, 120),
        "ഭാഗം നമ്പർ (Part No): 42  |  വിഭാഗം നമ്പർ (Section No): 1  |  Section Name: Market Junction West",
        fontsize=11,
        color=(0.2, 0.2, 0.2),
        **font_kwargs,
    )
    p1.insert_text(
        (50, 150),
        "പോളിംഗ് സ്റ്റേഷൻ (Polling Station): Govt Higher Secondary School, Thiruvalla East",
        fontsize=11,
        color=(0.2, 0.2, 0.2),
        **font_kwargs,
    )
    p1.insert_text(
        (50, 180),
        "Publication Date: 05-01-2026  |  Roll Type: GENERAL DRAFT ROLL 2026",
        fontsize=10,
        color=(0.4, 0.4, 0.4),
        **font_kwargs,
    )
    p1.draw_rect(pymupdf.Rect(45, 45, 550, 210), color=(0.1, 0.3, 0.6), width=1.5)

    # --- Page 2: Blank or Map Summary ---
    p2 = doc.new_page(width=595, height=842)
    p2.insert_text((50, 60), "SECTION MAP & POLLING STATION DETAILS", fontsize=14, **font_kwargs)
    p2.draw_rect(pymupdf.Rect(50, 80, 545, 400), color=(0.7, 0.7, 0.7), width=1)
    p2.insert_text((200, 220), "[POLLING AREA LAYOUT MAP]", fontsize=12, color=(0.5, 0.5, 0.5), **font_kwargs)

    # --- Page 3: Voter Cards Grid Page ---
    p3 = doc.new_page(width=595, height=842)
    p3.insert_text(
        (50, 35),
        "ഭാഗം നമ്പർ: 42  വിഭാഗം: 1 - Market Junction West  (നിയമസഭാ മണ്ഡലം: 112 - തിരുവല്ല)",
        fontsize=10,
        color=(0, 0, 0),
        **font_kwargs,
    )

    # Synthetic voter definitions
    synthetic_voters = [
        {
            "serial": 1,
            "epic": "KLM1092831",
            "name": "സുരേഷ് കുമാർ (Suresh Kumar)",
            "rel_label": "അച്ഛന്റെ പേര്: വാസുദേവൻ",
            "house": "12/45A ശാന്തിനിലയം",
            "age_gender": "പ്രായം: 42  ലിംഗം: പുരുഷൻ",
            "color": (60, 90, 180),
        },
        {
            "serial": 2,
            "epic": "KLM1092832",
            "name": "ഫാത്തിമ ബീവി (Fathima Beevi)",
            "rel_label": "ഭർത്താവിന്റെ പേര്: അബ്ദുൾ റഹ്മാൻ",
            "house": "14/102 ബൈത്തുൽ നൂറ",
            "age_gender": "പ്രായം: 38  ലിംഗം: സ്ത്രീ",
            "color": (180, 70, 90),
        },
        {
            "serial": 3,
            "epic": "KLM1092833",
            "name": "ജോർജ്ജ് തോമസ് (George Thomas)",
            "rel_label": "അച്ഛന്റെ പേര്: തോമസ് ജോസഫ്",
            "house": "18/90 സെന്റ് മേരീസ് കോട്ടേജ്",
            "age_gender": "പ്രായം: 55  ലിംഗം: പുരുഷൻ",
            "color": (70, 140, 80),
        },
        {
            "serial": 4,
            "epic": "KLM1092834",
            "name": "ലക്ഷ്മി പ്രിയ (Lakshmi Priya)",
            "rel_label": "അമ്മയുടെ പേര്: സരസ്വതി അമ്മ",
            "house": "20/15 കൃഷ്ണകൃപ",
            "age_gender": "പ്രായം: 24  ലിംഗം: സ്ത്രീ",
            "color": (150, 80, 160),
        },
        {
            "serial": 5,
            "epic": "KLM1092835",
            "name": "മുഹമ്മദ് റഫീഖ് (Muhammed Rafeeq)",
            "rel_label": "അച്ഛന്റെ പേര്: അബ്ദുൾ ഖാദർ",
            "house": "22/410 അൽ ഫലാഹ്",
            "age_gender": "പ്രായം: 31  ലിംഗം: പുരുഷൻ",
            "color": (180, 120, 50),
        },
        {
            "serial": 6,
            "epic": "KLM1092836",
            "name": "അഞ്ജലി നായർ (Anjali Nair)",
            "rel_label": "ഭർത്താവിന്റെ പേര്: പ്രശാന്ത് കുമാർ",
            "house": "25/88 പുഷ്പകഭവനം",
            "age_gender": "പ്രായം: 29  ലിംഗം: സ്ത്രീ",
            "color": (50, 150, 150),
        },
    ]

    # Content margins matching PDFProcessor default margins:
    # content_margin_top=0.07, content_margin_bottom=0.05, left=0.03, right=0.03
    page_w, page_h = 595, 842
    left_m = page_w * 0.03
    right_m = page_w * (1.0 - 0.03)
    top_m = page_h * 0.07
    bottom_m = page_h * (1.0 - 0.05)

    cols = 3
    rows = 10  # standard 30 card grid
    card_w = (right_m - left_m) / cols
    card_h = (bottom_m - top_m) / rows

    for idx, vdata in enumerate(synthetic_voters[:num_voters]):
        c = idx % cols
        r = idx // cols

        x1 = left_m + (c * card_w)
        y1 = top_m + (r * card_h)
        x2 = x1 + card_w
        y2 = y1 + card_h

        card_rect = pymupdf.Rect(x1, y1, x2, y2)
        p3.draw_rect(card_rect, color=(0.4, 0.4, 0.4), width=0.8)

        # Serial number and EPIC on top header line
        header_text = f"{vdata['serial']}    {vdata['epic']}"
        p3.insert_text((x1 + 6, y1 + 13), header_text, fontsize=8.5, color=(0, 0, 0), **font_kwargs)

        # Voter Details
        p3.insert_text((x1 + 6, y1 + 25), f"പേര്: {vdata['name']}", fontsize=7.5, color=(0, 0, 0), **font_kwargs)
        p3.insert_text((x1 + 6, y1 + 37), vdata["rel_label"], fontsize=7.0, color=(0, 0, 0), **font_kwargs)
        p3.insert_text((x1 + 6, y1 + 49), f"വീട്ടു നമ്പർ: {vdata['house']}", fontsize=7.0, color=(0, 0, 0), **font_kwargs)
        p3.insert_text((x1 + 6, y1 + 61), vdata["age_gender"], fontsize=7.5, color=(0, 0, 0), **font_kwargs)

        # Insert portrait on right 28% of the card
        photo_rect = pymupdf.Rect(x1 + (card_w * 0.70), y1 + 12, x2 - 5, y2 - 6)
        portrait_bytes = create_synthetic_portrait(vdata["name"], vdata["color"])
        p3.insert_image(photo_rect, stream=portrait_bytes)

    doc.save(str(out_file))
    doc.close()
    return out_file


if __name__ == "__main__":
    out = generate_synthetic_roll_pdf("tests/test-data/synthetic_kerala_roll.pdf")
    print(f"Generated synthetic roll: {out}")

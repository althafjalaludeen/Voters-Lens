"""Electoral roll parser extracting structured voter cards from OCR and layout blocks."""

from dataclasses import dataclass, field
import re
from typing import Any, Optional

from voterlens.normalizer.text_normalizer import (
    normalize_epic,
    normalize_gender,
    normalize_house_number,
    normalize_name,
    normalize_relative_type,
)


@dataclass
class ParsedVoterRecord:
    """Structured voter record extracted from a voter card."""
    serial_number: int
    epic_number: str
    name: str
    relative_name: str
    relative_type: str
    house_number: str
    age: int
    gender: str
    part_number: str = ""
    section_number: str = ""
    section_name: str = ""
    polling_station_name: str = ""
    polling_station_address: str = ""
    normalized_name: str = ""
    normalized_relative_name: str = ""
    normalized_house_number: str = ""
    photo_box: Optional[tuple[int, int, int, int]] = None
    ocr_confidence: Optional[float] = None
    raw_text: str = ""
    extra_fields: dict[str, Any] = field(default_factory=dict)


# Regex patterns accommodating Malayalam, English, and OCR artifacts
NAME_PATTERNS = [
    re.compile(r"(?:പേര്|പേരു്|പേർ|പേര്‌|പേര്‍|name)\s*[:;+\-\.]\s*([^\n\r]+)", re.IGNORECASE),
    re.compile(r"(?:^|\n)\s*(?:പേര്|പേരു്|പേർ|പേര്‌|പേര്‍)\s+([^\n\r]+)", re.IGNORECASE),
]

RELATIVE_PATTERNS = [
    (
        "FATHER",
        re.compile(
            r"(?:അച്ഛന്റെ\s*പേര്|അഛന്റെ\s*പേര്|പിതാവിൻ്റെ\s*പേര്|പിതാവിന്റെ\s*പേര്|പിതാവ്|father['’]?s?\s*name)\s*[:;+\-\.]\s*([^\n\r]+)",
            re.IGNORECASE,
        ),
    ),
    (
        "HUSBAND",
        re.compile(
            r"(?:ഭർത്താവിന്റെ\s*പേര്|ഭര്ത്താവിന്റെ\s*പേര്|ഭർത്താവ്|ഭര്ത്താവ്|husband['’]?s?\s*name)\s*[:;+\-\.]\s*([^\n\r]+)",
            re.IGNORECASE,
        ),
    ),
    (
        "MOTHER",
        re.compile(
            r"(?:അമ്മയുടെ\s*പേര്|മാതാവിൻ്റെ\s*പേര്|മാതാവിന്റെ\s*പേര്|മാതാവ്|mother['’]?s?\s*name)\s*[:;+\-\.]\s*([^\n\r]+)",
            re.IGNORECASE,
        ),
    ),
    (
        "OTHER",
        re.compile(
            r"(?:മറ്റുള്ളവരുടെ\s*പേര്|മറ്റുള്ളവർ|രക്ഷാകർത്താവ്|രക്ഷാകര്ത്താവ്|guardian['’]?s?\s*name|other['’]?s?\s*name)\s*[:;+\-\.]\s*([^\n\r]+)",
            re.IGNORECASE,
        ),
    ),
]

HOUSE_PATTERNS = [
    re.compile(
        r"(?:വീട്ടു\s*നമ്പർ|വിട്ടു\s*നമ്പർ|വിട്ടു\s*നമ്പര്|വീട്ടു\s*നമ്പര്|വീടു\s*നമ്പര്|വീട്ടു\s*നം|വീട്ടുപേര്|വീട്ടു\s*നന്പര്|house\s*no\.?|h\.?no\.?|house\s*name)\s*[:;+\-\.]\s*([^\n\r]+)",
        re.IGNORECASE,
    ),
]

AGE_GENDER_PATTERNS = [
    # Malayalam: പ്രായം: 42 ലിംഗം: പുരുഷൻ
    re.compile(
        r"(?:പ്രായം|age)\s*[:;+\-\.]\s*(\d{1,3})\s*(?:ലിംഗം|sex|gender)\s*[:;+\-\.]\s*([^\s\n\r]+)",
        re.IGNORECASE,
    ),
    # Separate Age
    re.compile(r"(?:പ്രായം|age)\s*[:;+\-\.]\s*(\d{1,3})", re.IGNORECASE),
]

GENDER_STANDALONE = re.compile(
    r"(?:ലിംഗം|sex|gender)\s*[:;+\-\.]\s*([^\s\n\r]+)", re.IGNORECASE
)

# EPIC Pattern in voter box
EPIC_IN_TEXT_PATTERN = re.compile(
    r"\b([A-Z0-9]{2,4}\s*\d{6,8}|[A-Z]{2,3}/\d{1,3}/\d{1,3}/\d{1,7})\b", re.IGNORECASE
)

# Serial number at card beginning (e.g. "123 KLM1452398" or "123\n")
SERIAL_IN_TEXT_PATTERN = re.compile(r"^\s*(\d{1,4})\b")


class VoterParser:
    """Parser to convert OCR card text and metadata into structured ParsedVoterRecord."""

    def __init__(self):
        pass

    def parse_card_text(
        self,
        card_text: str,
        default_meta: Optional[dict[str, Any]] = None,
        confidence: Optional[float] = None,
        photo_box: Optional[tuple[int, int, int, int]] = None,
    ) -> Optional[ParsedVoterRecord]:
        """Parse text from a single voter card block into structured voter fields."""
        if not card_text or not card_text.strip():
            return None

        meta = default_meta or {}
        # Clean formatting characters (ZWNJ, ZWJ, BOM) for robust regex matching
        text = re.sub(r"[\u200b-\u200f\ufeff]", "", card_text.strip())
        lines = [line.strip() for line in text.splitlines() if line.strip()]

        # 1. Serial number
        serial_no = 0
        serial_match = SERIAL_IN_TEXT_PATTERN.search(text)
        if serial_match:
            try:
                serial_no = int(serial_match.group(1))
            except ValueError:
                serial_no = 0
        if serial_no == 0:
            for l in lines[:2]:
                m_s = re.match(r"^(\d{1,4})$", l.strip())
                if m_s:
                    serial_no = int(m_s.group(1))
                    break

        # 2. EPIC Number
        epic_match = EPIC_IN_TEXT_PATTERN.search(text)
        raw_epic = epic_match.group(1).replace(" ", "") if epic_match else ""
        clean_epic = normalize_epic(raw_epic)

        # 3. Name
        name = ""
        for pat in NAME_PATTERNS:
            m = pat.search(text)
            if m:
                # Clean any stray trailing label tokens
                cand = m.group(1).split("അച്ഛ")[0].split("ഭർത്താ")[0].split("ഭര്ത്താ")[0].split("മാതാ")[0].split("പിതാ")[0].split("Father")[0].strip()
                cand = re.sub(r"[\:\;\-\+]", "", cand).strip()
                if cand:
                    name = cand
                    break

        # If name not matched by pattern, fallback to line scanning (typically line 2 after serial/epic)
        if not name and len(lines) >= 2:
            for l in lines[1:3]:
                if not any(k in l for k in ["പ്രായം", "ലിംഗം", "വീട്ടു", "വിട്ടു", "Age", "Sex", "House"]):
                    name = re.sub(r"^(?:പേര്|പേരു്|പേർ|പേര്‌|പേര്‍|name)\s*[:;+\-\.]?", "", l, flags=re.IGNORECASE).strip()
                    if name:
                        break

        # 4. Relative Name and Relationship
        relative_name = ""
        rel_type = "OTHER"
        for r_type, pat in RELATIVE_PATTERNS:
            m = pat.search(text)
            if m:
                cand = m.group(1).split("വീട്ടു")[0].split("വിട്ടു")[0].split("വീടു")[0].split("House")[0].split("ഫോട്ടോ")[0].split("പ്രായം")[0].strip()
                cand = re.sub(r"[\:\;\-\+]", "", cand).strip()
                if cand:
                    relative_name = cand
                    rel_type = r_type
                    break

        # 5. House Number / Name
        house_number = ""
        for pat in HOUSE_PATTERNS:
            m = pat.search(text)
            if m:
                cand = m.group(1).split("പ്രായം")[0].split("Age")[0].split("ലിംഗം")[0].split("ഫോട്ടോ")[0].split("ലഭ്യമാണ്")[0].strip()
                cand = re.sub(r"[\:\;\-\+]", "", cand).strip()
                if cand:
                    house_number = cand
                    break

        # 6. Age and Gender
        age = 0
        gender = "UNKNOWN"
        # Try combined Age + Gender pattern
        combined_m = AGE_GENDER_PATTERNS[0].search(text)
        if combined_m:
            try:
                age = int(combined_m.group(1))
            except ValueError:
                age = 0
            gender = normalize_gender(combined_m.group(2))
        else:
            # Standalone age
            age_m = AGE_GENDER_PATTERNS[1].search(text)
            if age_m:
                try:
                    age = int(age_m.group(1))
                except ValueError:
                    age = 0
            # Standalone gender
            gen_m = GENDER_STANDALONE.search(text)
            if gen_m:
                gender = normalize_gender(gen_m.group(1))

        if gender in ["UNKNOWN", ""]:
            if any(k in text for k in ["സ്ത്രീ", "സ്തീ", "സ്ത"]) or "female" in text.lower():
                gender = "F"
            elif any(k in text for k in ["പുരുഷ", "ആണ്"]) or "male" in text.lower():
                gender = "M"

        # Apply normalizations
        norm_name = normalize_name(name)
        norm_rel_name = normalize_name(relative_name)
        norm_house = normalize_house_number(house_number)

        return ParsedVoterRecord(
            serial_number=serial_no,
            epic_number=clean_epic,
            name=name,
            relative_name=relative_name,
            relative_type=rel_type,
            house_number=house_number,
            age=age,
            gender=gender,
            part_number=str(meta.get("part_number", "")),
            section_number=str(meta.get("section_number", "")),
            section_name=str(meta.get("section_name", "")),
            polling_station_name=str(meta.get("polling_station_name", "")),
            polling_station_address=str(meta.get("polling_station_address", "")),
            normalized_name=norm_name,
            normalized_relative_name=norm_rel_name,
            normalized_house_number=norm_house,
            photo_box=photo_box,
            ocr_confidence=confidence,
            raw_text=text,
            extra_fields={
                "detected_lines_count": len(lines),
            },
        )

    def extract_header_metadata(self, page_text: str) -> dict[str, str]:
        """Extract roll-level and polling station metadata from roll header or title page."""
        meta = {
            "assembly_constituency": "",
            "part_number": "",
            "section_number": "",
            "section_name": "",
            "polling_station_name": "",
            "polling_station_address": "",
        }

        # Part Number (ഭാഗം നമ്പർ / Part No)
        part_m = re.search(r"(?:ഭാഗം\s*നമ്പർ|part\s*no\.?)\s*[:;\-\.]?\s*(\d+)", page_text, re.IGNORECASE)
        if part_m:
            meta["part_number"] = part_m.group(1)

        # Section No (വിഭാഗം നമ്പർ / Section No)
        sec_m = re.search(r"(?:വിഭാഗം\s*നമ്പർ|section\s*no\.?)\s*[:;\-\.]?\s*(\d+)", page_text, re.IGNORECASE)
        if sec_m:
            meta["section_number"] = sec_m.group(1)

        # Section Name
        sec_name_m = re.search(
            r"(?:വിഭാഗത്തിന്റെ\s*പേര്|section\s*name)\s*[:;\-\.]?\s*([^\n\r]+)",
            page_text,
            re.IGNORECASE,
        )
        if sec_name_m:
            meta["section_name"] = sec_name_m.group(1).strip()

        # Polling station name
        ps_m = re.search(
            r"(?:പോളിംഗ്\s*സ്റ്റേഷൻ|polling\s*station)\s*[:;\-\.]?\s*([^\n\r]+)",
            page_text,
            re.IGNORECASE,
        )
        if ps_m:
            meta["polling_station_name"] = ps_m.group(1).strip()

        return meta

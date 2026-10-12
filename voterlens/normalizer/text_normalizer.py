"""Text normalization layer for search indexing while preserving original values."""

import re
import unicodedata
from typing import Optional


# Mapping of legacy Malayalam ligatures (consonant + virama + ZWJ) to atomic Unicode Chillu letters
CHILLU_MAPPINGS = [
    ("\u0d23\u0d4d\u200d", "\u0d7a"),  # ൺ (CHILLU NN)
    ("\u0d28\u0d4d\u200d", "\u0d7b"),  # ൻ (CHILLU N)
    ("\u0d30\u0d4d\u200d", "\u0d7c"),  # ർ (CHILLU RR)
    ("\u0d32\u0d4d\u200d", "\u0d7d"),  # ൽ (CHILLU L)
    ("\u0d33\u0d4d\u200d", "\u0d7e"),  # ൾ (CHILLU LL)
    ("\u0d15\u0d4d\u200d", "\u0d7f"),  # ൿ (CHILLU K)
]

# Zero-width spaces and control marks that should be cleaned for search indexing
ZERO_WIDTH_CHARS = re.compile(r"[\u200b\u200c\u200d\ufeff]")

# Excess whitespaces and punctuation
WHITESPACE_REGEX = re.compile(r"\s+")
PUNCTUATION_CLEANUP = re.compile(r"[^\w\s/.-]", re.UNICODE)


def normalize_malayalam_unicode(text: str) -> str:
    """Normalize Malayalam unicode characters without corrupting ligatures."""
    if not text:
        return ""
    
    # Standard NFC Unicode form
    result = unicodedata.normalize("NFC", text)
    
    # Replace old Virama+ZWJ sequences with atomic chillu characters
    for old_seq, atomic_chillu in CHILLU_MAPPINGS:
        result = result.replace(old_seq, atomic_chillu)
        
    return result


def normalize_name(text: Optional[str]) -> str:
    """Normalize voter/relative name for search indexing.
    
    Preserves Malayalam scripts, standardizes Unicode, collapses whitespace,
    and strips noise without modifying original official names.
    """
    if not text:
        return ""

    # Unicode NFC normalization
    normalized = normalize_malayalam_unicode(text)
    
    # Remove zero-width spaces/joiners for searching
    normalized = ZERO_WIDTH_CHARS.sub("", normalized)
    
    # Collapse duplicate whitespace and trim
    normalized = WHITESPACE_REGEX.sub(" ", normalized).strip()
    
    # Uppercase English characters for uniform case-insensitive search
    normalized = normalized.upper()
    
    return normalized


def normalize_epic(text: Optional[str]) -> str:
    """Normalize Electoral Photo Identity Card (EPIC) number.
    
    Removes extraneous spaces, standardizes slashes and uppercase characters.
    Example: 'kl / 14 / 098 / 123456' -> 'KL/14/098/123456'
             ' klm 1234567 ' -> 'KLM1234567'
    """
    if not text:
        return ""

    # Remove all internal whitespace
    cleaned = re.sub(r"\s+", "", text.strip()).upper()
    
    # Standardize repeated slashes or backslashes
    cleaned = cleaned.replace("\\", "/")
    cleaned = re.sub(r"/+", "/", cleaned)
    
    return cleaned


def normalize_house_number(text: Optional[str]) -> str:
    """Normalize house numbers / building IDs.
    
    Removes surrounding noise and collapses spaces around slashes.
    Example: '12 / A - 3' -> '12/A-3'
    """
    if not text:
        return ""

    cleaned = text.strip().upper()
    # Remove spaces around slashes and hyphens
    cleaned = re.sub(r"\s*/\s*", "/", cleaned)
    cleaned = re.sub(r"\s*-\s*", "-", cleaned)
    cleaned = WHITESPACE_REGEX.sub(" ", cleaned)
    return cleaned


def normalize_relative_type(text: Optional[str]) -> str:
    """Classify relative relationship indicator across Malayalam and English.
    
    Returns standard codes: 'FATHER', 'HUSBAND', 'MOTHER', 'OTHER'.
    """
    if not text:
        return "OTHER"

    raw = text.strip().lower()
    
    # Father patterns
    if any(k in raw for k in ["അച്ഛ", "പിതാ", "father", "fthr"]):
        return "FATHER"
    # Husband patterns
    if any(k in raw for k in ["ഭർത്താ", "husband", "hus"]):
        return "HUSBAND"
    # Mother patterns
    if any(k in raw for k in ["അമ്മ", "മാതാ", "mother", "mothr"]):
        return "MOTHER"
    # Other / Guardian
    return "OTHER"


def normalize_gender(text: Optional[str]) -> str:
    """Standardize gender to 'M', 'F', or 'THIRD_GENDER'."""
    if not text:
        return "UNKNOWN"

    raw = text.strip().lower()
    # Check third gender / other first
    if any(k in raw for k in ["ഭിന്നലിംഗ", "മറ്റുള്ളവർ", "third", "other", "transgender"]):
        return "THIRD_GENDER"
    # Check female before male (because 'female' contains 'male')
    if any(k in raw for k in ["സ്ത്രീ", "സ്തീ", "സ്ത", "female", " f "]) or raw in ["f", "female", "സ്ത", "സ്തീ", "സ്ത്രീ"]:
        return "F"
    # Check male
    if any(k in raw for k in ["പുരുഷൻ", "പുരുഷ", "ആണ്", "male", " m "]) or raw in ["m", "male", "ആണ്"]:
        return "M"
        
    return "UNKNOWN"

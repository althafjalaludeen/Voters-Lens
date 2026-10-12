"""Tests for Malayalam Unicode, name, EPIC, and relationship normalization."""

from voterlens.normalizer.text_normalizer import (
    normalize_epic,
    normalize_gender,
    normalize_house_number,
    normalize_malayalam_unicode,
    normalize_name,
    normalize_relative_type,
)


def test_malayalam_unicode_and_chillu_normalization():
    """Verify legacy virama+ZWJ sequences are mapped to atomic Unicode chillu letters."""
    # Legacy virama + ZWJ for ൻ (U+0D28 + U+0D4D + U+200D)
    legacy_n = "\u0d28\u0d4d\u200d"
    normalized_n = normalize_malayalam_unicode(legacy_n)
    # Atomic chillu ൻ is U+0D7B
    assert normalized_n == "\u0d7b"

    # Legacy virama + ZWJ for ൽ (U+0D32 + U+0D4D + U+200D)
    legacy_l = "\u0d32\u0d4d\u200d"
    normalized_l = normalize_malayalam_unicode(legacy_l)
    assert normalized_l == "\u0d7d"


def test_name_normalization():
    """Verify name normalization cleans whitespace, English case, and zero-width artifacts."""
    raw_eng = "   suresh   kumar   "
    assert normalize_name(raw_eng) == "SURESH KUMAR"

    # Malayalam name with stray zero-width joiner
    raw_mal = "സുരേഷ്\u200c കുമാർ"
    assert normalize_name(raw_mal) == "സുരേഷ് കുമാർ"


def test_epic_normalization():
    """Verify EPIC formatting normalization."""
    assert normalize_epic(" klm / 1092831 ") == "KLM/1092831"
    assert normalize_epic("klm 1092831") == "KLM1092831"
    assert normalize_epic("kl\\14\\098\\001234") == "KL/14/098/001234"


def test_house_number_normalization():
    """Verify house number whitespace cleanup."""
    assert normalize_house_number("  12  /  45-A  ") == "12/45-A"
    assert normalize_house_number("14 / 102") == "14/102"


def test_relative_type_classification():
    """Verify Malayalam and English relative classifications."""
    assert normalize_relative_type("അച്ഛന്റെ പേര്") == "FATHER"
    assert normalize_relative_type("പിതാവ്") == "FATHER"
    assert normalize_relative_type("Father's Name") == "FATHER"

    assert normalize_relative_type("ഭർത്താവിന്റെ പേര്") == "HUSBAND"
    assert normalize_relative_type("Husband's Name") == "HUSBAND"

    assert normalize_relative_type("അമ്മയുടെ പേര്") == "MOTHER"
    assert normalize_relative_type("Mother's Name") == "MOTHER"

    assert normalize_relative_type("മറ്റുള്ളവർ") == "OTHER"
    assert normalize_relative_type("Guardian") == "OTHER"


def test_gender_normalization():
    """Verify gender normalization."""
    assert normalize_gender("പുരുഷൻ") == "M"
    assert normalize_gender("Male") == "M"
    assert normalize_gender("m") == "M"

    assert normalize_gender("സ്ത്രീ") == "F"
    assert normalize_gender("Female") == "F"
    assert normalize_gender("f") == "F"

    assert normalize_gender("ഭിന്നലിംഗം") == "THIRD_GENDER"
    assert normalize_gender("Transgender") == "THIRD_GENDER"

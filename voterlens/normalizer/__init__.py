"""Text normalization package."""

from voterlens.normalizer.text_normalizer import (
    normalize_epic,
    normalize_gender,
    normalize_house_number,
    normalize_malayalam_unicode,
    normalize_name,
    normalize_relative_type,
)

__all__ = [
    "normalize_epic",
    "normalize_gender",
    "normalize_house_number",
    "normalize_malayalam_unicode",
    "normalize_name",
    "normalize_relative_type",
]

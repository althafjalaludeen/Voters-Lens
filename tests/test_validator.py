"""Tests for voter validation rules, duplicate detection, and validation reports."""

from voterlens.validator.voter_validator import IssueSeverity, VoterValidator


def test_validation_clean_records():
    """Verify clean dataset returns full validity."""
    validator = VoterValidator()
    records = [
        {
            "serial_number": 1,
            "epic_number": "KLM1092831",
            "name": "സുരേഷ് കുമാർ",
            "age": 42,
            "gender": "M",
            "house_number": "12/45A",
            "photo_path": "photos/roll_1/v_00001.jpg",
        },
        {
            "serial_number": 2,
            "epic_number": "KLM1092832",
            "name": "ഫാത്തിമ ബീവി",
            "age": 38,
            "gender": "F",
            "house_number": "14/102",
            "photo_path": "photos/roll_1/v_00002.jpg",
        },
    ]
    report = validator.validate_dataset(records)
    assert report.total_detected == 2
    assert report.valid_count == 2
    assert report.warning_count == 0
    assert report.invalid_count == 0


def test_validation_detects_duplicate_epic():
    """Verify duplicate EPIC detection flags warning."""
    validator = VoterValidator()
    records = [
        {
            "serial_number": 1,
            "epic_number": "KLM1092831",
            "name": "Person One",
            "age": 30,
            "gender": "M",
            "house_number": "1",
            "photo_path": "photo1.jpg",
        },
        {
            "serial_number": 2,
            "epic_number": "KLM1092831",  # Duplicate EPIC
            "name": "Person Two",
            "age": 35,
            "gender": "F",
            "house_number": "2",
            "photo_path": "photo2.jpg",
        },
    ]
    report = validator.validate_dataset(records)
    assert "DUPLICATE_EPIC" in report.issue_counts_by_code
    assert report.issue_counts_by_code["DUPLICATE_EPIC"] == 1


def test_validation_impossible_age_and_missing_mandatory():
    """Verify impossible age and missing fields are flagged."""
    validator = VoterValidator(min_age=18, max_age=125)
    records = [
        {
            "serial_number": 1,
            "epic_number": "KLM1092831",
            "name": "Too Young",
            "age": 14,  # Underage (< 18)
            "gender": "M",
            "house_number": "1",
            "photo_path": "photo.jpg",
        },
        {
            "serial_number": 2,
            "epic_number": "KLM1092832",
            "name": "",  # Missing name
            "age": 40,
            "gender": "F",
            "house_number": "2",
            "photo_path": "photo.jpg",
        },
    ]
    report = validator.validate_dataset(records)
    assert "IMPOSSIBLE_AGE" in report.issue_counts_by_code
    assert "MISSING_MANDATORY" in report.issue_counts_by_code
    # Person 2 with missing name has error severity
    assert report.invalid_count >= 1


def test_validation_report_summary_formatting():
    """Verify report text matches required layout."""
    validator = VoterValidator()
    records = [
        {
            "serial_number": 1,
            "epic_number": "INVALID_EPIC_FORMAT_12345",
            "name": "Test Name",
            "age": 25,
            "gender": "M",
            "house_number": "-",  # malformed house no
            "photo_path": None,   # missing photo
        }
    ]
    report = validator.validate_dataset(records)
    summary_text = report.to_summary_text()
    assert "IMPORT VALIDATION REPORT" in summary_text
    assert "Total detected: 1" in summary_text
    assert "missing photographs" in summary_text
    assert "malformed house numbers" in summary_text

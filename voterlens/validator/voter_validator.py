"""Validation layer for voter records and import dataset auditing."""

from collections import Counter
from dataclasses import asdict, dataclass, field
from enum import Enum
import re
from typing import Any, Optional


class IssueSeverity(str, Enum):
    WARNING = "WARNING"
    ERROR = "ERROR"


@dataclass
class ValidationIssue:
    field: str
    code: str
    message: str
    severity: IssueSeverity
    serial_number: Optional[int] = None
    epic_number: Optional[str] = None


@dataclass
class ValidationReport:
    total_detected: int = 0
    valid_count: int = 0
    warning_count: int = 0
    invalid_count: int = 0
    issues: list[ValidationIssue] = field(default_factory=list)
    issue_counts_by_code: dict[str, int] = field(default_factory=dict)

    def add_issue(self, issue: ValidationIssue) -> None:
        self.issues.append(issue)
        self.issue_counts_by_code[issue.code] = self.issue_counts_by_code.get(issue.code, 0) + 1
        if issue.severity == IssueSeverity.ERROR:
            self.invalid_count += 1
        else:
            self.warning_count += 1

    def to_summary_text(self) -> str:
        lines = [
            "=" * 50,
            "IMPORT VALIDATION REPORT",
            "=" * 50,
            f"Total detected: {self.total_detected:,}",
            f"Valid:          {self.valid_count:,}",
            f"Warnings:       {self.warning_count:,}",
            f"Invalid:        {self.invalid_count:,}",
            "-" * 50,
        ]

        if self.issue_counts_by_code:
            lines.append("Breakdown:")
            code_labels = {
                "MISSING_PHOTO": "missing photographs",
                "UNCERTAIN_NAME": "uncertain names",
                "MALFORMED_HOUSE_NO": "malformed house numbers",
                "DUPLICATE_RECORD": "duplicate-looking records",
                "INVALID_EPIC": "invalid EPIC numbers",
                "DUPLICATE_EPIC": "duplicate EPIC numbers",
                "IMPOSSIBLE_AGE": "impossible age values",
                "LOW_CONFIDENCE": "low OCR confidence",
                "MISSING_MANDATORY": "missing mandatory fields",
            }
            for code, count in sorted(self.issue_counts_by_code.items(), key=lambda x: -x[1]):
                label = code_labels.get(code, code.lower().replace("_", " "))
                lines.append(f"  {count:>4} {label}")
        else:
            lines.append("No validation issues detected.")

        lines.append("=" * 50)
        return "\n".join(lines)


# Standard Indian EPIC regex patterns
# Pattern 1: 3 letters + 7 digits (e.g. ABC1234567)
# Pattern 2: State prefix code format (e.g. KL/14/098/123456 or KLM/123/4567)
EPIC_STANDARD_PATTERN = re.compile(r"^[A-Z]{3}\d{7}$")
EPIC_STATE_CODE_PATTERN = re.compile(r"^[A-Z]{2,3}/\d{1,3}/\d{1,3}/\d{1,7}$")


class VoterValidator:
    """Validates raw and parsed voter records prior to database commitment."""

    def __init__(
        self,
        min_age: int = 18,
        max_age: int = 125,
        min_ocr_confidence: float = 0.50,
    ):
        self.min_age = min_age
        self.max_age = max_age
        self.min_ocr_confidence = min_ocr_confidence

    def validate_dataset(self, records: list[dict[str, Any]]) -> ValidationReport:
        """Run batch validation across all extracted voter records."""
        report = ValidationReport(total_detected=len(records))
        seen_epics: dict[str, int] = {}
        seen_fingerprints: dict[str, int] = {}

        for rec in records:
            rec_issues: list[ValidationIssue] = []
            serial = rec.get("serial_number")
            epic = rec.get("epic_number", "")

            # 1. Missing mandatory fields
            mandatory = ["name", "serial_number", "age", "gender"]
            for mf in mandatory:
                val = rec.get(mf)
                if val is None or (isinstance(val, str) and not val.strip()):
                    rec_issues.append(
                        ValidationIssue(
                            field=mf,
                            code="MISSING_MANDATORY",
                            message=f"Mandatory field '{mf}' is empty or missing",
                            severity=IssueSeverity.ERROR,
                            serial_number=serial,
                            epic_number=epic,
                        )
                    )

            # 2. Age validation
            age = rec.get("age")
            if age is not None:
                try:
                    age_int = int(age)
                    if age_int < self.min_age or age_int > self.max_age:
                        rec_issues.append(
                            ValidationIssue(
                                field="age",
                                code="IMPOSSIBLE_AGE",
                                message=f"Age {age_int} is outside valid range ({self.min_age}-{self.max_age})",
                                severity=IssueSeverity.WARNING,
                                serial_number=serial,
                                epic_number=epic,
                            )
                        )
                except (ValueError, TypeError):
                    rec_issues.append(
                        ValidationIssue(
                            field="age",
                            code="IMPOSSIBLE_AGE",
                            message=f"Age '{age}' is not a valid integer",
                            severity=IssueSeverity.ERROR,
                            serial_number=serial,
                            epic_number=epic,
                        )
                    )

            # 3. EPIC validation
            if epic:
                clean_epic = epic.strip().upper()
                if not (EPIC_STANDARD_PATTERN.match(clean_epic) or EPIC_STATE_CODE_PATTERN.match(clean_epic)):
                    rec_issues.append(
                        ValidationIssue(
                            field="epic_number",
                            code="INVALID_EPIC",
                            message=f"EPIC '{clean_epic}' does not match standard Election Commission formats",
                            severity=IssueSeverity.WARNING,
                            serial_number=serial,
                            epic_number=epic,
                        )
                    )
                # Duplicate EPIC check within batch
                if clean_epic in seen_epics:
                    rec_issues.append(
                        ValidationIssue(
                            field="epic_number",
                            code="DUPLICATE_EPIC",
                            message=f"Duplicate EPIC '{clean_epic}' already seen at serial {seen_epics[clean_epic]}",
                            severity=IssueSeverity.WARNING,
                            serial_number=serial,
                            epic_number=epic,
                        )
                    )
                else:
                    seen_epics[clean_epic] = serial
            else:
                rec_issues.append(
                    ValidationIssue(
                        field="epic_number",
                        code="MISSING_MANDATORY",
                        message="EPIC number is missing",
                        severity=IssueSeverity.ERROR,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )

            # 4. House number validation
            house_no = str(rec.get("house_number", "")).strip()
            if not house_no or house_no in ["-", "--", ".", "??", "0"]:
                rec_issues.append(
                    ValidationIssue(
                        field="house_number",
                        code="MALFORMED_HOUSE_NO",
                        message=f"House number '{house_no}' appears malformed or missing",
                        severity=IssueSeverity.WARNING,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )

            # 5. Name confidence and length
            name = str(rec.get("name", "")).strip()
            if len(name) < 2 or re.search(r"[\?\#\$\%]", name):
                rec_issues.append(
                    ValidationIssue(
                        field="name",
                        code="UNCERTAIN_NAME",
                        message=f"Name '{name}' has uncertain OCR artifacts or is too short",
                        severity=IssueSeverity.WARNING,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )

            # 6. OCR confidence
            confidence = rec.get("ocr_confidence")
            if confidence is not None and confidence < self.min_ocr_confidence:
                rec_issues.append(
                    ValidationIssue(
                        field="ocr_confidence",
                        code="LOW_CONFIDENCE",
                        message=f"OCR confidence {confidence:.2f} is below threshold {self.min_ocr_confidence}",
                        severity=IssueSeverity.WARNING,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )

            # 7. Photograph check
            if not rec.get("photo_path"):
                rec_issues.append(
                    ValidationIssue(
                        field="photo_path",
                        code="MISSING_PHOTO",
                        message="No voter photograph was extracted or found",
                        severity=IssueSeverity.WARNING,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )

            # 8. Duplicate person fingerprint check (Name + Relative Name + House No)
            fingerprint = f"{name}|{rec.get('relative_name', '')}|{house_no}".lower()
            if fingerprint in seen_fingerprints and len(name) > 2:
                rec_issues.append(
                    ValidationIssue(
                        field="record",
                        code="DUPLICATE_RECORD",
                        message=f"Record closely matches previous voter at serial {seen_fingerprints[fingerprint]}",
                        severity=IssueSeverity.WARNING,
                        serial_number=serial,
                        epic_number=epic,
                    )
                )
            else:
                seen_fingerprints[fingerprint] = serial

            # Register issues into report
            has_error = False
            for iss in rec_issues:
                report.add_issue(iss)
                if iss.severity == IssueSeverity.ERROR:
                    has_error = True

            if not has_error:
                report.valid_count += 1

        return report

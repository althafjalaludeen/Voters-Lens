"""Data Transfer Objects for Voter presentation and Search results."""

from datetime import datetime
from typing import Optional
from pydantic import BaseModel, Field


FIELD_STATUS_LABELS = {
    "NO_ISSUE": "🟢 No issue reported",
    "AWAY": "🟡 Away",
    "ABROAD": "🔵 Currently abroad",
    "REPORTED_DECEASED": "🔴 Reported deceased",
    "UNABLE_TO_VERIFY": "🟠 Unable to verify",
}


class VoterSearchResult(BaseModel):
    """Compact search result representation for list view and future Flutter UI."""

    voter_id: str
    serial_number: int
    epic_number: str
    name: str
    relative_name: str
    relative_type: str = "OTHER"
    house_number: str
    age: int
    gender: str
    part_number: str
    polling_station_name: str = ""
    photo_path: Optional[str] = None
    photo_available: bool = False
    field_status: str = "NO_ISSUE"
    field_status_label: str = "🟢 No issue reported"
    review_status: str = "NOT_REVIEWED"
    phone_number: Optional[str] = None


class VoterOfficialDTO(BaseModel):
    """Read-only official electoral-roll voter data."""

    id: str
    roll_version_id: str
    serial_number: int
    epic_number: str
    name: str
    normalized_name: str
    relative_name: str
    normalized_relative_name: str
    relative_type: str
    house_number: str
    normalized_house_number: str
    age: int
    gender: str
    part_number: str
    section_number: str
    section_name: str
    polling_station_name: str
    polling_station_address: str
    photo_path: Optional[str] = None
    photo_available: bool = False
    photo_status: str = "PHOTO_UNAVAILABLE"
    ocr_confidence: Optional[float] = None


class FieldStatusHistoryDTO(BaseModel):
    """Audit entry for field status transition."""

    id: str
    voter_id: str
    old_status: str
    new_status: str
    notes: Optional[str] = None
    changed_by: Optional[str] = None
    changed_at: datetime


class VoterFieldDTO(BaseModel):
    """Editable local field and verification data."""

    status: str = "NO_ISSUE"
    status_label: str = "🟢 No issue reported"
    phone_number: Optional[str] = None
    notes: Optional[str] = None
    review_status: str = "NOT_REVIEWED"
    review_reasons: list[str] = Field(default_factory=list)
    reviewed_by: Optional[str] = None
    reviewed_at: Optional[datetime] = None
    reported_by: Optional[str] = None
    reported_at: Optional[datetime] = None
    history: list[FieldStatusHistoryDTO] = Field(default_factory=list)


class VoterDetail(BaseModel):
    """Complete voter representation cleanly separating official vs field data."""

    voter_id: str
    official: VoterOfficialDTO
    field: VoterFieldDTO


class VoterListResponse(BaseModel):
    """Paginated voter search or list result for lazy-loading UI."""

    items: list[VoterSearchResult]
    total_count: int
    page: int
    page_size: int
    total_pages: int
    has_next: bool
    has_prev: bool


class HouseholdGroup(BaseModel):
    """Household view grouping voters by normalized house number."""

    house_number: str
    normalized_house_number: str
    voter_count: int
    voters: list[VoterSearchResult]


class AreaStatistics(BaseModel):
    """Electoral area database-management metrics."""

    total_voters: int
    part_number: Optional[str] = None
    gender_counts: dict[str, int]
    field_status_counts: dict[str, int]
    review_status_counts: dict[str, int]

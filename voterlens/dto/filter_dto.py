"""Filter and Search parameter models for VoterLens search engine."""

from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field


class SortField(str, Enum):
    SERIAL_NUMBER = "serial_number"
    NAME = "name"
    HOUSE_NUMBER = "house_number"
    AGE = "age"
    PART_NUMBER = "part_number"
    FIELD_STATUS = "field_status"
    REVIEW_STATUS = "review_status"


class SortDirection(str, Enum):
    ASC = "asc"
    DESC = "desc"


class SortOptions(BaseModel):
    field: SortField = SortField.SERIAL_NUMBER
    direction: SortDirection = SortDirection.ASC


class FieldStatusFilter(str, Enum):
    ALL = "ALL"
    NO_ISSUE = "NO_ISSUE"
    AWAY = "AWAY"
    ABROAD = "ABROAD"
    REPORTED_DECEASED = "REPORTED_DECEASED"
    UNABLE_TO_VERIFY = "UNABLE_TO_VERIFY"


class ReviewStatusFilter(str, Enum):
    ALL = "ALL"
    NOT_REVIEWED = "NOT_REVIEWED"
    NEEDS_REVIEW = "NEEDS_REVIEW"
    REVIEWED = "REVIEWED"


class GenderFilter(str, Enum):
    ALL = "ALL"
    MALE = "M"
    FEMALE = "F"
    OTHER = "O"


class SearchCriteria(BaseModel):
    """Unified search and filtering parameters for VoterLens queries."""

    query: Optional[str] = None  # Free text search across name, epic, relative, house
    name: Optional[str] = None  # Exact, prefix, or contains match on name
    epic: Optional[str] = None  # EPIC number match
    relative_name: Optional[str] = None  # Relative name match
    house_number: Optional[str] = None  # House number match
    gender: GenderFilter = GenderFilter.ALL
    part_number: Optional[str] = None
    serial_number: Optional[int] = None
    section_number: Optional[str] = None
    polling_station_name: Optional[str] = None
    phone_number: Optional[str] = None
    field_status: FieldStatusFilter = FieldStatusFilter.ALL
    review_status: ReviewStatusFilter = ReviewStatusFilter.ALL
    use_fts: bool = False  # Whether to use SQLite FTS5 index for text search
    page: int = Field(default=1, ge=1)
    page_size: int = Field(default=50, ge=1, le=500)
    sort: SortOptions = Field(default_factory=SortOptions)

"""Data Transfer Objects for Roll Version and Comparison presentation."""

from datetime import datetime
from typing import Any, Optional
from pydantic import BaseModel, Field


class RollVersionDTO(BaseModel):
    """Electoral roll version presentation model."""

    id: str
    state: str
    district: str
    assembly_constituency: str
    roll_name: str
    roll_type: str = "GENERAL"
    publication_date: Optional[str] = None
    source_reference: Optional[str] = None
    imported_at: datetime
    record_count: int = 0
    status: str
    checksum_hash: Optional[str] = None


class ElectoralAreaConfigDTO(BaseModel):
    """Local electoral constituency configuration presentation model."""

    id: str
    state: str
    district: str
    assembly_constituency: str
    selected_part_number: Optional[str] = None
    active_roll_id: Optional[str] = None


class VoterDifference(BaseModel):
    """Individual difference detected between old and new roll versions."""

    epic_number: str
    diff_type: str  # "ADDED", "REMOVED", "MODIFIED"
    changes: list[str] = Field(default_factory=list)
    old_data: Optional[dict[str, Any]] = None
    new_data: Optional[dict[str, Any]] = None


class RollComparisonReport(BaseModel):
    """Future-ready differential audit between two electoral roll versions."""

    old_roll_id: str
    new_roll_id: str
    added_count: int
    removed_count: int
    modified_count: int
    unchanged_count: int
    part_changes_count: int
    polling_station_changes_count: int
    differences: list[VoterDifference] = Field(default_factory=list)
    summary: str

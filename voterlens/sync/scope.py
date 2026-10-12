"""Export scope abstraction for synchronization packaging."""

from dataclasses import dataclass, field
from datetime import datetime
import enum
from typing import List, Optional


class ExportScope(str, enum.Enum):
    """Scope defining the boundary of field observations to export."""
    ALL_ELIGIBLE_FIELD_OBSERVATIONS = "ALL_ELIGIBLE"
    PART = "PART"
    HOUSE = "HOUSE"
    DATE_RANGE = "DATE_RANGE"
    SELECTED_RECORDS = "SELECTED_RECORDS"
    DEVICE_DELTA = "DEVICE_DELTA"


@dataclass
class ExportScopeFilter:
    """Filter parameters applied when querying observations for an export scope."""
    part_number: Optional[str] = None
    house_number: Optional[str] = None
    start_date: Optional[datetime] = None
    end_date: Optional[datetime] = None
    selected_epics: Optional[List[str]] = field(default_factory=list)
    since_timestamp: Optional[datetime] = None
    origin_device_id: Optional[str] = None

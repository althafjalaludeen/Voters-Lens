"""Database models, connection management, and repository package."""

from voterlens.database.database import DatabaseManager, get_db_manager
from voterlens.database.models import (
    AuditLog,
    Base,
    ElectoralAreaConfig,
    FieldStatus,
    FieldStatusHistory,
    FieldStatusType,
    ImportReportRecord,
    ReviewStatusType,
    RollVersion,
    RollVersionStatus,
    User,
    UserRole,
    Voter,
)
from voterlens.database.repository import (
    AuditRepository,
    ElectoralAreaRepository,
    ElectoralRollRepository,
    FieldStatusRepository,
    ImmutableElectoralRollError,
    UserRepository,
    VoterRepository,
)

__all__ = [
    "Base",
    "DatabaseManager",
    "get_db_manager",
    "RollVersion",
    "RollVersionStatus",
    "Voter",
    "FieldStatus",
    "FieldStatusType",
    "FieldStatusHistory",
    "ReviewStatusType",
    "ImportReportRecord",
    "ElectoralAreaConfig",
    "User",
    "UserRole",
    "AuditLog",
    "ElectoralRollRepository",
    "ElectoralAreaRepository",
    "VoterRepository",
    "FieldStatusRepository",
    "UserRepository",
    "AuditRepository",
    "ImmutableElectoralRollError",
]

"""Database models for VoterLens using SQLAlchemy 2.0."""

from datetime import datetime, timezone
import enum
import uuid
from typing import Optional

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


def generate_uuid() -> str:
    """Generate a UUID4 string representation."""
    return str(uuid.uuid4())


def utc_now() -> datetime:
    """Current UTC datetime."""
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    """Base class for all SQLAlchemy declarative models."""
    pass


class RollVersionStatus(str, enum.Enum):
    """Status lifecycle of an electoral roll version."""
    IMPORTING = "IMPORTING"
    ACTIVE = "ACTIVE"
    ARCHIVED = "ARCHIVED"
    FAILED = "FAILED"


class FieldStatusType(str, enum.Enum):
    """Verification field observations recorded by local workers."""
    NO_ISSUE = "NO_ISSUE"
    AWAY = "AWAY"
    ABROAD = "ABROAD"
    REPORTED_DECEASED = "REPORTED_DECEASED"
    UNABLE_TO_VERIFY = "UNABLE_TO_VERIFY"


class ReviewStatusType(str, enum.Enum):
    """Manual review lifecycle for records needing human verification."""
    NOT_REVIEWED = "NOT_REVIEWED"
    NEEDS_REVIEW = "NEEDS_REVIEW"
    REVIEWED = "REVIEWED"


class UserRole(str, enum.Enum):
    """Role-based access tiers for local operators."""
    ADMIN = "ADMIN"
    MANAGER = "MANAGER"
    FIELD_USER = "FIELD_USER"
    VIEWER = "VIEWER"


class RollVersion(Base):
    """Electoral Roll Version representing an official published snapshot."""

    __tablename__ = "roll_versions"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    state: Mapped[str] = mapped_column(String(100), nullable=False)
    district: Mapped[str] = mapped_column(String(100), nullable=False)
    assembly_constituency: Mapped[str] = mapped_column(String(150), nullable=False)
    roll_name: Mapped[str] = mapped_column(String(200), nullable=False)
    roll_type: Mapped[str] = mapped_column(String(50), default="GENERAL")
    publication_date: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    source_reference: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    imported_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    record_count: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[RollVersionStatus] = mapped_column(
        Enum(RollVersionStatus), default=RollVersionStatus.IMPORTING, nullable=False
    )
    checksum_hash: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)

    # Relationships
    voters: Mapped[list["Voter"]] = relationship(
        "Voter", back_populates="roll_version", cascade="all, delete-orphan"
    )
    import_report: Mapped[Optional["ImportReportRecord"]] = relationship(
        "ImportReportRecord", back_populates="roll_version", uselist=False
    )

    __table_args__ = (
        Index("ix_roll_area", "state", "district", "assembly_constituency"),
        Index("ix_roll_status", "status"),
    )


class Voter(Base):
    """Official Electoral-Roll record. READ-ONLY once imported and roll is ACTIVE."""

    __tablename__ = "voters"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    roll_version_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("roll_versions.id"), nullable=False, index=True
    )
    serial_number: Mapped[int] = mapped_column(Integer, nullable=False)
    epic_number: Mapped[str] = mapped_column(String(50), nullable=False)
    
    # Official text (preserving exact original Malayalam/English)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_name: Mapped[str] = mapped_column(String(255), nullable=False)
    
    relative_name: Mapped[str] = mapped_column(String(255), nullable=False)
    normalized_relative_name: Mapped[str] = mapped_column(String(255), nullable=False)
    relative_type: Mapped[str] = mapped_column(String(50), default="OTHER")
    
    house_number: Mapped[str] = mapped_column(String(100), nullable=False)
    normalized_house_number: Mapped[str] = mapped_column(String(100), nullable=False)
    
    age: Mapped[int] = mapped_column(Integer, nullable=False)
    gender: Mapped[str] = mapped_column(String(20), nullable=False)
    
    part_number: Mapped[str] = mapped_column(String(50), nullable=False)
    section_number: Mapped[str] = mapped_column(String(50), default="")
    section_name: Mapped[str] = mapped_column(String(255), default="")
    polling_station_name: Mapped[str] = mapped_column(String(255), default="")
    polling_station_address: Mapped[str] = mapped_column(Text, default="")
    
    photo_path: Mapped[Optional[str]] = mapped_column(String(500), nullable=True)
    ocr_confidence: Mapped[Optional[float]] = mapped_column(Float, nullable=True)
    
    # JSON field for forward compatibility without schema rewrite
    raw_data: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    # Relationships
    roll_version: Mapped["RollVersion"] = relationship("RollVersion", back_populates="voters")
    field_status: Mapped[Optional["FieldStatus"]] = relationship(
        "FieldStatus", back_populates="voter", uselist=False, cascade="all, delete-orphan"
    )
    field_status_history: Mapped[list["FieldStatusHistory"]] = relationship(
        "FieldStatusHistory", back_populates="voter", cascade="all, delete-orphan"
    )

    __table_args__ = (
        Index("ix_voter_epic", "epic_number"),
        Index("ix_voter_name", "name"),
        Index("ix_voter_norm_name", "normalized_name"),
        Index("ix_voter_rel_name", "relative_name"),
        Index("ix_voter_norm_rel_name", "normalized_relative_name"),
        Index("ix_voter_house", "house_number"),
        Index("ix_voter_norm_house", "normalized_house_number"),
        Index("ix_voter_part", "part_number"),
        Index("ix_voter_serial", "serial_number"),
        Index("ix_voter_gender", "gender"),
        Index("ix_voter_age", "age"),
        Index("ix_voter_roll_epic", "roll_version_id", "epic_number"),
        Index("ix_voter_roll_part_serial", "roll_version_id", "part_number", "serial_number"),
    )


class FieldStatus(Base):
    """Local field-verification status and editable field information.
    
    Completely separate from official electoral-roll data.
    Never overwrites or deletes the official Voter record.
    """

    __tablename__ = "field_status"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    voter_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("voters.id"), nullable=False, unique=True, index=True
    )
    status: Mapped[FieldStatusType] = mapped_column(
        Enum(FieldStatusType), default=FieldStatusType.NO_ISSUE, nullable=False
    )
    phone_number: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    
    # Review workflow fields
    review_status: Mapped[ReviewStatusType] = mapped_column(
        Enum(ReviewStatusType), default=ReviewStatusType.NOT_REVIEWED, nullable=False
    )
    review_reasons: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    reviewed_by: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    reviewed_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)

    reported_by: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    reported_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )

    # Relationships
    voter: Mapped["Voter"] = relationship("Voter", back_populates="field_status")

    __table_args__ = (
        Index("ix_fs_voter_status", "voter_id", "status"),
        Index("ix_fs_review_status", "review_status"),
    )


class FieldStatusHistory(Base):
    """Audit log of every field-status transition. History is append-only."""

    __tablename__ = "field_status_history"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    voter_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("voters.id"), nullable=False, index=True
    )
    old_status: Mapped[str] = mapped_column(String(50), nullable=False)
    new_status: Mapped[str] = mapped_column(String(50), nullable=False)
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    changed_by: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    changed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    # Relationships
    voter: Mapped["Voter"] = relationship("Voter", back_populates="field_status_history")

    __table_args__ = (
        Index("ix_fsh_voter_time", "voter_id", "changed_at"),
    )


class ImportReportRecord(Base):
    """Persistent storage for Import Validation Reports."""

    __tablename__ = "import_reports"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    roll_version_id: Mapped[str] = mapped_column(
        String(36), ForeignKey("roll_versions.id"), nullable=False, unique=True
    )
    total_detected: Mapped[int] = mapped_column(Integer, default=0)
    valid_count: Mapped[int] = mapped_column(Integer, default=0)
    warning_count: Mapped[int] = mapped_column(Integer, default=0)
    invalid_count: Mapped[int] = mapped_column(Integer, default=0)
    warnings_json: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    summary_text: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    # Relationships
    roll_version: Mapped["RollVersion"] = relationship("RollVersion", back_populates="import_report")


class ElectoralAreaConfig(Base):
    """Configuration for local electoral constituency and active roll assignment."""

    __tablename__ = "electoral_area_configs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    state: Mapped[str] = mapped_column(String(100), nullable=False)
    district: Mapped[str] = mapped_column(String(100), nullable=False)
    assembly_constituency: Mapped[str] = mapped_column(String(150), nullable=False)
    selected_part_number: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    active_roll_id: Mapped[Optional[str]] = mapped_column(
        String(36), ForeignKey("roll_versions.id", ondelete="SET NULL"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )

    __table_args__ = (
        Index("ix_area_config_unique", "state", "district", "assembly_constituency", unique=True),
    )


class User(Base):
    """Local application user / operator with role-based permissions."""

    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    username: Mapped[str] = mapped_column(String(100), unique=True, nullable=False, index=True)
    full_name: Mapped[str] = mapped_column(String(200), nullable=False)
    role: Mapped[UserRole] = mapped_column(Enum(UserRole), default=UserRole.VIEWER, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, onupdate=utc_now
    )


class AuditLog(Base):
    """Immutable audit trail for all significant administrative and field actions."""

    __tablename__ = "audit_logs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    action: Mapped[str] = mapped_column(String(100), nullable=False, index=True)
    entity_type: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    entity_id: Mapped[Optional[str]] = mapped_column(String(50), nullable=True, index=True)
    performed_by: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    details: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    timestamp: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utc_now, nullable=False, index=True
    )


# Register synchronization models with Base.metadata
from voterlens.sync.models import (
    DeviceConfig,
    FieldObservation,
    SyncConflict,
    SyncPacketRecord,
    TrustedDevice,
)

"""Data models and schemas for the VoterLens Offline Synchronization Layer."""

from datetime import datetime, timezone
import enum
import uuid
from typing import Optional

from sqlalchemy import (
    Boolean,
    Column,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from voterlens.database.models import (
    Base,
    FieldStatusType,
    generate_uuid,
    utc_now,
)


class SyncPacketDirection(str, enum.Enum):
    """Direction of synchronization packet."""
    EXPORT = "EXPORT"
    IMPORT = "IMPORT"


class SyncPacketStatus(str, enum.Enum):
    """Status lifecycle of a processed synchronization packet."""
    RECEIVED = "RECEIVED"
    VALIDATED = "VALIDATED"
    PREVIEWED = "PREVIEWED"
    COMMITTED = "COMMITTED"
    CREATED = "CREATED"
    IMPORTED = "IMPORTED"  # Kept for backward compatibility with Phase 4A
    REJECTED = "REJECTED"
    FAILED = "FAILED"


class PacketType(str, enum.Enum):
    """Semantic type of sync packet payload."""
    FIELD_OBSERVATIONS_SYNC = "FIELD_OBSERVATIONS_SYNC"
    GAZETTE_SNAPSHOT = "GAZETTE_SNAPSHOT"
    FIELD_DELTA_BACKUP = "FIELD_DELTA_BACKUP"


class ConflictType(str, enum.Enum):
    """Classification categories for observation synchronization conflicts."""
    DUPLICATE = "DUPLICATE"
    IDENTICAL = "IDENTICAL"
    STALE = "STALE"
    CONCURRENT = "CONCURRENT"
    ROLL_MISMATCH = "ROLL_MISMATCH"
    VOTER_NOT_FOUND = "VOTER_NOT_FOUND"
    INVALID_OBSERVATION = "INVALID_OBSERVATION"
    PERMISSION_CONFLICT = "PERMISSION_CONFLICT"
    SCHEMA_VERSION_MISMATCH = "SCHEMA_VERSION_MISMATCH"


class ConflictResolutionStatus(str, enum.Enum):
    """Resolution status for detected observation conflicts."""
    PENDING_REVIEW = "PENDING_REVIEW"
    RESOLVED_ACCEPTED_A = "RESOLVED_ACCEPTED_A"
    RESOLVED_ACCEPTED_B = "RESOLVED_ACCEPTED_B"
    RESOLVED_MERGED = "RESOLVED_MERGED"
    DISMISSED = "DISMISSED"


class DeviceConfig(Base):
    """Local device persistent identity and configuration."""

    __tablename__ = "device_configs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    device_id: Mapped[str] = mapped_column(String(36), unique=True, nullable=False, index=True)
    device_name: Mapped[str] = mapped_column(String(100), default="VoterLens Field Unit")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)


class FieldObservation(Base):
    """Append-only observation event store representing discrete field actions.
    
    This records 'What happened?' across all devices, maintaining complete
    provenance, historical auditability, and conflict detection evidence.
    The current `field_status` table acts as the materialized latest resolved state.
    """

    __tablename__ = "field_observations"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    observation_id: Mapped[str] = mapped_column(
        String(36), unique=True, nullable=False, index=True
    )
    voter_id: Mapped[Optional[str]] = mapped_column(
        String(36), ForeignKey("voters.id", ondelete="SET NULL"), nullable=True, index=True
    )
    voter_epic: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    voter_part_serial: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    
    roll_version_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    roll_checksum: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    
    field_status: Mapped[FieldStatusType] = mapped_column(
        Enum(FieldStatusType), nullable=False
    )
    phone_number: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    
    created_by: Mapped[str] = mapped_column(String(100), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    origin_device_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    supersedes_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True)
    
    # Revocation / Tombstone without physical deletion
    is_revoked: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    revocation_reason: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    __table_args__ = (
        Index("ix_fo_epic_roll", "voter_epic", "roll_checksum"),
        Index("ix_fo_voter_time", "voter_epic", "created_at"),
    )


class SyncPacketRecord(Base):
    """Audit and idempotency record of exported and imported synchronization packets."""

    __tablename__ = "sync_packets"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    packet_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    direction: Mapped[SyncPacketDirection] = mapped_column(Enum(SyncPacketDirection), nullable=False)
    protocol_version: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    source_device_id: Mapped[str] = mapped_column(String(36), nullable=False)
    source_user_id: Mapped[str] = mapped_column(String(100), nullable=False)
    roll_version_id: Mapped[str] = mapped_column(String(36), nullable=False)
    roll_checksum: Mapped[str] = mapped_column(String(64), nullable=False)
    observation_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    processed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    status: Mapped[SyncPacketStatus] = mapped_column(Enum(SyncPacketStatus), nullable=False)
    status_message: Mapped[Optional[str]] = mapped_column(Text, nullable=True)

    __table_args__ = (
        Index("ix_sp_packet_direction", "packet_id", "direction", unique=True),
    )


class SyncConflict(Base):
    """Discrepancies identified during observation reconciliation requiring review."""

    __tablename__ = "sync_conflicts"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    voter_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True)
    voter_epic: Mapped[str] = mapped_column(String(50), nullable=False, index=True)
    conflict_type: Mapped[ConflictType] = mapped_column(Enum(ConflictType), nullable=False)
    local_observation_id: Mapped[Optional[str]] = mapped_column(String(36), nullable=True)
    incoming_observation_id: Mapped[str] = mapped_column(String(36), nullable=False)
    
    resolution_status: Mapped[ConflictResolutionStatus] = mapped_column(
        Enum(ConflictResolutionStatus), default=ConflictResolutionStatus.PENDING_REVIEW, nullable=False
    )
    resolved_by: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    resolved_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    resolution_choice: Mapped[Optional[str]] = mapped_column(String(50), nullable=True)
    resolution_notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

    __table_args__ = (
        Index("ix_sc_voter_status", "voter_epic", "resolution_status"),
    )


class TrustedDevice(Base):
    """Authorized peer devices permitted to exchange field data."""

    __tablename__ = "trusted_devices"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=generate_uuid)
    device_id: Mapped[str] = mapped_column(String(36), unique=True, nullable=False, index=True)
    device_name: Mapped[str] = mapped_column(String(100), nullable=False)
    operator_name: Mapped[Optional[str]] = mapped_column(String(100), nullable=True)
    is_trusted: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    first_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    last_synced_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)

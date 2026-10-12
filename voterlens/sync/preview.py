"""Import preview domain model and non-mutating preview analysis engine."""

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import RollVersion, RollVersionStatus, Voter
from voterlens.sync.conflict_engine import ConflictEngine
from voterlens.sync.models import (
    ConflictType,
    FieldObservation,
    SyncPacketDirection,
    SyncPacketRecord,
    SyncPacketStatus,
    TrustedDevice,
)
from voterlens.sync.protocol import (
    deserialize_and_decrypt_packet,
    resolve_canonical_voter,
)
from voterlens.sync.transport import VLSyncFileTransport


@dataclass
class PreviewRecord:
    """Classified preview for an individual incoming observation."""
    observation_id: str
    voter_epic: str
    voter_part_serial: Optional[str]
    voter_name: Optional[str]
    incoming_status: str
    local_status: Optional[str]
    classification: str  # NEW, IDENTICAL, DUPLICATE, STALE, CONCURRENT, ROLL_MISMATCH, VOTER_NOT_FOUND, INVALID
    message: str
    is_safe_to_import: bool
    requires_review: bool
    is_rejected: bool
    phone_number: Optional[str]
    notes: Optional[str]
    created_at: str
    origin_device_id: str
    raw_observation: Dict[str, Any] = field(default_factory=dict)


@dataclass
class ImportPreview:
    """Comprehensive Stage 1 preview model generated without mutating live database state."""
    packet_id: str
    source_device_id: str
    source_user_id: str
    roll_version_id: str
    roll_checksum: str
    created_at: str
    total_records: int
    new_records: int
    duplicate_records: int
    identical_records: int
    stale_records: int
    concurrent_conflicts: int
    roll_mismatch_records: int
    voter_not_found_records: int
    invalid_records: int
    permission_conflict_records: int
    is_compatible_roll: bool
    can_commit: bool
    rejection_reason: Optional[str]
    records: List[PreviewRecord] = field(default_factory=list)
    raw_packet_metadata: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        """Convert preview to serialized dictionary for UI and audit representations."""
        return {
            "packet_id": self.packet_id,
            "source_device_id": self.source_device_id,
            "source_user_id": self.source_user_id,
            "roll_version_id": self.roll_version_id,
            "roll_checksum": self.roll_checksum,
            "created_at": self.created_at,
            "total_records": self.total_records,
            "new_records": self.new_records,
            "duplicate_records": self.duplicate_records,
            "identical_records": self.identical_records,
            "stale_records": self.stale_records,
            "concurrent_conflicts": self.concurrent_conflicts,
            "roll_mismatch_records": self.roll_mismatch_records,
            "voter_not_found_records": self.voter_not_found_records,
            "invalid_records": self.invalid_records,
            "permission_conflict_records": self.permission_conflict_records,
            "is_compatible_roll": self.is_compatible_roll,
            "can_commit": self.can_commit,
            "rejection_reason": self.rejection_reason,
            "records": [
                {
                    "observation_id": r.observation_id,
                    "voter_epic": r.voter_epic,
                    "voter_part_serial": r.voter_part_serial,
                    "voter_name": r.voter_name,
                    "incoming_status": r.incoming_status,
                    "local_status": r.local_status,
                    "classification": r.classification,
                    "message": r.message,
                    "is_safe_to_import": r.is_safe_to_import,
                    "requires_review": r.requires_review,
                    "is_rejected": r.is_rejected,
                    "phone_number": r.phone_number,
                    "notes": r.notes,
                    "created_at": r.created_at,
                    "origin_device_id": r.origin_device_id,
                }
                for r in self.records
            ],
        }


class PreviewEngine:
    """Generates preview analysis for incoming sync packets without altering database state."""

    @staticmethod
    def generate_preview(
        session: Session,
        packet_data: Dict[str, Any],
        transfer_passphrase: str,
        require_trusted_device: bool = False,
    ) -> ImportPreview:
        """Inspect, decrypt, authenticate, and classify packet observations.
        
        Strict Guarantee: Does NOT perform any INSERT/UPDATE/DELETE queries.
        """
        # 1. Parse & Decrypt
        metadata, observations = deserialize_and_decrypt_packet(
            packet_data=packet_data,
            transfer_passphrase=transfer_passphrase,
        )

        packet_id = metadata["packet_id"]
        source_device_id = metadata["source_device_id"]
        source_user_id = metadata.get("source_user_id", "unknown")
        roll_version_id = metadata["roll_version_id"]
        roll_checksum = metadata["roll_checksum"]
        created_at = metadata["created_at"]

        # 2. Check Roll Compatibility
        roll_stmt = select(RollVersion).where(
            RollVersion.checksum_hash == roll_checksum,
            RollVersion.status == RollVersionStatus.ACTIVE,
        )
        active_roll = session.execute(roll_stmt).scalars().first()

        is_compatible_roll = active_roll is not None
        rejection_reason = None
        if not is_compatible_roll:
            rejection_reason = f"This synchronization file belongs to a different electoral-roll version (checksum mismatch: {roll_checksum})"

        # 3. Check Trusted Device / Revoked Device
        revoked_stmt = select(TrustedDevice).where(
            TrustedDevice.device_id == source_device_id,
            TrustedDevice.is_trusted == False,
        )
        if session.execute(revoked_stmt).scalars().first():
            is_compatible_roll = False
            can_commit = False
            rejection_reason = f"Source device {source_device_id} is revoked and unauthorized"
        elif require_trusted_device:
            td_stmt = select(TrustedDevice).where(
                TrustedDevice.device_id == source_device_id,
                TrustedDevice.is_trusted == True,
            )
            if not session.execute(td_stmt).scalars().first():
                is_compatible_roll = False
                can_commit = False
                rejection_reason = f"Source device {source_device_id} is not in local trusted devices list"

        # 4. Check Idempotency (Already imported packet)
        dup_stmt = select(SyncPacketRecord).where(
            SyncPacketRecord.packet_id == packet_id,
            SyncPacketRecord.direction == SyncPacketDirection.IMPORT,
            SyncPacketRecord.status.in_([SyncPacketStatus.IMPORTED, SyncPacketStatus.COMMITTED]),
        )
        if session.execute(dup_stmt).scalars().first():
            can_commit = False
            rejection_reason = f"This synchronization file has already been imported (Packet {packet_id})"
        else:
            can_commit = is_compatible_roll

        # 5. Classify each observation without writing to DB
        preview_records: List[PreviewRecord] = []
        new_count = 0
        dup_count = 0
        identical_count = 0
        stale_count = 0
        concurrent_count = 0
        roll_mismatch_count = 0
        voter_not_found_count = 0
        invalid_count = 0
        perm_conflict_count = 0

        for obs in observations:
            obs_id = obs.get("observation_id", "UNKNOWN")
            epic = obs.get("voter_epic", "")
            part_serial = obs.get("voter_part_serial")
            inc_status = obs.get("field_status", "UNKNOWN")
            phone = obs.get("phone_number")
            notes = obs.get("notes")
            created_at_obs = obs.get("created_at", "")
            origin_dev = obs.get("origin_device_id", source_device_id)

            if not is_compatible_roll:
                roll_mismatch_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=None,
                        incoming_status=inc_status,
                        local_status=None,
                        classification="ROLL_MISMATCH",
                        message=f"Roll mismatch: packet checksum {roll_checksum} differs from active roll",
                        is_safe_to_import=False,
                        requires_review=False,
                        is_rejected=True,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
                continue

            matched_voter = resolve_canonical_voter(
                session=session,
                roll_version_id=active_roll.id,
                voter_epic=epic,
                voter_part_serial=part_serial,
            )

            voter_name = matched_voter.name if matched_voter else None
            local_status = (
                matched_voter.field_status.status.value
                if matched_voter and matched_voter.field_status
                else None
            )

            # Analyze conflict
            analysis = ConflictEngine.analyze_observation(
                session=session,
                incoming=obs,
                matched_voter=matched_voter,
            )

            if analysis.conflict_type == ConflictType.VOTER_NOT_FOUND:
                voter_not_found_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=None,
                        incoming_status=inc_status,
                        local_status=None,
                        classification="VOTER_NOT_FOUND",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=True,
                        is_rejected=True,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type == ConflictType.DUPLICATE:
                dup_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="DUPLICATE",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=False,
                        is_rejected=False,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type == ConflictType.IDENTICAL:
                identical_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="IDENTICAL",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=False,
                        is_rejected=False,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type == ConflictType.STALE:
                stale_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="STALE",
                        message=analysis.message,
                        is_safe_to_import=True,  # History is appended safely
                        requires_review=False,
                        is_rejected=False,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type == ConflictType.CONCURRENT:
                concurrent_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="CONCURRENT",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=True,
                        is_rejected=False,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type in (
                ConflictType.INVALID_OBSERVATION,
                ConflictType.SCHEMA_VERSION_MISMATCH,
            ):
                invalid_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="INVALID",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=False,
                        is_rejected=True,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            elif analysis.conflict_type == ConflictType.PERMISSION_CONFLICT:
                perm_conflict_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="PERMISSION_CONFLICT",
                        message=analysis.message,
                        is_safe_to_import=False,
                        requires_review=True,
                        is_rejected=True,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )
            else:
                # Clean actionable new update
                new_count += 1
                preview_records.append(
                    PreviewRecord(
                        observation_id=obs_id,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        voter_name=voter_name,
                        incoming_status=inc_status,
                        local_status=local_status,
                        classification="NEW",
                        message="Ready to materialize into local state",
                        is_safe_to_import=True,
                        requires_review=False,
                        is_rejected=False,
                        phone_number=phone,
                        notes=notes,
                        created_at=created_at_obs,
                        origin_device_id=origin_dev,
                        raw_observation=obs,
                    )
                )

        return ImportPreview(
            packet_id=packet_id,
            source_device_id=source_device_id,
            source_user_id=source_user_id,
            roll_version_id=roll_version_id,
            roll_checksum=roll_checksum,
            created_at=created_at,
            total_records=len(observations),
            new_records=new_count,
            duplicate_records=dup_count,
            identical_records=identical_count,
            stale_records=stale_count,
            concurrent_conflicts=concurrent_count,
            roll_mismatch_records=roll_mismatch_count,
            voter_not_found_records=voter_not_found_count,
            invalid_records=invalid_count,
            permission_conflict_records=perm_conflict_count,
            is_compatible_roll=is_compatible_roll,
            can_commit=can_commit,
            rejection_reason=rejection_reason,
            records=preview_records,
            raw_packet_metadata=metadata,
        )

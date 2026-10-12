"""Backup and Disaster Recovery engine using authenticated encrypted .vlsync containers."""

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import (
    AuditLog,
    FieldStatus,
    FieldStatusHistory,
    FieldStatusType,
    ReviewStatusType,
    RollVersion,
    RollVersionStatus,
    Voter,
    generate_uuid,
    utc_now,
)
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, SecurityContext
from voterlens.sync.models import (
    ConflictResolutionStatus,
    ConflictType,
    FieldObservation,
    PacketType,
    SyncConflict,
    SyncPacketDirection,
    SyncPacketRecord,
    SyncPacketStatus,
)
from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    InvalidPacketError,
    RollMismatchError,
    deserialize_and_decrypt_packet,
    serialize_packet_envelope,
)
from voterlens.sync.transport import VLSyncFileTransport


class BackupService:
    """Manages creation and safe restoration of encrypted Gazette and Field Delta backups."""

    def __init__(self, transport: Optional[VLSyncFileTransport] = None):
        self.transport = transport or VLSyncFileTransport()

    def create_gazette_snapshot(
        self,
        session: Session,
        roll_version_id: str,
        destination_path: str,
        transfer_passphrase: str,
        operator_username: str,
        security_context: Optional[SecurityContext] = None,
    ) -> str:
        """Create an authenticated, encrypted snapshot of the statutory official roll."""
        if security_context:
            security_context.require_permission(Permission.BACKUP_RESTORE)

        roll = session.execute(
            select(RollVersion).where(RollVersion.id == roll_version_id)
        ).scalars().first()
        if not roll:
            raise ValueError(f"Roll version {roll_version_id} not found")
        if not roll.checksum_hash:
            raise ValueError(f"Roll version {roll_version_id} is missing checksum")

        voters = session.execute(
            select(Voter).where(Voter.roll_version_id == roll_version_id)
        ).scalars().all()

        voter_records = [
            {
                "id": v.id,
                "serial_number": v.serial_number,
                "epic_number": v.epic_number,
                "name": v.name,
                "normalized_name": v.normalized_name,
                "relative_name": v.relative_name,
                "normalized_relative_name": v.normalized_relative_name,
                "relative_type": v.relative_type,
                "house_number": v.house_number,
                "normalized_house_number": v.normalized_house_number,
                "age": v.age,
                "gender": v.gender,
                "part_number": v.part_number,
                "section_number": v.section_number,
                "section_name": v.section_name,
                "polling_station_name": v.polling_station_name,
                "polling_station_address": v.polling_station_address,
                "photo_path": v.photo_path,
                "ocr_confidence": v.ocr_confidence,
            }
            for v in voters
        ]

        packet_id = generate_uuid()
        device_id = "backup-system"
        payload_dict = {
            "packet_id": packet_id,
            "roll_version_id": roll.id,
            "roll_checksum": roll.checksum_hash,
            "roll_metadata": {
                "id": roll.id,
                "state": roll.state,
                "district": roll.district,
                "assembly_constituency": roll.assembly_constituency,
                "roll_name": roll.roll_name,
                "roll_type": roll.roll_type,
                "publication_date": roll.publication_date,
                "record_count": roll.record_count,
                "checksum_hash": roll.checksum_hash,
            },
            "voters": voter_records,
            "observations": [],  # Empty for Gazette Snapshot
        }

        envelope = serialize_packet_envelope(
            packet_id=packet_id,
            source_device_id=device_id,
            source_user_id=operator_username,
            roll_version_id=roll.id,
            roll_checksum=roll.checksum_hash,
            observations=[],
            transfer_passphrase=transfer_passphrase,
            protocol_version=CURRENT_PROTOCOL_VERSION,
            packet_type=PacketType.GAZETTE_SNAPSHOT.value,
            custom_payload_dict=payload_dict,
        )

        output_path = self.transport.export_packet(envelope, destination_path)

        AuditService(session).log(
            action="BACKUP_GAZETTE_SNAPSHOT_CREATED",
            entity_type="Backup",
            entity_id=packet_id,
            performed_by=operator_username,
            details={
                "packet_id": packet_id,
                "roll_version_id": roll.id,
                "voter_count": len(voter_records),
                "output_file": str(output_path),
            },
        )
        return output_path

    def create_field_delta_backup(
        self,
        session: Session,
        roll_version_id: str,
        destination_path: str,
        transfer_passphrase: str,
        operator_username: str,
        security_context: Optional[SecurityContext] = None,
    ) -> str:
        """Create an authenticated, encrypted backup of all field observations and history."""
        if security_context:
            security_context.require_permission(Permission.BACKUP_RESTORE)

        roll = session.execute(
            select(RollVersion).where(RollVersion.id == roll_version_id)
        ).scalars().first()
        if not roll:
            raise ValueError(f"Roll version {roll_version_id} not found")

        # 1. Fetch field observations
        observations = session.execute(
            select(FieldObservation).where(FieldObservation.roll_version_id == roll_version_id)
        ).scalars().all()

        obs_list = [
            {
                "observation_id": o.observation_id,
                "voter_epic": o.voter_epic,
                "voter_part_serial": o.voter_part_serial,
                "roll_version_id": o.roll_version_id,
                "roll_checksum": o.roll_checksum,
                "field_status": o.field_status.value,
                "phone_number": o.phone_number,
                "notes": o.notes,
                "created_by": o.created_by,
                "created_at": o.created_at.isoformat(),
                "origin_device_id": o.origin_device_id,
                "supersedes_id": o.supersedes_id,
                "is_revoked": o.is_revoked,
                "revocation_reason": o.revocation_reason,
            }
            for o in observations
        ]

        # 2. Fetch conflicts
        conflicts = session.execute(select(SyncConflict)).scalars().all()
        conflict_list = [
            {
                "id": c.id,
                "voter_epic": c.voter_epic,
                "conflict_type": c.conflict_type.value,
                "local_observation_id": c.local_observation_id,
                "incoming_observation_id": c.incoming_observation_id,
                "resolution_status": c.resolution_status.value,
                "resolved_by": c.resolved_by,
                "resolved_at": c.resolved_at.isoformat() if c.resolved_at else None,
                "resolution_choice": c.resolution_choice,
                "resolution_notes": c.resolution_notes,
                "created_at": c.created_at.isoformat(),
            }
            for c in conflicts
        ]

        # 3. Fetch status history
        histories = session.execute(select(FieldStatusHistory)).scalars().all()
        history_list = [
            {
                "id": h.id,
                "voter_id": h.voter_id,
                "old_status": h.old_status,
                "new_status": h.new_status,
                "notes": h.notes,
                "changed_by": h.changed_by,
                "changed_at": h.changed_at.isoformat(),
            }
            for h in histories
        ]

        packet_id = generate_uuid()
        device_id = "backup-system"
        payload_dict = {
            "packet_id": packet_id,
            "roll_version_id": roll.id,
            "roll_checksum": roll.checksum_hash,
            "observations": obs_list,
            "conflicts": conflict_list,
            "histories": history_list,
        }

        envelope = serialize_packet_envelope(
            packet_id=packet_id,
            source_device_id=device_id,
            source_user_id=operator_username,
            roll_version_id=roll.id,
            roll_checksum=roll.checksum_hash,
            observations=obs_list,
            transfer_passphrase=transfer_passphrase,
            protocol_version=CURRENT_PROTOCOL_VERSION,
            packet_type=PacketType.FIELD_DELTA_BACKUP.value,
            custom_payload_dict=payload_dict,
        )

        output_path = self.transport.export_packet(envelope, destination_path)

        AuditService(session).log(
            action="BACKUP_FIELD_DELTA_CREATED",
            entity_type="Backup",
            entity_id=packet_id,
            performed_by=operator_username,
            details={
                "packet_id": packet_id,
                "roll_version_id": roll.id,
                "observation_count": len(obs_list),
                "conflict_count": len(conflict_list),
                "output_file": str(output_path),
            },
        )
        return output_path

    def restore_field_delta_backup(
        self,
        session: Session,
        source_file_path: str,
        transfer_passphrase: str,
        operator_username: str,
        security_context: Optional[SecurityContext] = None,
    ) -> Dict[str, Any]:
        """Safely restore field data without overwriting official voter data."""
        if security_context:
            security_context.require_permission(Permission.BACKUP_RESTORE)

        # 1. Read and validate container
        envelope = self.transport.read_packet(source_file_path)

        # 2. Authenticate and decrypt
        metadata, observations = deserialize_and_decrypt_packet(envelope, transfer_passphrase)
        payload = metadata.get("_decrypted_payload", {})

        roll_checksum = metadata["roll_checksum"]

        # 3. Roll Compatibility Verification
        active_roll = session.execute(
            select(RollVersion).where(
                RollVersion.checksum_hash == roll_checksum,
                RollVersion.status == RollVersionStatus.ACTIVE,
            )
        ).scalars().first()

        if not active_roll:
            raise RollMismatchError(
                f"Cannot restore backup: backup roll checksum '{roll_checksum}' "
                "does not match active local electoral roll"
            )

        # 4. Snapshot voter table row count to guarantee immutability
        voters_before = session.execute(select(Voter.id)).scalars().all()

        # 5. Restore observations idempotently
        obs_restored = 0
        obs_skipped = 0

        raw_obs_list = payload.get("observations", observations)
        for obs_data in raw_obs_list:
            obs_id = obs_data.get("observation_id")
            existing = session.execute(
                select(FieldObservation).where(FieldObservation.observation_id == obs_id)
            ).scalars().first()

            if existing:
                obs_skipped += 1
                continue

            voter = session.execute(
                select(Voter).where(
                    Voter.roll_version_id == active_roll.id,
                    Voter.epic_number == obs_data["voter_epic"],
                )
            ).scalars().first()

            created_dt = datetime.fromisoformat(obs_data["created_at"].replace("Z", "+00:00"))
            new_obs = FieldObservation(
                observation_id=obs_id,
                voter_id=voter.id if voter else None,
                voter_epic=obs_data["voter_epic"],
                voter_part_serial=obs_data.get("voter_part_serial"),
                roll_version_id=active_roll.id,
                roll_checksum=active_roll.checksum_hash,
                field_status=FieldStatusType(obs_data["field_status"]),
                phone_number=obs_data.get("phone_number"),
                notes=obs_data.get("notes"),
                created_by=obs_data.get("created_by", "backup_restore"),
                created_at=created_dt,
                origin_device_id=obs_data.get("origin_device_id", "restored_device"),
                received_at=utc_now(),
                supersedes_id=obs_data.get("supersedes_id"),
                is_revoked=obs_data.get("is_revoked", False),
                revocation_reason=obs_data.get("revocation_reason"),
            )
            session.add(new_obs)

            # Materialize current state if voter exists and observation is not revoked
            if voter and not obs_data.get("is_revoked", False):
                if voter.field_status:
                    if voter.field_status.reported_at is None or created_dt > voter.field_status.reported_at:
                        voter.field_status.status = FieldStatusType(obs_data["field_status"])
                        voter.field_status.phone_number = obs_data.get("phone_number")
                        voter.field_status.notes = obs_data.get("notes")
                        voter.field_status.reported_by = obs_data.get("created_by")
                        voter.field_status.reported_at = created_dt
                        voter.field_status.updated_at = utc_now()
                else:
                    fs = FieldStatus(
                        voter_id=voter.id,
                        status=FieldStatusType(obs_data["field_status"]),
                        phone_number=obs_data.get("phone_number"),
                        notes=obs_data.get("notes"),
                        reported_by=obs_data.get("created_by"),
                        reported_at=created_dt,
                    )
                    session.add(fs)

            obs_restored += 1

        # 6. Verify statutory voter immutability
        voters_after = session.execute(select(Voter.id)).scalars().all()
        if len(voters_before) != len(voters_after):
            session.rollback()
            raise RuntimeError("CRITICAL IMMUTABILITY VIOLATION: Backup restore modified voters table!")

        session.flush()

        AuditService(session).log(
            action="BACKUP_FIELD_DELTA_RESTORED",
            entity_type="Backup",
            entity_id=metadata["packet_id"],
            performed_by=operator_username,
            details={
                "packet_id": metadata["packet_id"],
                "observations_restored": obs_restored,
                "observations_skipped": obs_skipped,
            },
        )

        return {
            "status": "RESTORE_SUCCESS",
            "packet_id": metadata["packet_id"],
            "observations_restored": obs_restored,
            "observations_skipped": obs_skipped,
        }

    def restore_gazette_snapshot(
        self,
        session: Session,
        source_file_path: str,
        transfer_passphrase: str,
        operator_username: str,
        allow_replace_active: bool = False,
        security_context: Optional[SecurityContext] = None,
    ) -> Dict[str, Any]:
        """Safely bootstrap or restore an official statutory roll from an authenticated Gazette Snapshot."""
        if security_context:
            security_context.require_permission(Permission.BACKUP_RESTORE)

        # 1. Read and validate container
        envelope = self.transport.read_packet(source_file_path)
        if envelope.get("packet_type") != PacketType.GAZETTE_SNAPSHOT.value:
            raise InvalidPacketError(
                f"Expected packet_type '{PacketType.GAZETTE_SNAPSHOT.value}', got '{envelope.get('packet_type')}'"
            )

        proto_ver = envelope.get("protocol_version")
        if proto_ver != CURRENT_PROTOCOL_VERSION:
            raise InvalidPacketError(f"Unsupported protocol version: {proto_ver}")

        # 2. Authenticate and decrypt
        metadata, _ = deserialize_and_decrypt_packet(envelope, transfer_passphrase)
        payload = metadata.get("_decrypted_payload")
        if not payload or not isinstance(payload, dict):
            raise InvalidPacketError("Decrypted snapshot payload is malformed or missing")

        roll_meta = payload.get("roll_metadata")
        if not roll_meta or not isinstance(roll_meta, dict):
            raise InvalidPacketError("Snapshot manifest is missing 'roll_metadata'")

        for req_field in ("id", "state", "district", "assembly_constituency", "roll_name", "checksum_hash"):
            if req_field not in roll_meta or not isinstance(roll_meta[req_field], str) or not roll_meta[req_field].strip():
                raise InvalidPacketError(f"Snapshot roll_metadata missing or invalid mandatory string field '{req_field}'")

        if "record_count" not in roll_meta or not isinstance(roll_meta["record_count"], int):
            raise InvalidPacketError("Snapshot roll_metadata missing mandatory integer field 'record_count'")
        if roll_meta["record_count"] < 0 or roll_meta["record_count"] > 500000:
            raise InvalidPacketError(f"Snapshot roll_metadata invalid or unrealistic record_count: {roll_meta['record_count']}")

        roll_checksum = metadata["roll_checksum"]
        if roll_meta["checksum_hash"] != roll_checksum:
            raise InvalidPacketError(
                f"Declared checksum '{roll_meta['checksum_hash']}' does not match envelope checksum '{roll_checksum}'"
            )

        if roll_meta["id"] != metadata["roll_version_id"]:
            raise InvalidPacketError("Roll version ID mismatch between manifest and envelope")

        if "packet_id" in payload and payload["packet_id"] != metadata["packet_id"]:
            raise InvalidPacketError("Packet ID mismatch between payload and envelope")
        if "roll_version_id" in payload and payload["roll_version_id"] != metadata["roll_version_id"]:
            raise InvalidPacketError("Roll version ID mismatch between payload and envelope")
        if "roll_checksum" in payload and payload["roll_checksum"] != roll_checksum:
            raise InvalidPacketError("Roll checksum mismatch between payload and envelope")

        voters_list = payload.get("voters")
        if voters_list is None or not isinstance(voters_list, list):
            raise InvalidPacketError("Snapshot is missing 'voters' list")

        if len(voters_list) != roll_meta["record_count"]:
            raise InvalidPacketError(
                f"Voter record count mismatch: metadata declared {roll_meta['record_count']}, payload contained {len(voters_list)}"
            )

        # Pre-validate voters: check types, ranges, and uniqueness
        seen_ids = set()
        seen_epics = set()
        seen_part_serials = set()

        for idx, v_data in enumerate(voters_list):
            if not isinstance(v_data, dict):
                raise InvalidPacketError(f"Malformed voter record at index {idx}")
            for vf in ("id", "serial_number", "epic_number", "name", "part_number"):
                if vf not in v_data or v_data[vf] is None:
                    raise InvalidPacketError(f"Voter record missing mandatory field '{vf}'")

            v_id = str(v_data["id"]).strip()
            if not v_id:
                raise InvalidPacketError(f"Voter record at index {idx} has invalid 'id'")
            if v_id in seen_ids:
                raise InvalidPacketError(f"Duplicate voter ID detected at index {idx}")
            seen_ids.add(v_id)

            serial = v_data["serial_number"]
            if not isinstance(serial, int) or serial <= 0:
                raise InvalidPacketError(f"Voter record at index {idx} has invalid 'serial_number'")

            epic = str(v_data["epic_number"]).strip().upper()
            if not epic:
                raise InvalidPacketError(f"Voter record at index {idx} has invalid 'epic_number'")
            if epic in seen_epics:
                raise InvalidPacketError(f"Duplicate EPIC number detected at index {idx}")
            seen_epics.add(epic)

            part_serial = f"{str(v_data['part_number']).strip()}:{serial}"
            if part_serial in seen_part_serials:
                raise InvalidPacketError(f"Duplicate serial number in part at index {idx}")
            seen_part_serials.add(part_serial)

            if "roll_version_id" in v_data and v_data["roll_version_id"] and v_data["roll_version_id"] != roll_meta["id"]:
                raise InvalidPacketError(f"Voter record at index {idx} specifies mismatched roll_version_id")

            if "age" in v_data and v_data["age"] is not None:
                if not isinstance(v_data["age"], int) or v_data["age"] < 0 or v_data["age"] > 150:
                    raise InvalidPacketError(f"Voter record at index {idx} has invalid 'age'")

        # 3. Check existing active roll protection
        active_roll = session.execute(
            select(RollVersion).where(RollVersion.status == RollVersionStatus.ACTIVE)
        ).scalars().first()

        if active_roll:
            if active_roll.checksum_hash == roll_checksum:
                raise ValueError(f"Roll '{active_roll.roll_name}' with checksum '{roll_checksum}' is already installed and active")
            if not allow_replace_active:
                raise ValueError(
                    f"An active roll '{active_roll.roll_name}' is already installed. "
                    "Explicit authorization required to replace an active roll."
                )
            # Deactivate previous active roll
            active_roll.status = RollVersionStatus.SUPERSEDED

        # 4. Check if roll version already exists or create
        existing_roll = session.execute(
            select(RollVersion).where(RollVersion.id == roll_meta["id"])
        ).scalars().first()

        if existing_roll:
            target_roll = existing_roll
            target_roll.status = RollVersionStatus.ACTIVE
        else:
            target_roll = RollVersion(
                id=roll_meta["id"],
                state=roll_meta["state"],
                district=roll_meta["district"],
                assembly_constituency=roll_meta["assembly_constituency"],
                roll_name=roll_meta["roll_name"],
                roll_type=roll_meta.get("roll_type", "GENERAL"),
                publication_date=roll_meta.get("publication_date"),
                record_count=roll_meta["record_count"],
                status=RollVersionStatus.ACTIVE,
                checksum_hash=roll_checksum,
            )
            session.add(target_roll)
            session.flush()

        # 5. Insert voters atomically
        voters_inserted = 0
        for v_data in voters_list:
            for vf in ("id", "serial_number", "epic_number", "name", "part_number"):
                if vf not in v_data:
                    raise InvalidPacketError(f"Voter record missing mandatory field '{vf}'")

            existing_voter = session.execute(
                select(Voter.id).where(Voter.id == v_data["id"])
            ).scalars().first()

            if not existing_voter:
                new_voter = Voter(
                    id=v_data["id"],
                    roll_version_id=target_roll.id,
                    serial_number=v_data["serial_number"],
                    epic_number=v_data["epic_number"],
                    name=v_data["name"],
                    normalized_name=v_data.get("normalized_name", v_data["name"].lower()),
                    relative_name=v_data.get("relative_name", ""),
                    normalized_relative_name=v_data.get("normalized_relative_name", ""),
                    relative_type=v_data.get("relative_type", "OTHER"),
                    house_number=v_data.get("house_number", ""),
                    normalized_house_number=v_data.get("normalized_house_number", ""),
                    age=v_data.get("age", 0),
                    gender=v_data.get("gender", ""),
                    part_number=str(v_data["part_number"]),
                    section_number=str(v_data.get("section_number", "")),
                    section_name=v_data.get("section_name", ""),
                    polling_station_name=v_data.get("polling_station_name", ""),
                    polling_station_address=v_data.get("polling_station_address", ""),
                    photo_path=v_data.get("photo_path"),
                    ocr_confidence=v_data.get("ocr_confidence", 1.0),
                )
                session.add(new_voter)
                voters_inserted += 1

        session.flush()

        # 6. Audit trail
        AuditService(session).log(
            action="GAZETTE_SNAPSHOT_RESTORED",
            entity_type="RollVersion",
            entity_id=target_roll.id,
            performed_by=operator_username,
            details={
                "packet_id": metadata["packet_id"],
                "roll_version_id": target_roll.id,
                "roll_checksum": roll_checksum,
                "voter_count": voters_inserted,
            },
        )

        return {
            "status": "BOOTSTRAP_SUCCESS",
            "packet_id": metadata["packet_id"],
            "roll_version_id": target_roll.id,
            "roll_name": target_roll.roll_name,
            "voters_installed": voters_inserted,
            "roll_checksum": roll_checksum,
        }

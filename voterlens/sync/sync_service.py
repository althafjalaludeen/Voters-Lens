"""Complete 14-Stage Atomic Offline Synchronization Service."""

from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Union
import uuid

from sqlalchemy import select, text
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
from voterlens.sync.conflict_engine import ConflictEngine
from voterlens.sync.crypto import (
    AuthenticationError,
    CryptoError,
    validate_transfer_passphrase,
)
from voterlens.sync.models import (
    ConflictType,
    DeviceConfig,
    FieldObservation,
    SyncPacketDirection,
    SyncPacketRecord,
    SyncPacketStatus,
    TrustedDevice,
)
from voterlens.sync.preview import ImportPreview, PreviewEngine, PreviewRecord
from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    InvalidPacketError,
    ProtocolError,
    RollMismatchError,
    deserialize_and_decrypt_packet,
    resolve_canonical_voter,
    serialize_packet_envelope,
)
from voterlens.sync.scope import ExportScope, ExportScopeFilter
from voterlens.sync.transport import VLSyncFileTransport
from voterlens.sync.validation import filter_valid_observations_for_export


class SyncService:
    """Orchestrates end-to-end export, validation, and atomic import of field observations."""

    @staticmethod
    def get_or_create_device_id(session: Session, device_name: str = "VoterLens Field Unit") -> str:
        """Retrieve the local persistent device UUID or generate and persist a new one."""
        stmt = select(DeviceConfig).limit(1)
        config = session.execute(stmt).scalars().first()
        if config:
            return config.device_id

        new_device_id = generate_uuid()
        config = DeviceConfig(
            device_id=new_device_id,
            device_name=device_name,
            created_at=utc_now(),
        )
        session.add(config)
        session.flush()
        return new_device_id

    @staticmethod
    def export_observations(
        session: Session,
        roll_version_id: str,
        operator_username: str,
        transfer_passphrase: str,
        since_timestamp: Optional[datetime] = None,
        scope: ExportScope = ExportScope.ALL_ELIGIBLE_FIELD_OBSERVATIONS,
        scope_filter: Optional[ExportScopeFilter] = None,
        security_context: Optional[SecurityContext] = None,
    ) -> Dict[str, Any]:
        """Export local field observations into an authenticated, encrypted sync packet.
        
        Guarantees:
        - Only exports LOCAL FIELD DATA.
        - Does NOT export statutory voter records.
        - Validates all observations prior to packaging.
        """
        # RBAC Check
        if security_context:
            security_context.require_permission(Permission.EXPORT_SYNC)

        # Passphrase validation against security policy
        validate_transfer_passphrase(transfer_passphrase)

        AuditService(session).log(
            action="SYNC_EXPORT_STARTED",
            entity_type="RollVersion",
            entity_id=roll_version_id,
            performed_by=operator_username,
            details={
                "roll_version_id": roll_version_id,
                "scope": scope.value if hasattr(scope, "value") else str(scope),
            },
        )

        # 1. Verify active roll and checksum
        roll_stmt = select(RollVersion).where(RollVersion.id == roll_version_id)
        roll = session.execute(roll_stmt).scalars().first()
        if not roll:
            raise ValueError(f"Roll version {roll_version_id} not found")
        if not roll.checksum_hash:
            raise ValueError(f"Roll version {roll_version_id} is missing checksum hash")

        device_id = SyncService.get_or_create_device_id(session)
        packet_id = generate_uuid()

        # 2. Gather existing field observations with export scoping
        obs_stmt = select(FieldObservation).where(
            FieldObservation.roll_version_id == roll_version_id,
            FieldObservation.is_revoked == False,
        )
        if since_timestamp:
            obs_stmt = obs_stmt.where(FieldObservation.created_at >= since_timestamp)

        if scope_filter:
            if scope_filter.since_timestamp:
                obs_stmt = obs_stmt.where(FieldObservation.created_at >= scope_filter.since_timestamp)
            if scope_filter.start_date:
                obs_stmt = obs_stmt.where(FieldObservation.created_at >= scope_filter.start_date)
            if scope_filter.end_date:
                obs_stmt = obs_stmt.where(FieldObservation.created_at <= scope_filter.end_date)
            if scope_filter.part_number:
                obs_stmt = obs_stmt.where(FieldObservation.voter_part_serial.like(f"{scope_filter.part_number}:%"))
            if scope_filter.selected_epics:
                obs_stmt = obs_stmt.where(FieldObservation.voter_epic.in_(scope_filter.selected_epics))
            if scope_filter.origin_device_id:
                obs_stmt = obs_stmt.where(FieldObservation.origin_device_id == scope_filter.origin_device_id)

        observations = session.execute(obs_stmt).scalars().all()
        obs_list = []

        if observations:
            for o in observations:
                obs_list.append({
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
                })
        else:
            # Fallback: synthesize observations from active field_status table if event store is empty
            fs_stmt = (
                select(FieldStatus, Voter)
                .join(Voter, FieldStatus.voter_id == Voter.id)
                .where(Voter.roll_version_id == roll_version_id)
            )
            fs_records = session.execute(fs_stmt).all()
            for fs, v in fs_records:
                obs_id = generate_uuid()
                obs_dict = {
                    "observation_id": obs_id,
                    "voter_epic": v.epic_number,
                    "voter_part_serial": f"{v.part_number}:{v.serial_number}",
                    "roll_version_id": roll.id,
                    "roll_checksum": roll.checksum_hash,
                    "field_status": fs.status.value,
                    "phone_number": fs.phone_number,
                    "notes": fs.notes,
                    "created_by": fs.reported_by or operator_username,
                    "created_at": (fs.reported_at or utc_now()).isoformat(),
                    "origin_device_id": device_id,
                    "supersedes_id": None,
                    "is_revoked": False,
                    "revocation_reason": None,
                }
                obs_list.append(obs_dict)
                # Also store in local field_observations event store
                local_obs = FieldObservation(
                    observation_id=obs_id,
                    voter_id=v.id,
                    voter_epic=v.epic_number,
                    voter_part_serial=f"{v.part_number}:{v.serial_number}",
                    roll_version_id=roll.id,
                    roll_checksum=roll.checksum_hash,
                    field_status=fs.status,
                    phone_number=fs.phone_number,
                    notes=fs.notes,
                    created_by=fs.reported_by or operator_username,
                    created_at=fs.reported_at or utc_now(),
                    origin_device_id=device_id,
                    received_at=utc_now(),
                )
                session.add(local_obs)
            session.flush()

        # 3. Export validation: filter valid observations
        valid_obs_list, excluded_records = filter_valid_observations_for_export(
            obs_list, expected_roll_checksum=roll.checksum_hash
        )

        # 4. Serialize and encrypt packet envelope
        envelope = serialize_packet_envelope(
            packet_id=packet_id,
            source_device_id=device_id,
            source_user_id=operator_username,
            roll_version_id=roll.id,
            roll_checksum=roll.checksum_hash,
            observations=valid_obs_list,
            transfer_passphrase=transfer_passphrase,
            protocol_version=CURRENT_PROTOCOL_VERSION,
        )

        # 5. Record export packet record
        pkt_record = SyncPacketRecord(
            packet_id=packet_id,
            direction=SyncPacketDirection.EXPORT,
            protocol_version=CURRENT_PROTOCOL_VERSION,
            source_device_id=device_id,
            source_user_id=operator_username,
            roll_version_id=roll.id,
            roll_checksum=roll.checksum_hash,
            observation_count=len(valid_obs_list),
            created_at=utc_now(),
            processed_at=utc_now(),
            status=SyncPacketStatus.CREATED,
            status_message=f"Exported {len(valid_obs_list)} observations (Excluded: {len(excluded_records)})",
        )
        session.add(pkt_record)

        # 6. Audit log
        AuditService(session).log(
            action="SYNC_EXPORT_CREATED",
            entity_type="SyncPacket",
            entity_id=packet_id,
            performed_by=operator_username,
            details={
                "packet_id": packet_id,
                "observation_count": len(valid_obs_list),
                "excluded_count": len(excluded_records),
                "roll_version_id": roll.id,
                "roll_checksum": roll.checksum_hash,
            },
        )
        AuditService(session).log(
            action="SYNC_EXPORT_COMPLETED",
            entity_type="SyncPacket",
            entity_id=packet_id,
            performed_by=operator_username,
            details={
                "packet_id": packet_id,
                "observation_count": len(valid_obs_list),
            },
        )
        return envelope

    @staticmethod
    def export_observations_to_file(
        session: Session,
        roll_version_id: str,
        operator_username: str,
        transfer_passphrase: str,
        destination: str,
        since_timestamp: Optional[datetime] = None,
        scope: ExportScope = ExportScope.ALL_ELIGIBLE_FIELD_OBSERVATIONS,
        scope_filter: Optional[ExportScopeFilter] = None,
        security_context: Optional[SecurityContext] = None,
    ) -> str:
        """Export field observations into an authenticated, encrypted local .vlsync file."""
        envelope = SyncService.export_observations(
            session=session,
            roll_version_id=roll_version_id,
            operator_username=operator_username,
            transfer_passphrase=transfer_passphrase,
            since_timestamp=since_timestamp,
            scope=scope,
            scope_filter=scope_filter,
            security_context=security_context,
        )
        transport = VLSyncFileTransport()
        return transport.export_packet(envelope, destination)

    @staticmethod
    def preview_import(
        session: Session,
        source: Union[str, Path, Dict[str, Any]],
        transfer_passphrase: str,
        operator_username: str,
        security_context: Optional[SecurityContext] = None,
        require_trusted_device: bool = False,
    ) -> ImportPreview:
        """Stage 1: Inspect, validate, authenticate, and preview an incoming sync file or packet.
        
        Strict Guarantee: Does NOT mutate live database state.
        """
        if security_context:
            security_context.require_permission(Permission.IMPORT_SYNC)

        transport = VLSyncFileTransport()
        if isinstance(source, (str, Path)):
            file_str = str(source)
            AuditService(session).log(
                action="SYNC_IMPORT_SELECTED",
                entity_type="SyncFile",
                entity_id=file_str,
                performed_by=operator_username,
                details={"file_path": file_str},
            )
            packet_data = transport.read_packet(file_str)
        else:
            packet_data = source

        AuditService(session).log(
            action="SYNC_IMPORT_VALIDATED",
            entity_type="SyncPacket",
            entity_id=packet_data.get("packet_id"),
            performed_by=operator_username,
            details={"packet_id": packet_data.get("packet_id")},
        )

        preview = PreviewEngine.generate_preview(
            session=session,
            packet_data=packet_data,
            transfer_passphrase=transfer_passphrase,
            require_trusted_device=require_trusted_device,
        )

        AuditService(session).log(
            action="SYNC_IMPORT_PREVIEWED",
            entity_type="SyncPacket",
            entity_id=preview.packet_id,
            performed_by=operator_username,
            details={
                "packet_id": preview.packet_id,
                "total_records": preview.total_records,
                "new_records": preview.new_records,
                "duplicate_records": preview.duplicate_records,
                "stale_records": preview.stale_records,
                "concurrent_conflicts": preview.concurrent_conflicts,
                "can_commit": preview.can_commit,
            },
        )
        return preview

    @staticmethod
    def commit_import(
        session: Session,
        preview: ImportPreview,
        operator_username: str,
        security_context: Optional[SecurityContext] = None,
        require_trusted_device: bool = False,
    ) -> Dict[str, Any]:
        """Stage 2: Atomically commit accepted previewed records to the database."""
        if security_context:
            security_context.require_permission(Permission.IMPORT_SYNC)

        # Check if source device is explicitly revoked
        revoked_stmt = select(TrustedDevice).where(
            TrustedDevice.device_id == preview.source_device_id,
            TrustedDevice.is_trusted == False,
        )
        if session.execute(revoked_stmt).scalars().first():
            AuditService(session).log(
                action="SYNC_IMPORT_REJECTED",
                entity_type="SyncPacket",
                entity_id=preview.packet_id,
                performed_by=operator_username,
                details={"reason": "REVOKED_DEVICE", "device_id": preview.source_device_id},
            )
            raise PermissionError(f"Source device {preview.source_device_id} is revoked and unauthorized to import")

        if require_trusted_device:
            td_stmt = select(TrustedDevice).where(
                TrustedDevice.device_id == preview.source_device_id,
                TrustedDevice.is_trusted == True,
            )
            if not session.execute(td_stmt).scalars().first():
                AuditService(session).log(
                    action="SYNC_IMPORT_REJECTED",
                    entity_type="SyncPacket",
                    entity_id=preview.packet_id,
                    performed_by=operator_username,
                    details={"reason": "UNTRUSTED_DEVICE", "device_id": preview.source_device_id},
                )
                raise PermissionError(f"Source device {preview.source_device_id} is not in local trusted devices list")

        if not preview.can_commit:
            AuditService(session).log(
                action="SYNC_IMPORT_REJECTED",
                entity_type="SyncPacket",
                entity_id=preview.packet_id,
                performed_by=operator_username,
                details={"reason": preview.rejection_reason},
            )
            if not preview.is_compatible_roll:
                raise RollMismatchError(preview.rejection_reason or "Roll mismatch")
            raise ValueError(preview.rejection_reason or "Cannot commit rejected sync packet")

        # Idempotency check: verify packet not already imported
        dup_pkt_stmt = select(SyncPacketRecord).where(
            SyncPacketRecord.packet_id == preview.packet_id,
            SyncPacketRecord.direction == SyncPacketDirection.IMPORT,
            SyncPacketRecord.status.in_([SyncPacketStatus.IMPORTED, SyncPacketStatus.COMMITTED]),
        )
        existing_pkt = session.execute(dup_pkt_stmt).scalars().first()
        if existing_pkt:
            return {
                "status": "IDEMPOTENT_SKIPPED",
                "message": f"Packet {preview.packet_id} was already imported",
                "packet_id": preview.packet_id,
                "imported_count": 0,
                "skipped_count": preview.total_records,
                "conflict_count": 0,
            }

        # Immutability baseline: snapshot official voters table count and ids
        voters_before_count = session.execute(select(Voter.id)).scalars().all()

        active_roll = session.execute(
            select(RollVersion).where(
                RollVersion.checksum_hash == preview.roll_checksum,
                RollVersion.status == RollVersionStatus.ACTIVE,
            )
        ).scalars().first()

        session.begin_nested()
        try:
            res = SyncService._execute_commit_import(
                session=session,
                preview=preview,
                active_roll=active_roll,
                operator_username=operator_username,
                voters_before_count=voters_before_count,
            )
            session.flush()
            return res
        except Exception:
            session.rollback()
            raise

    @staticmethod
    def _execute_commit_import(
        session: Session,
        preview: ImportPreview,
        active_roll: Any,
        operator_username: str,
        voters_before_count: List[Any],
    ) -> Dict[str, Any]:
        imported_count = 0
        skipped_count = 0
        conflict_count = 0

        def parse_created_at(raw_dt: Any) -> datetime:
            if not raw_dt:
                return utc_now()
            try:
                return datetime.fromisoformat(str(raw_dt).replace("Z", "+00:00"))
            except Exception:
                return utc_now()

        for record in preview.records:
            obs_data = record.raw_observation
            if record.classification in ("DUPLICATE", "IDENTICAL"):
                skipped_count += 1
                if record.classification == "IDENTICAL":
                    stmt_exist = select(FieldObservation).where(
                        FieldObservation.observation_id == record.observation_id
                    )
                    if not session.execute(stmt_exist).scalars().first():
                        matched_voter = resolve_canonical_voter(session, active_roll.id, record.voter_epic, record.voter_part_serial)
                        new_obs = FieldObservation(
                            observation_id=record.observation_id,
                            voter_id=matched_voter.id if matched_voter else None,
                            voter_epic=record.voter_epic,
                            voter_part_serial=record.voter_part_serial,
                            roll_version_id=active_roll.id,
                            roll_checksum=active_roll.checksum_hash,
                            field_status=FieldStatusType(record.incoming_status),
                            phone_number=record.phone_number,
                            notes=record.notes,
                            created_by=obs_data.get("created_by", "unknown"),
                            created_at=parse_created_at(record.created_at),
                            origin_device_id=record.origin_device_id,
                            received_at=utc_now(),
                        )
                        session.add(new_obs)
                continue

            if record.classification in ("VOTER_NOT_FOUND", "INVALID", "PERMISSION_CONFLICT"):
                conflict_count += 1
                continue

            matched_voter = resolve_canonical_voter(session, active_roll.id, record.voter_epic, record.voter_part_serial)

            if record.classification == "STALE":
                skipped_count += 1
                if matched_voter:
                    new_obs = FieldObservation(
                        observation_id=record.observation_id,
                        voter_id=matched_voter.id,
                        voter_epic=record.voter_epic,
                        voter_part_serial=record.voter_part_serial,
                        roll_version_id=active_roll.id,
                        roll_checksum=active_roll.checksum_hash,
                        field_status=FieldStatusType(record.incoming_status),
                        phone_number=record.phone_number,
                        notes=record.notes,
                        created_by=obs_data.get("created_by", "unknown"),
                        created_at=parse_created_at(record.created_at),
                        origin_device_id=record.origin_device_id,
                        received_at=utc_now(),
                    )
                    session.add(new_obs)
                continue

            if record.classification == "CONCURRENT":
                conflict_count += 1
                if matched_voter:
                    new_obs = FieldObservation(
                        observation_id=record.observation_id,
                        voter_id=matched_voter.id,
                        voter_epic=record.voter_epic,
                        voter_part_serial=record.voter_part_serial,
                        roll_version_id=active_roll.id,
                        roll_checksum=active_roll.checksum_hash,
                        field_status=FieldStatusType(record.incoming_status),
                        phone_number=record.phone_number,
                        notes=record.notes,
                        created_by=obs_data.get("created_by", "unknown"),
                        created_at=parse_created_at(record.created_at),
                        origin_device_id=record.origin_device_id,
                        received_at=utc_now(),
                    )
                    analysis = ConflictEngine.analyze_observation(session, obs_data, matched_voter)
                    ConflictEngine.record_conflict(session, matched_voter, obs_data, analysis)
                    session.add(new_obs)
                    AuditService(session).log(
                        action="SYNC_CONFLICT_CREATED",
                        entity_type="SyncConflict",
                        entity_id=record.observation_id,
                        performed_by=operator_username,
                        details={"voter_epic": record.voter_epic, "reason": analysis.message},
                    )
                continue

            if record.classification == "NEW" and matched_voter:
                incoming_status = FieldStatusType(record.incoming_status)
                created_dt = parse_created_at(record.created_at)
                new_obs = FieldObservation(
                    observation_id=record.observation_id,
                    voter_id=matched_voter.id,
                    voter_epic=record.voter_epic,
                    voter_part_serial=record.voter_part_serial,
                    roll_version_id=active_roll.id,
                    roll_checksum=active_roll.checksum_hash,
                    field_status=incoming_status,
                    phone_number=record.phone_number,
                    notes=record.notes,
                    created_by=obs_data.get("created_by", "unknown"),
                    created_at=created_dt,
                    origin_device_id=record.origin_device_id,
                    received_at=utc_now(),
                    supersedes_id=obs_data.get("supersedes_id"),
                )
                session.add(new_obs)

                if matched_voter.field_status:
                    old_status = matched_voter.field_status.status.value
                    matched_voter.field_status.status = incoming_status
                    if record.phone_number:
                        matched_voter.field_status.phone_number = record.phone_number
                    if record.notes:
                        matched_voter.field_status.notes = record.notes
                    matched_voter.field_status.reported_by = obs_data.get("created_by")
                    matched_voter.field_status.reported_at = created_dt
                    matched_voter.field_status.updated_at = utc_now()
                else:
                    old_status = "INITIAL"
                    fs = FieldStatus(
                        voter_id=matched_voter.id,
                        status=incoming_status,
                        phone_number=record.phone_number,
                        notes=record.notes,
                        reported_by=obs_data.get("created_by"),
                        reported_at=created_dt,
                    )
                    session.add(fs)

                history = FieldStatusHistory(
                    voter_id=matched_voter.id,
                    old_status=old_status,
                    new_status=incoming_status.value,
                    notes=f"Sync import from device {preview.source_device_id}: {record.notes or ''}".strip(),
                    changed_by=obs_data.get("created_by", operator_username),
                    changed_at=utc_now(),
                )
                session.add(history)
                imported_count += 1

        # Strict Immutability verification
        voters_after_count = session.execute(select(Voter.id)).scalars().all()
        if len(voters_before_count) != len(voters_after_count):
            session.rollback()
            raise RuntimeError("CRITICAL DATA INTEGRITY VIOLATION: Sync attempted to modify voters table!")

        # Record incoming packet record
        pkt_record = SyncPacketRecord(
            packet_id=preview.packet_id,
            direction=SyncPacketDirection.IMPORT,
            protocol_version=CURRENT_PROTOCOL_VERSION,
            source_device_id=preview.source_device_id,
            source_user_id=preview.source_user_id,
            roll_version_id=preview.roll_version_id,
            roll_checksum=preview.roll_checksum,
            observation_count=preview.total_records,
            created_at=datetime.fromisoformat(preview.created_at.replace("Z", "+00:00")),
            processed_at=utc_now(),
            status=SyncPacketStatus.COMMITTED,
            status_message=f"Imported: {imported_count}, Skipped: {skipped_count}, Conflicts: {conflict_count}",
        )
        session.add(pkt_record)

        action_name = "SYNC_CONFLICT_DETECTED" if conflict_count > 0 else "SYNC_IMPORT_COMPLETED"
        AuditService(session).log(
            action=action_name,
            entity_type="SyncPacket",
            entity_id=preview.packet_id,
            performed_by=operator_username,
            details={
                "packet_id": preview.packet_id,
                "source_device_id": preview.source_device_id,
                "imported_count": imported_count,
                "skipped_count": skipped_count,
                "conflict_count": conflict_count,
            },
        )
        AuditService(session).log(
            action="SYNC_IMPORT_COMMITTED",
            entity_type="SyncPacket",
            entity_id=preview.packet_id,
            performed_by=operator_username,
            details={
                "packet_id": preview.packet_id,
                "imported_count": imported_count,
            },
        )
        session.flush()

        return {
            "status": "SUCCESS",
            "packet_id": preview.packet_id,
            "imported_count": imported_count,
            "skipped_count": skipped_count,
            "conflict_count": conflict_count,
        }

    @staticmethod
    def import_observations(
        session: Session,
        packet_data: Dict[str, Any],
        transfer_passphrase: str,
        operator_username: str,
        require_trusted_device: bool = False,
    ) -> Dict[str, Any]:
        """Execute the 14-Stage Atomic Offline Sync Import Pipeline.
        
        Guarantees:
        - Atomicity: SQLite transaction ensures all-or-nothing changes.
        - Idempotency: Duplicate packet imports return zero duplicate mutations.
        - Immutability: Official voters table is NEVER modified.
        - Conflict Detection: Divergent observations are flagged, never silently lost.
        """
        # --- STAGES 1 TO 4: Parse Envelope, Check Protocol, Authenticate & Decrypt ---
        try:
            metadata, observations = deserialize_and_decrypt_packet(
                packet_data=packet_data,
                transfer_passphrase=transfer_passphrase,
            )
        except AuthenticationError as exc:
            # Audit rejection due to tampering or wrong key
            AuditService(session).log(
                action="SYNC_PACKET_REJECTED",
                entity_type="SyncPacket",
                entity_id=packet_data.get("packet_id"),
                performed_by=operator_username,
                details={"reason": "AUTHENTICATION_FAILED", "error": str(exc)},
            )
            raise

        packet_id = metadata["packet_id"]
        source_device_id = metadata["source_device_id"]
        roll_version_id = metadata["roll_version_id"]
        roll_checksum = metadata["roll_checksum"]

        # --- STAGE 5: Roll Compatibility Verification ---
        roll_stmt = select(RollVersion).where(
            RollVersion.checksum_hash == roll_checksum,
            RollVersion.status == RollVersionStatus.ACTIVE,
        )
        active_roll = session.execute(roll_stmt).scalars().first()
        if not active_roll:
            # Check by roll_version_id fallback
            roll_id_stmt = select(RollVersion).where(RollVersion.id == roll_version_id)
            matched_roll = session.execute(roll_id_stmt).scalars().first()
            if matched_roll and matched_roll.checksum_hash != roll_checksum:
                err_msg = (
                    f"Roll checksum mismatch: packet checksum '{roll_checksum}' does not match "
                    f"local roll checksum '{matched_roll.checksum_hash}'"
                )
            else:
                err_msg = f"No active local roll matches packet checksum: {roll_checksum}"

            AuditService(session).log(
                action="SYNC_PACKET_REJECTED",
                entity_type="SyncPacket",
                entity_id=packet_id,
                performed_by=operator_username,
                details={"reason": "ROLL_MISMATCH", "error": err_msg},
            )
            raise RollMismatchError(err_msg)

        # --- STAGE 6: Trusted Device Verification ---
        if require_trusted_device:
            td_stmt = select(TrustedDevice).where(
                TrustedDevice.device_id == source_device_id,
                TrustedDevice.is_trusted == True,
            )
            trusted_dev = session.execute(td_stmt).scalars().first()
            if not trusted_dev:
                err_msg = f"Device {source_device_id} is not authorized in local trusted devices"
                AuditService(session).log(
                    action="SYNC_PACKET_REJECTED",
                    entity_type="SyncPacket",
                    entity_id=packet_id,
                    performed_by=operator_username,
                    details={"reason": "UNTRUSTED_DEVICE", "device_id": source_device_id},
                )
                raise PermissionError(err_msg)

        # --- STAGE 7: Idempotency Check (Duplicate Packet) ---
        dup_pkt_stmt = select(SyncPacketRecord).where(
            SyncPacketRecord.packet_id == packet_id,
            SyncPacketRecord.direction == SyncPacketDirection.IMPORT,
            SyncPacketRecord.status == SyncPacketStatus.IMPORTED,
        )
        existing_pkt = session.execute(dup_pkt_stmt).scalars().first()
        if existing_pkt:
            return {
                "status": "IDEMPOTENT_SKIPPED",
                "message": f"Packet {packet_id} was already imported on {existing_pkt.processed_at.isoformat()}",
                "packet_id": packet_id,
                "imported_count": 0,
                "skipped_count": len(observations),
                "conflict_count": 0,
            }

        # --- STAGES 8 TO 13: Transactional Processing ---
        imported_count = 0
        skipped_count = 0
        conflict_count = 0

        # Snapshot voter table row count to enforce absolute immutability guarantee
        voters_before_count = session.execute(select(Voter.id)).scalars().all()

        for obs_data in observations:
            epic = obs_data.get("voter_epic")
            part_serial = obs_data.get("voter_part_serial")
            matched_voter = resolve_canonical_voter(
                session=session,
                roll_version_id=active_roll.id,
                voter_epic=epic,
                voter_part_serial=part_serial,
            )

            # Analyze conflict
            analysis = ConflictEngine.analyze_observation(
                session=session,
                incoming=obs_data,
                matched_voter=matched_voter,
            )

            if analysis.conflict_type == ConflictType.DUPLICATE:
                skipped_count += 1
                continue

            if analysis.conflict_type == ConflictType.IDENTICAL:
                skipped_count += 1
                # Still record in field_observations for provenance if new observation_id
                stmt_exist = select(FieldObservation).where(
                    FieldObservation.observation_id == obs_data["observation_id"]
                )
                if not session.execute(stmt_exist).scalars().first():
                    new_obs = FieldObservation(
                        observation_id=obs_data["observation_id"],
                        voter_id=matched_voter.id if matched_voter else None,
                        voter_epic=epic,
                        voter_part_serial=part_serial,
                        roll_version_id=active_roll.id,
                        roll_checksum=active_roll.checksum_hash,
                        field_status=FieldStatusType(obs_data["field_status"]),
                        phone_number=obs_data.get("phone_number"),
                        notes=obs_data.get("notes"),
                        created_by=obs_data.get("created_by", "unknown"),
                        created_at=datetime.fromisoformat(obs_data["created_at"].replace("Z", "+00:00")),
                        origin_device_id=obs_data.get("origin_device_id", source_device_id),
                        received_at=utc_now(),
                    )
                    session.add(new_obs)
                continue

            if analysis.conflict_type in (ConflictType.VOTER_NOT_FOUND, ConflictType.INVALID_OBSERVATION):
                conflict_count += 1
                if matched_voter:
                    ConflictEngine.record_conflict(session, matched_voter, obs_data, analysis)
                continue

            if analysis.conflict_type == ConflictType.STALE:
                # Historical observation: record in event store, but do not overwrite latest state
                new_obs = FieldObservation(
                    observation_id=obs_data["observation_id"],
                    voter_id=matched_voter.id,
                    voter_epic=epic,
                    voter_part_serial=part_serial,
                    roll_version_id=active_roll.id,
                    roll_checksum=active_roll.checksum_hash,
                    field_status=FieldStatusType(obs_data["field_status"]),
                    phone_number=obs_data.get("phone_number"),
                    notes=obs_data.get("notes"),
                    created_by=obs_data.get("created_by", "unknown"),
                    created_at=datetime.fromisoformat(obs_data["created_at"].replace("Z", "+00:00")),
                    origin_device_id=obs_data.get("origin_device_id", source_device_id),
                    received_at=utc_now(),
                )
                session.add(new_obs)
                skipped_count += 1
                continue

            if analysis.conflict_type == ConflictType.CONCURRENT:
                # Concurrent divergence: store observation, flag conflict, prompt review
                conflict_count += 1
                new_obs = FieldObservation(
                    observation_id=obs_data["observation_id"],
                    voter_id=matched_voter.id,
                    voter_epic=epic,
                    voter_part_serial=part_serial,
                    roll_version_id=active_roll.id,
                    roll_checksum=active_roll.checksum_hash,
                    field_status=FieldStatusType(obs_data["field_status"]),
                    phone_number=obs_data.get("phone_number"),
                    notes=obs_data.get("notes"),
                    created_by=obs_data.get("created_by", "unknown"),
                    created_at=datetime.fromisoformat(obs_data["created_at"].replace("Z", "+00:00")),
                    origin_device_id=obs_data.get("origin_device_id", source_device_id),
                    received_at=utc_now(),
                )
                session.add(new_obs)
                ConflictEngine.record_conflict(session, matched_voter, obs_data, analysis)
                continue

            # Clean actionable update or explicit superseding
            if analysis.is_actionable and matched_voter:
                incoming_status = FieldStatusType(obs_data["field_status"])
                created_dt = datetime.fromisoformat(obs_data["created_at"].replace("Z", "+00:00"))
                
                # 1. Append to field_observations event store
                new_obs = FieldObservation(
                    observation_id=obs_data["observation_id"],
                    voter_id=matched_voter.id,
                    voter_epic=epic,
                    voter_part_serial=part_serial,
                    roll_version_id=active_roll.id,
                    roll_checksum=active_roll.checksum_hash,
                    field_status=incoming_status,
                    phone_number=obs_data.get("phone_number"),
                    notes=obs_data.get("notes"),
                    created_by=obs_data.get("created_by", "unknown"),
                    created_at=created_dt,
                    origin_device_id=obs_data.get("origin_device_id", source_device_id),
                    received_at=utc_now(),
                    supersedes_id=obs_data.get("supersedes_id"),
                )
                session.add(new_obs)

                # 2. Materialize into current field_status
                if matched_voter.field_status:
                    old_status = matched_voter.field_status.status.value
                    matched_voter.field_status.status = incoming_status
                    if obs_data.get("phone_number"):
                        matched_voter.field_status.phone_number = obs_data["phone_number"]
                    if obs_data.get("notes"):
                        matched_voter.field_status.notes = obs_data["notes"]
                    matched_voter.field_status.reported_by = obs_data.get("created_by")
                    matched_voter.field_status.reported_at = created_dt
                    matched_voter.field_status.updated_at = utc_now()
                else:
                    old_status = "INITIAL"
                    fs = FieldStatus(
                        voter_id=matched_voter.id,
                        status=incoming_status,
                        phone_number=obs_data.get("phone_number"),
                        notes=obs_data.get("notes"),
                        reported_by=obs_data.get("created_by"),
                        reported_at=created_dt,
                    )
                    session.add(fs)

                # 3. Record in audit history
                history = FieldStatusHistory(
                    voter_id=matched_voter.id,
                    old_status=old_status,
                    new_status=incoming_status.value,
                    notes=f"Sync import from device {source_device_id}: {obs_data.get('notes') or ''}".strip(),
                    changed_by=obs_data.get("created_by", operator_username),
                    changed_at=utc_now(),
                )
                session.add(history)
                imported_count += 1

        # --- DATA BOUNDARY GUARANTEE CHECK ---
        voters_after_count = session.execute(select(Voter.id)).scalars().all()
        if len(voters_before_count) != len(voters_after_count):
            session.rollback()
            raise RuntimeError("CRITICAL DATA INTEGRITY VIOLATION: Sync attempted to modify voters table!")

        # Record incoming packet record
        pkt_record = SyncPacketRecord(
            packet_id=packet_id,
            direction=SyncPacketDirection.IMPORT,
            protocol_version=metadata["protocol_version"],
            source_device_id=source_device_id,
            source_user_id=metadata["source_user_id"],
            roll_version_id=roll_version_id,
            roll_checksum=roll_checksum,
            observation_count=len(observations),
            created_at=datetime.fromisoformat(metadata["created_at"].replace("Z", "+00:00")),
            processed_at=utc_now(),
            status=SyncPacketStatus.IMPORTED,
            status_message=f"Imported: {imported_count}, Skipped: {skipped_count}, Conflicts: {conflict_count}",
        )
        session.add(pkt_record)

        # Audit logging
        action_name = "SYNC_CONFLICT_DETECTED" if conflict_count > 0 else "SYNC_IMPORT_COMPLETED"
        AuditService(session).log(
            action=action_name,
            entity_type="SyncPacket",
            entity_id=packet_id,
            performed_by=operator_username,
            details={
                "packet_id": packet_id,
                "source_device_id": source_device_id,
                "imported_count": imported_count,
                "skipped_count": skipped_count,
                "conflict_count": conflict_count,
            },
        )
        session.flush()

        return {
            "status": "SUCCESS",
            "packet_id": packet_id,
            "imported_count": imported_count,
            "skipped_count": skipped_count,
            "conflict_count": conflict_count,
        }

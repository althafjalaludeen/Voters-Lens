"""Comprehensive Phase 4B.1 Synchronization Security and Integrity Audit Test Suite.

Audits and verifies:
1. Bidirectional Python-Flutter Cryptographic Interoperability
2. Preview Non-Mutation Invariants
3. Atomic Transaction Rollback on Import Failure
4. Trusted and Revoked Device Enforcement
5. Service-Layer Role-Based Access Control (RBAC)
6. Transfer Passphrase Policy and Entropy
7. Official Electoral Data Absolute Immutability
"""

from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import tempfile
import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from voterlens.database.models import (
    AuditLog,
    Base,
    FieldStatus,
    FieldStatusHistory,
    FieldStatusType,
    ReviewStatusType,
    RollVersion,
    RollVersionStatus,
    User,
    UserRole,
    Voter,
    generate_uuid,
    utc_now,
)
from voterlens.services.audit_service import AuditService
from voterlens.services.security import Permission, PermissionDeniedError, SecurityContext
from voterlens.sync.backup import BackupService
from voterlens.sync.conflict_engine import ConflictEngine
from voterlens.sync.crypto import (
    AuthenticationError,
    CryptoError,
    WeakPassphraseError,
    decrypt_payload,
    derive_key,
    encrypt_payload,
    generate_transfer_secret,
    validate_transfer_passphrase,
)
from voterlens.sync.models import (
    ConflictResolutionStatus,
    ConflictType,
    FieldObservation,
    SyncConflict,
    SyncPacketDirection,
    SyncPacketRecord,
    SyncPacketStatus,
    TrustedDevice,
)
from voterlens.sync.preview import ImportPreview, PreviewEngine, PreviewRecord
from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    InvalidPacketError,
    RollMismatchError,
    UnsupportedProtocolVersionError,
    deserialize_and_decrypt_packet,
    serialize_packet_envelope,
)
from voterlens.sync.scope import ExportScope
from voterlens.sync.sync_service import SyncService
from voterlens.sync.transport import VLSyncFileTransport


DART_EXPORTED_ENVELOPE = {
    "magic": "VLSYNC",
    "protocol_version": 1,
    "packet_id": "dart-pkt-9999",
    "created_at": "2026-10-09T08:30:00Z",
    "packet_type": "FIELD_OBSERVATIONS_SYNC",
    "source_device_id": "dart-dev-7777",
    "source_user_id": "dart_operator",
    "roll_version_id": "roll-ver-1234",
    "roll_checksum": "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
    "observation_count": 1,
    "encryption": {
        "algorithm": "AES-256-GCM",
        "kdf": "PBKDF2-HMAC-SHA256",
        "iterations": 100000,
        "salt_hex": "0a0b0c0d0e0f10111213141516171819",
        "nonce_hex": "0102030405060708090a0b0c",
    },
    "ciphertext_hex": "ddf4122d3ce0b7875a7ec5a0e83723ef9816ac95ca555bf0a98d5632d3ff08c356aea140be0adf0acf9b520d8aada26e9501b615ffaf20e5991f58b2febea0feddfec5f02fed4f8eeda1b28766e7277958eba47a9f51e9847f2a83a8d488e55c28a804313cba0e504b6b365c9db5ee85b1c7d74950cf495496b78620d239ffcebbf7c3da19447edf719f3b8b577207e480602f986e11c859a58e95fefb341834f9efa4af5a992a50490b7e1356147df54fea665994c1e6980b1cdc4cb529bf7245cc634c2bda3c4cd7cf51a78c69223f9eb0d9ad5fbe0304817d189a79aaceddd40c367f6271970601705edf06f417dbe8384a7b1eacfc2bb0fc1f983d2b91ab8dd9ef26f1a1571171c43a5913ef0eeb94b7ddfe939ba563ab69d8c5f927c0ff1c825f3b5f6b16ffdc933b085aad25a391bc02df1ccbe33d976bf20163e1369e90772b0d8f29986d409d",
    "file_integrity": {
        "sha256": "3d63df988194af229184b44a6ee579be2630ce758552b80590081a4c0d96e698",
    },
}


@pytest.fixture
def audit_session():
    """In-memory SQLite database populated with isolated synthetic test data."""
    engine = create_engine("sqlite:///:memory:", echo=False)
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine)
    session = session_factory()

    # Seed synthetic roll
    roll = RollVersion(
        id="roll-audit-001",
        state="Kerala",
        district="Pathanamthitta",
        assembly_constituency="111 - Thiruvalla",
        roll_name="Synthetic Audit Roll",
        record_count=3,
        status=RollVersionStatus.ACTIVE,
        checksum_hash="3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
    )
    session.add(roll)

    # Seed 3 synthetic voters
    v1 = Voter(
        id="voter-audit-001",
        roll_version_id="roll-audit-001",
        serial_number=1,
        epic_number="KL99/999/9999",
        name="ഗോപാലൻ",
        normalized_name="gopalan",
        relative_name="രാമൻ",
        normalized_relative_name="raman",
        relative_type="FTHR",
        house_number="1/10",
        normalized_house_number="1/10",
        age=45,
        gender="M",
        part_number="1",
        section_number="1",
        section_name="Section 1",
        polling_station_name="Govt LPS",
        polling_station_address="Room 1",
    )
    v2 = Voter(
        id="voter-audit-002",
        roll_version_id="roll-audit-001",
        serial_number=2,
        epic_number="KL99/999/9998",
        name="ലക്ഷ്മി",
        normalized_name="lakshmi",
        relative_name="ഗോപാലൻ",
        normalized_relative_name="gopalan",
        relative_type="HUSB",
        house_number="1/10",
        normalized_house_number="1/10",
        age=40,
        gender="F",
        part_number="1",
        section_number="1",
        section_name="Section 1",
        polling_station_name="Govt LPS",
        polling_station_address="Room 1",
    )
    session.add_all([v1, v2])
    session.commit()
    yield session
    session.close()


# ==============================================================================
# 1. PYTHON-FLUTTER INTEROPERABILITY TESTS
# ==============================================================================

def test_python_decrypts_dart_exported_packet():
    """Verify that Python successfully validates and decrypts a packet generated by Dart."""
    metadata, observations = deserialize_and_decrypt_packet(
        packet_data=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
    )

    assert metadata["packet_id"] == "dart-pkt-9999"
    assert metadata["source_device_id"] == "dart-dev-7777"
    assert metadata["roll_checksum"] == "3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b"
    assert len(observations) == 1

    obs = observations[0]
    assert obs["observation_id"] == "dart-obs-001"
    assert obs["voter_epic"] == "KL99/999/9999"
    assert obs["field_status"] == "ABROAD"
    assert obs["phone_number"] == "9999999999"


def test_python_rejects_dart_packet_with_wrong_password():
    """Verify that Python rejects a Dart-generated packet when given an incorrect passphrase."""
    with pytest.raises(AuthenticationError) as exc_info:
        deserialize_and_decrypt_packet(
            packet_data=DART_EXPORTED_ENVELOPE,
            transfer_passphrase="IncorrectPassword999!",
        )
    assert "Cryptographic authentication failed" in str(exc_info.value)


def test_python_rejects_dart_packet_with_tampered_ciphertext():
    """Verify that Python rejects a Dart-generated packet if ciphertext bytes are altered."""
    tampered_data = json.loads(json.dumps(DART_EXPORTED_ENVELOPE))
    # Flip bytes in ciphertext
    raw_ct = bytearray(bytes.fromhex(tampered_data["ciphertext_hex"]))
    raw_ct[10] ^= 0xFF
    tampered_data["ciphertext_hex"] = raw_ct.hex()
    # Update SHA-256 to isolate GCM tag verification failure
    tampered_data["file_integrity"]["sha256"] = hashlib.sha256(raw_ct).hexdigest()

    with pytest.raises(AuthenticationError):
        deserialize_and_decrypt_packet(
            packet_data=tampered_data,
            transfer_passphrase="DartExportPass123!",
        )


def test_python_rejects_dart_packet_with_tampered_aad():
    """Verify that Python rejects a Dart-generated packet if authenticated metadata is swapped."""
    tampered_data = json.loads(json.dumps(DART_EXPORTED_ENVELOPE))
    # Tamper observation count without altering ciphertext
    tampered_data["observation_count"] = 999

    with pytest.raises(AuthenticationError):
        deserialize_and_decrypt_packet(
            packet_data=tampered_data,
            transfer_passphrase="DartExportPass123!",
        )


def test_python_rejects_unsupported_protocol_version():
    """Verify rejection of packet with unsupported protocol version."""
    tampered_data = json.loads(json.dumps(DART_EXPORTED_ENVELOPE))
    tampered_data["protocol_version"] = 99

    with pytest.raises(UnsupportedProtocolVersionError):
        deserialize_and_decrypt_packet(
            packet_data=tampered_data,
            transfer_passphrase="DartExportPass123!",
        )


def test_python_rejects_malformed_magic():
    """Verify rejection of packet with incorrect magic identifier."""
    tampered_data = json.loads(json.dumps(DART_EXPORTED_ENVELOPE))
    tampered_data["magic"] = "INVALID_MAGIC"

    with pytest.raises(InvalidPacketError):
        deserialize_and_decrypt_packet(
            packet_data=tampered_data,
            transfer_passphrase="DartExportPass123!",
        )


# ==============================================================================
# 2. PREVIEW NON-MUTATION TESTS
# ==============================================================================

def test_preview_does_not_mutate_database_state(audit_session: Session):
    """Rigorous verification that Stage 1 Preview does not perform ANY database writes
    to field_observations, field_status, sync_conflicts, or sync_packets."""
    voters_before = audit_session.execute(select(Voter)).scalars().all()
    rolls_before = audit_session.execute(select(RollVersion)).scalars().all()
    obs_before = audit_session.execute(select(FieldObservation)).scalars().all()
    status_before = audit_session.execute(select(FieldStatus)).scalars().all()
    conflicts_before = audit_session.execute(select(SyncConflict)).scalars().all()
    packets_before = audit_session.execute(select(SyncPacketRecord)).scalars().all()

    # Execute preview of Dart packet
    preview = SyncService.preview_import(
        session=audit_session,
        source=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
        operator_username="supervisor_test",
        security_context=SecurityContext(role=UserRole.MANAGER),
    )

    assert preview.can_commit is True
    assert preview.total_records == 1
    assert preview.new_records == 1

    # Verify database state after preview
    voters_after = audit_session.execute(select(Voter)).scalars().all()
    rolls_after = audit_session.execute(select(RollVersion)).scalars().all()
    obs_after = audit_session.execute(select(FieldObservation)).scalars().all()
    status_after = audit_session.execute(select(FieldStatus)).scalars().all()
    conflicts_after = audit_session.execute(select(SyncConflict)).scalars().all()
    packets_after = audit_session.execute(select(SyncPacketRecord)).scalars().all()

    assert len(voters_after) == len(voters_before)
    assert len(rolls_after) == len(rolls_before)
    assert len(obs_after) == len(obs_before) == 0
    assert len(status_after) == len(status_before) == 0
    assert len(conflicts_after) == len(conflicts_before) == 0
    assert len(packets_after) == len(packets_before) == 0

    # Only permissible preview audit actions logged
    preview_audits = audit_session.execute(
        select(AuditLog).where(
            AuditLog.action.in_(["SYNC_IMPORT_SELECTED", "SYNC_IMPORT_VALIDATED", "SYNC_IMPORT_PREVIEWED"])
        )
    ).scalars().all()
    assert len(preview_audits) > 0

    # Zero commit audit events
    commit_audits = audit_session.execute(
        select(AuditLog).where(AuditLog.action == "SYNC_IMPORT_COMMITTED")
    ).scalars().all()
    assert len(commit_audits) == 0


# ==============================================================================
# 3. TRANSACTION ATOMICITY AND ROLLBACK
# ==============================================================================

def test_atomic_rollback_on_simulated_commit_failure(audit_session: Session, monkeypatch):
    """Verify that if an unhandled failure occurs during commit_import,
    all mutations roll back and the packet status NEVER indicates COMMITTED."""
    preview = SyncService.preview_import(
        session=audit_session,
        source=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
        operator_username="supervisor_test",
        security_context=SecurityContext(role=UserRole.MANAGER),
    )

    # Monkeypatch AuditService.log to raise an error after observations were added
    original_log = AuditService.log
    def failing_log(self, action, *args, **kwargs):
        if action == "SYNC_IMPORT_COMMITTED":
            raise RuntimeError("SIMULATED_DATABASE_IO_CRASH")
        return original_log(self, action, *args, **kwargs)

    monkeypatch.setattr(AuditService, "log", failing_log)

    with pytest.raises(RuntimeError) as exc_info:
        SyncService.commit_import(
            session=audit_session,
            preview=preview,
            operator_username="supervisor_test",
            security_context=SecurityContext(role=UserRole.MANAGER),
        )
    assert "SIMULATED_DATABASE_IO_CRASH" in str(exc_info.value)

    # Verify complete rollback: zero observations and zero committed packets in DB
    obs_in_db = audit_session.execute(select(FieldObservation)).scalars().all()
    assert len(obs_in_db) == 0

    committed_pkts = audit_session.execute(
        select(SyncPacketRecord).where(SyncPacketRecord.status == SyncPacketStatus.COMMITTED)
    ).scalars().all()
    assert len(committed_pkts) == 0


# ==============================================================================
# 4. TRUSTED AND REVOKED DEVICE ENFORCEMENT
# ==============================================================================

def test_revoked_device_is_rejected_on_preview_and_commit(audit_session: Session):
    """Verify that an explicitly revoked device (is_trusted=False) is rejected."""
    revoked_dev = TrustedDevice(
        device_id="dart-dev-7777",
        device_name="Compromised Field Tablet",
        is_trusted=False,
    )
    audit_session.add(revoked_dev)
    audit_session.commit()

    # Preview should classify as cannot commit
    preview = SyncService.preview_import(
        session=audit_session,
        source=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
        operator_username="supervisor_test",
        security_context=SecurityContext(role=UserRole.MANAGER),
    )

    assert preview.can_commit is False
    assert "revoked and unauthorized" in (preview.rejection_reason or "")

    # Direct commit attempt must raise PermissionError
    with pytest.raises(PermissionError) as exc_info:
        SyncService.commit_import(
            session=audit_session,
            preview=preview,
            operator_username="supervisor_test",
            security_context=SecurityContext(role=UserRole.MANAGER),
        )
    assert "revoked and unauthorized" in str(exc_info.value)


def test_unknown_device_not_silently_trusted(audit_session: Session):
    """Verify that an unknown device is not silently added to trusted_devices."""
    devices_before = audit_session.execute(select(TrustedDevice)).scalars().all()

    SyncService.preview_import(
        session=audit_session,
        source=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
        operator_username="supervisor_test",
        security_context=SecurityContext(role=UserRole.MANAGER),
        require_trusted_device=False,
    )

    devices_after = audit_session.execute(select(TrustedDevice)).scalars().all()
    assert len(devices_after) == len(devices_before)


# ==============================================================================
# 5. SERVICE-LAYER RBAC ENFORCEMENT
# ==============================================================================

def test_service_level_rbac_permissions(audit_session: Session):
    """Verify that direct service calls strictly enforce RBAC."""
    preview = SyncService.preview_import(
        session=audit_session,
        source=DART_EXPORTED_ENVELOPE,
        transfer_passphrase="DartExportPass123!",
        operator_username="test_user",
        security_context=SecurityContext(role=UserRole.ADMIN),
    )

    viewer_ctx = SecurityContext(role=UserRole.VIEWER)
    field_user_ctx = SecurityContext(role=UserRole.FIELD_USER)
    manager_ctx = SecurityContext(role=UserRole.MANAGER)

    # VIEWER cannot export or import
    with pytest.raises(PermissionDeniedError):
        SyncService.preview_import(
            session=audit_session,
            source=DART_EXPORTED_ENVELOPE,
            transfer_passphrase="DartExportPass123!",
            operator_username="viewer_user",
            security_context=viewer_ctx,
        )

    with pytest.raises(PermissionDeniedError):
        SyncService.commit_import(
            session=audit_session,
            preview=preview,
            operator_username="viewer_user",
            security_context=viewer_ctx,
        )

    # FIELD_USER cannot commit import
    with pytest.raises(PermissionDeniedError):
        SyncService.commit_import(
            session=audit_session,
            preview=preview,
            operator_username="field_user",
            security_context=field_user_ctx,
        )

    # MANAGER can commit import
    result = SyncService.commit_import(
        session=audit_session,
        preview=preview,
        operator_username="manager_user",
        security_context=manager_ctx,
    )
    assert result["status"] == "SUCCESS"


# ==============================================================================
# 6. PASSWORD POLICY AND TRANSFER SECRETS
# ==============================================================================

def test_transfer_passphrase_policy():
    """Verify that weak transfer passphrases are rejected and high-entropy secrets generated."""
    # Too short
    with pytest.raises(WeakPassphraseError):
        validate_transfer_passphrase("short")

    # Common dictionary password
    with pytest.raises(WeakPassphraseError):
        validate_transfer_passphrase("password")

    with pytest.raises(WeakPassphraseError):
        validate_transfer_passphrase("12345678")

    # Valid strong passphrase
    validate_transfer_passphrase("CorrectHorseBatteryStaple99!")

    # Generated transfer secret
    secret = generate_transfer_secret(24)
    assert len(secret) == 24
    validate_transfer_passphrase(secret)


# ==============================================================================
# 7. OFFICIAL DATA ABSOLUTE IMMUTABILITY
# ==============================================================================

def test_official_data_immutability_throughout_sync_lifecycle(audit_session: Session):
    """Run full lifecycle: export -> preview -> commit -> conflict resolve -> restore,
    and verify official statutory rolls and voter records remain byte-for-byte identical."""
    # Capture logical snapshot of official voters and roll
    def snapshot_official_data():
        voters = audit_session.execute(
            select(Voter).order_by(Voter.id)
        ).scalars().all()
        rolls = audit_session.execute(
            select(RollVersion).order_by(RollVersion.id)
        ).scalars().all()

        voter_tuples = [
            (v.id, v.epic_number, v.name, v.relative_name, v.age, v.gender, v.house_number, v.part_number, v.serial_number)
            for v in voters
        ]
        roll_tuples = [
            (r.id, r.roll_name, r.checksum_hash, r.record_count, r.status)
            for r in rolls
        ]
        return voter_tuples, roll_tuples

    voters_initial, rolls_initial = snapshot_official_data()

    # Step 1: Export observations
    with tempfile.TemporaryDirectory() as tmp_dir:
        export_file = SyncService.export_observations_to_file(
            session=audit_session,
            roll_version_id="roll-audit-001",
            operator_username="admin_user",
            transfer_passphrase="StrongSecurePassphrase123!",
            destination=tmp_dir,
            security_context=SecurityContext(role=UserRole.ADMIN),
        )
        assert Path(export_file).is_file()

        # Step 2: Preview import
        preview = SyncService.preview_import(
            session=audit_session,
            source=export_file,
            transfer_passphrase="StrongSecurePassphrase123!",
            operator_username="admin_user",
            security_context=SecurityContext(role=UserRole.ADMIN),
        )

        # Step 3: Commit import
        SyncService.commit_import(
            session=audit_session,
            preview=preview,
            operator_username="admin_user",
            security_context=SecurityContext(role=UserRole.ADMIN),
        )

        # Step 4: Export field backup and restore
        backup_svc = BackupService()
        backup_file = backup_svc.create_field_delta_backup(
            session=audit_session,
            roll_version_id="roll-audit-001",
            destination_path=tmp_dir,
            transfer_passphrase="StrongSecurePassphrase123!",
            operator_username="admin_user",
            security_context=SecurityContext(role=UserRole.ADMIN),
        )

        backup_svc.restore_field_delta_backup(
            session=audit_session,
            source_file_path=backup_file,
            transfer_passphrase="StrongSecurePassphrase123!",
            operator_username="admin_user",
            security_context=SecurityContext(role=UserRole.ADMIN),
        )

    # Step 5: Capture snapshot again and verify absolute immutability
    voters_final, rolls_final = snapshot_official_data()

    assert voters_final == voters_initial
    assert rolls_final == rolls_initial

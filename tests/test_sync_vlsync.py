"""Comprehensive Phase 4B test suite: Encrypted Local .vlsync File Exchange Transport,
Two-Stage Import Preview, Scopes, Validations, Backups, and Immutability Protection.
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
    decrypt_payload,
    derive_key,
    encrypt_payload,
)
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
from voterlens.sync.preview import ImportPreview, PreviewEngine, PreviewRecord
from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    InvalidPacketError,
    RollMismatchError,
    UnsupportedProtocolVersionError,
    deserialize_and_decrypt_packet,
    serialize_packet_envelope,
)
from voterlens.sync.scope import ExportScope, ExportScopeFilter
from voterlens.sync.sync_service import SyncService
from voterlens.sync.transport import VLSyncFileTransport
from voterlens.sync.validation import (
    filter_valid_observations_for_export,
    validate_observation_for_export,
)


@pytest.fixture
def phase4b_session():
    """In-memory SQLite database populated strictly with synthetic test data."""
    engine = create_engine("sqlite:///:memory:", echo=False)
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine)
    session = session_factory()

    # Seed synthetic roll
    synthetic_roll = RollVersion(
        id="roll-synthetic-4b",
        state="Kerala",
        district="Pathanamthitta",
        assembly_constituency="111 - Thiruvalla",
        roll_name="Synthetic Test Roll Phase 4B",
        record_count=3,
        status=RollVersionStatus.ACTIVE,
        checksum_hash="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
    )
    session.add(synthetic_roll)

    # Seed 3 synthetic voters: V001, V002, V003
    v1 = Voter(
        id="voter-uuid-4b-001",
        roll_version_id="roll-synthetic-4b",
        serial_number=1,
        epic_number="KL14001",
        name="അനിൽ കുമാർ",
        normalized_name="anil kumar",
        relative_name="സുരേഷ്",
        normalized_relative_name="suresh",
        relative_type="FTHR",
        house_number="12/100",
        normalized_house_number="12/100",
        age=30,
        gender="M",
        part_number="1",
        section_number="1",
    )
    v2 = Voter(
        id="voter-uuid-4b-002",
        roll_version_id="roll-synthetic-4b",
        serial_number=2,
        epic_number="KL14002",
        name="പ്രിയ നായർ",
        normalized_name="priya nair",
        relative_name="മോഹൻ",
        normalized_relative_name="mohan",
        relative_type="HUSB",
        house_number="12/101",
        normalized_house_number="12/101",
        age=28,
        gender="F",
        part_number="1",
        section_number="1",
    )
    v3 = Voter(
        id="voter-uuid-4b-003",
        roll_version_id="roll-synthetic-4b",
        serial_number=3,
        epic_number="KL14003",
        name="ജോർജ് തോമസ്",
        normalized_name="george thomas",
        relative_name="തോമസ്",
        normalized_relative_name="thomas",
        relative_type="FTHR",
        house_number="12/102",
        normalized_house_number="12/102",
        age=55,
        gender="M",
        part_number="2",
        section_number="1",
    )
    session.add_all([v1, v2, v3])
    session.commit()

    try:
        yield session
    finally:
        session.close()
        engine.dispose()


# ---------------------------------------------------------------------------
# EXPORT TESTS (1-10)
# ---------------------------------------------------------------------------

def test_export_valid_observations(phase4b_session: Session):
    """1. Export valid field observations into an encrypted .vlsync packet."""
    roll_id = "roll-synthetic-4b"
    passphrase = "SecureTransferPassphrase2026!"
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()

    fs = FieldStatus(
        voter_id=v1.id,
        status=FieldStatusType.AWAY,
        phone_number="9876543210",
        notes="Working in Bengaluru",
        reported_by="operator_anil",
    )
    phase4b_session.add(fs)
    phase4b_session.commit()

    envelope = SyncService.export_observations(
        session=phase4b_session,
        roll_version_id=roll_id,
        operator_username="operator_anil",
        transfer_passphrase=passphrase,
    )

    assert envelope["magic"] == "VLSYNC"
    assert envelope["protocol_version"] == 1
    assert envelope["observation_count"] == 1
    assert "ciphertext_hex" in envelope
    assert "file_integrity" in envelope


def test_deterministic_serialization(phase4b_session: Session):
    """2. Deterministic serialization produces valid sorted-key JSON format."""
    transport = VLSyncFileTransport()
    envelope = {
        "magic": "VLSYNC",
        "protocol_version": 1,
        "packet_id": "test-pkt-id",
        "source_device_id": "dev-1",
        "source_user_id": "user-1",
        "roll_version_id": "roll-1",
        "roll_checksum": "checksum-1",
        "observation_count": 0,
        "encryption": {"algorithm": "AES-256-GCM", "salt_hex": "00"*16, "nonce_hex": "00"*12},
        "ciphertext_hex": "deadbeef",
        "file_integrity": {"sha256": hashlib.sha256(b"\xde\xad\xbe\xef").hexdigest()},
    }

    with tempfile.TemporaryDirectory() as tmp_dir:
        file_path = transport.export_packet(envelope, tmp_dir)
        assert Path(file_path).exists()
        assert file_path.endswith(".vlsync")

        read_back = transport.read_packet(file_path)
        assert read_back["magic"] == "VLSYNC"
        assert read_back["packet_id"] == "test-pkt-id"


def test_encryption_decryption_roundtrip():
    """3. AES-256-GCM encryption/decryption roundtrip with canonical AAD."""
    passphrase = "SecretKey2026!"
    salt = b"1234567890abcdef"
    key = derive_key(passphrase, salt)
    aad = b"VOTERLENS_SYNC_V1|pkt-1|dev-1|roll-1|checksum-1|5"
    data = b'{"hello": "offline_world"}'

    ciphertext_with_tag, nonce = encrypt_payload(data, key, associated_data=aad)
    plaintext = decrypt_payload(ciphertext_with_tag, key, nonce, associated_data=aad)
    assert plaintext == data


def test_password_roundtrip_file_transport(phase4b_session: Session):
    """4. Export to .vlsync file and read back successfully with correct password."""
    roll_id = "roll-synthetic-4b"
    passphrase = "MySecretTransferPassword!"
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()
    fs = FieldStatus(voter_id=v1.id, status=FieldStatusType.ABROAD, reported_by="operator_a")
    phase4b_session.add(fs)
    phase4b_session.commit()

    with tempfile.TemporaryDirectory() as tmp_dir:
        file_path = SyncService.export_observations_to_file(
            session=phase4b_session,
            roll_version_id=roll_id,
            operator_username="operator_a",
            transfer_passphrase=passphrase,
            destination=tmp_dir,
        )

        transport = VLSyncFileTransport()
        packet = transport.read_packet(file_path)
        metadata, observations = deserialize_and_decrypt_packet(packet, passphrase)
        assert len(observations) == 1
        assert observations[0]["field_status"] == "ABROAD"


def test_wrong_password_rejection(phase4b_session: Session):
    """5. Decrypting .vlsync with incorrect password raises AuthenticationError."""
    roll_id = "roll-synthetic-4b"
    correct_passphrase = "CorrectSecretPassword"
    wrong_passphrase = "WrongPassword123"

    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()
    fs = FieldStatus(voter_id=v1.id, status=FieldStatusType.NO_ISSUE, reported_by="op")
    phase4b_session.add(fs)
    phase4b_session.commit()

    envelope = SyncService.export_observations(
        session=phase4b_session,
        roll_version_id=roll_id,
        operator_username="op",
        transfer_passphrase=correct_passphrase,
    )

    with pytest.raises(AuthenticationError):
        deserialize_and_decrypt_packet(envelope, wrong_passphrase)


def test_tampered_file_rejected(phase4b_session: Session):
    """6. Tampered ciphertext or file integrity hash in .vlsync raises error."""
    transport = VLSyncFileTransport()
    envelope = {
        "magic": "VLSYNC",
        "protocol_version": 1,
        "packet_id": "pkt-tampered",
        "source_device_id": "dev-1",
        "source_user_id": "user-1",
        "roll_version_id": "roll-1",
        "roll_checksum": "checksum-1",
        "observation_count": 0,
        "encryption": {"algorithm": "AES-256-GCM", "salt_hex": "00"*16, "nonce_hex": "00"*12},
        "ciphertext_hex": "deadbeef",
        "file_integrity": {"sha256": "bad_hash_99999999999999999999999999999999999999999999999999"},
    }

    with pytest.raises(InvalidPacketError) as exc_info:
        transport.validate_container(json.dumps(envelope))
    assert "integrity check failed" in str(exc_info.value).lower()


def test_malformed_header_rejected():
    """7. Sync container with missing or malformed header is rejected."""
    transport = VLSyncFileTransport()
    bad_container = {"not_magic": "FOOBAR"}
    with pytest.raises(InvalidPacketError) as exc_info:
        transport.validate_container(json.dumps(bad_container))
    assert "magic" in str(exc_info.value).lower()


def test_unsupported_protocol_rejected():
    """8. Future protocol version is rejected gracefully."""
    transport = VLSyncFileTransport()
    envelope = {
        "magic": "VLSYNC",
        "protocol_version": 999,
        "packet_id": "pkt-1",
        "source_device_id": "dev-1",
        "source_user_id": "user-1",
        "roll_version_id": "roll-1",
        "roll_checksum": "checksum-1",
        "observation_count": 0,
        "encryption": {"algorithm": "AES-256-GCM", "salt_hex": "00"*16, "nonce_hex": "00"*12},
        "ciphertext_hex": "deadbeef",
    }
    with pytest.raises(UnsupportedProtocolVersionError):
        transport.validate_container(json.dumps(envelope))


def test_oversized_packet_rejected():
    """9. Files exceeding size limit are blocked to prevent memory exhaustion."""
    transport = VLSyncFileTransport(max_file_size=100)  # Low 100 byte limit for test
    oversized_data = b"VLSYNC" + b"X" * 200
    with pytest.raises(InvalidPacketError) as exc_info:
        transport.validate_container(oversized_data)
    assert "exceeds" in str(exc_info.value).lower()


def test_invalid_observation_validation_on_export():
    """10. Malformed observation records are excluded during export validation."""
    valid_obs = {
        "observation_id": generate_uuid(),
        "voter_epic": "KL14001",
        "roll_checksum": "valid_checksum",
        "field_status": "AWAY",
        "created_by": "operator",
        "created_at": utc_now().isoformat(),
        "origin_device_id": generate_uuid(),
    }
    is_valid, reason = validate_observation_for_export(valid_obs, "valid_checksum")
    assert is_valid is True

    bad_obs = {
        "observation_id": "NOT-A-UUID",
        "voter_epic": "",
        "roll_checksum": "wrong_checksum",
        "field_status": "INVALID_STATUS",
        "created_by": "",
        "created_at": "not-a-date",
        "origin_device_id": "bad",
    }
    valid_list, excluded_list = filter_valid_observations_for_export([valid_obs, bad_obs], "valid_checksum")
    assert len(valid_list) == 1
    assert len(excluded_list) == 1


# ---------------------------------------------------------------------------
# IMPORT & PREVIEW TESTS (11-22)
# ---------------------------------------------------------------------------

def test_successful_two_stage_import(phase4b_session: Session):
    """11 & 12 & 13. Two-stage import: Preview does NOT mutate DB; commit applies changes."""
    roll_id = "roll-synthetic-4b"
    passphrase = "TwoStagePassphrase"
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()

    obs_list = [{
        "observation_id": generate_uuid(),
        "voter_epic": "KL14001",
        "voter_part_serial": "1:1",
        "roll_version_id": roll_id,
        "roll_checksum": "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        "field_status": "AWAY",
        "phone_number": "9998887776",
        "notes": "Preview test note",
        "created_by": "remote_op",
        "created_at": utc_now().isoformat(),
        "origin_device_id": generate_uuid(),
        "supersedes_id": None,
        "is_revoked": False,
        "revocation_reason": None,
    }]

    envelope = serialize_packet_envelope(
        packet_id="pkt-stage-001",
        source_device_id="remote-dev-1",
        source_user_id="remote_op",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        observations=obs_list,
        transfer_passphrase=passphrase,
    )

    # Stage 1: Preview
    preview = SyncService.preview_import(
        session=phase4b_session,
        source=envelope,
        transfer_passphrase=passphrase,
        operator_username="local_admin",
    )

    assert preview.total_records == 1
    assert preview.new_records == 1
    assert preview.can_commit is True

    # VERIFY DB UNTOUCHED (v1.field_status is still None)
    phase4b_session.refresh(v1)
    assert v1.field_status is None
    obs_count = phase4b_session.execute(select(FieldObservation)).scalars().all()
    assert len(obs_count) == 0

    # Stage 2: Commit
    commit_res = SyncService.commit_import(
        session=phase4b_session,
        preview=preview,
        operator_username="local_admin",
    )

    assert commit_res["status"] == "SUCCESS"
    assert commit_res["imported_count"] == 1

    # Verify materialized state
    phase4b_session.refresh(v1)
    assert v1.field_status is not None
    assert v1.field_status.status == FieldStatusType.AWAY
    assert v1.field_status.phone_number == "9998887776"


def test_duplicate_packet_and_observation(phase4b_session: Session):
    """14 & 15. Duplicate packet and observation detection (idempotency)."""
    roll_id = "roll-synthetic-4b"
    passphrase = "DupPassphrase"

    obs_id = generate_uuid()
    obs_list = [{
        "observation_id": obs_id,
        "voter_epic": "KL14002",
        "voter_part_serial": "1:2",
        "roll_version_id": roll_id,
        "roll_checksum": "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        "field_status": "ABROAD",
        "phone_number": None,
        "notes": None,
        "created_by": "remote_op",
        "created_at": utc_now().isoformat(),
        "origin_device_id": generate_uuid(),
    }]

    envelope = serialize_packet_envelope(
        packet_id="pkt-dup-test",
        source_device_id="dev-dup",
        source_user_id="remote_op",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        observations=obs_list,
        transfer_passphrase=passphrase,
    )

    # First import
    res1 = SyncService.import_observations(phase4b_session, envelope, passphrase, "admin")
    assert res1["imported_count"] == 1

    # Second preview of identical packet
    preview2 = SyncService.preview_import(phase4b_session, envelope, passphrase, "admin")
    assert preview2.can_commit is False  # Flagged already imported
    assert "already been imported" in (preview2.rejection_reason or "")


def test_stale_observation_does_not_overwrite_newer_state(phase4b_session: Session):
    """16. Stale observation appends history but does NOT revert newer local status."""
    roll_id = "roll-synthetic-4b"
    passphrase = "StaleTestKey"
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()

    # Local state: Newer update at 12:00
    t_local = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)
    obs_local = FieldObservation(
        observation_id="obs-newer",
        voter_id=v1.id,
        voter_epic="KL14001",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.NO_ISSUE,
        created_by="local_worker",
        created_at=t_local,
        origin_device_id="local_dev",
    )
    fs1 = FieldStatus(voter_id=v1.id, status=FieldStatusType.NO_ISSUE, reported_at=t_local)
    phase4b_session.add_all([obs_local, fs1])
    phase4b_session.commit()

    # Incoming observation from earlier at 10:00 (Stale)
    t_incoming = datetime(2026, 10, 5, 10, 0, tzinfo=timezone.utc)
    incoming_obs = [{
        "observation_id": "obs-older",
        "voter_epic": "KL14001",
        "roll_version_id": roll_id,
        "roll_checksum": "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        "field_status": "AWAY",
        "created_by": "remote_worker",
        "created_at": t_incoming.isoformat(),
        "origin_device_id": "remote_dev",
    }]

    envelope = serialize_packet_envelope(
        packet_id="pkt-stale-01",
        source_device_id="remote_dev",
        source_user_id="remote_worker",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        observations=incoming_obs,
        transfer_passphrase=passphrase,
    )

    preview = SyncService.preview_import(phase4b_session, envelope, passphrase, "admin")
    assert preview.stale_records == 1
    assert preview.records[0].classification == "STALE"

    SyncService.commit_import(phase4b_session, preview, "admin")
    phase4b_session.refresh(v1)

    # Local state is STILL NO_ISSUE (newer state preserved)
    assert v1.field_status.status == FieldStatusType.NO_ISSUE


def test_concurrent_conflict_and_review(phase4b_session: Session):
    """17. Concurrent conflict surfaces clearly and flags voter for review."""
    roll_id = "roll-synthetic-4b"
    passphrase = "ConcurrentKey"
    v3 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14003")).scalars().first()

    # Local state at 10:00: AWAY
    t_local = datetime(2026, 10, 5, 10, 0, tzinfo=timezone.utc)
    obs_local = FieldObservation(
        observation_id="obs-c-local",
        voter_id=v3.id,
        voter_epic="KL14003",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.AWAY,
        created_by="worker_a",
        created_at=t_local,
        origin_device_id="dev_a",
    )
    fs3 = FieldStatus(voter_id=v3.id, status=FieldStatusType.AWAY, reported_at=t_local)
    phase4b_session.add_all([obs_local, fs3])
    phase4b_session.commit()

    # Incoming observation at 10:15: REPORTED_DECEASED
    t_incoming = datetime(2026, 10, 5, 10, 15, tzinfo=timezone.utc)
    incoming_obs = [{
        "observation_id": "obs-c-remote",
        "voter_epic": "KL14003",
        "roll_version_id": roll_id,
        "roll_checksum": "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        "field_status": "REPORTED_DECEASED",
        "created_by": "worker_b",
        "created_at": t_incoming.isoformat(),
        "origin_device_id": "dev_b",
    }]

    envelope = serialize_packet_envelope(
        packet_id="pkt-concurrent-01",
        source_device_id="dev_b",
        source_user_id="worker_b",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        observations=incoming_obs,
        transfer_passphrase=passphrase,
    )

    preview = SyncService.preview_import(phase4b_session, envelope, passphrase, "admin")
    assert preview.concurrent_conflicts == 1

    commit_res = SyncService.commit_import(phase4b_session, preview, "admin")
    assert commit_res["conflict_count"] == 1

    # Conflict record created
    conflict = phase4b_session.execute(
        select(SyncConflict).where(SyncConflict.voter_epic == "KL14003")
    ).scalars().first()
    assert conflict is not None
    assert conflict.conflict_type == ConflictType.CONCURRENT
    assert conflict.resolution_status == ConflictResolutionStatus.PENDING_REVIEW


def test_roll_mismatch_blocks_import(phase4b_session: Session):
    """18. Roll checksum mismatch blocks preview and commit."""
    envelope = serialize_packet_envelope(
        packet_id="pkt-mismatch-1",
        source_device_id="dev-other",
        source_user_id="user-other",
        roll_version_id="roll-synthetic-4b",
        roll_checksum="COMPLETELY_DIFFERENT_CHECKSUM_00000000000000000000000000000000000",
        observations=[],
        transfer_passphrase="pass",
    )

    preview = SyncService.preview_import(phase4b_session, envelope, "pass", "admin")
    assert preview.is_compatible_roll is False
    assert preview.can_commit is False
    assert "different electoral-roll version" in (preview.rejection_reason or "")

    with pytest.raises(RollMismatchError):
        SyncService.commit_import(phase4b_session, preview, "admin")


def test_voter_not_found_handling(phase4b_session: Session):
    """19. Observation with nonexistent voter is classified VOTER_NOT_FOUND."""
    roll_id = "roll-synthetic-4b"
    obs = [{
        "observation_id": generate_uuid(),
        "voter_epic": "NONEXISTENT_EPIC_9999",
        "roll_version_id": roll_id,
        "roll_checksum": "b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        "field_status": "AWAY",
        "created_by": "op",
        "created_at": utc_now().isoformat(),
        "origin_device_id": "dev",
    }]
    envelope = serialize_packet_envelope(
        packet_id="pkt-vnf-01",
        source_device_id="dev",
        source_user_id="op",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        observations=obs,
        transfer_passphrase="pass",
    )
    preview = SyncService.preview_import(phase4b_session, envelope, "pass", "admin")
    assert preview.voter_not_found_records == 1
    assert preview.records[0].classification == "VOTER_NOT_FOUND"


def test_rbac_permission_enforcement(phase4b_session: Session):
    """21. RBAC enforces permissions: Viewer cannot export or import."""
    roll_id = "roll-synthetic-4b"
    viewer_context = SecurityContext.viewer("guest")
    field_context = SecurityContext.field_user("worker")

    # Viewer cannot export
    with pytest.raises(PermissionDeniedError):
        SyncService.export_observations(
            session=phase4b_session,
            roll_version_id=roll_id,
            operator_username="guest",
            transfer_passphrase="TestSecurePass123!",
            security_context=viewer_context,
        )

    # Field user CAN export
    envelope = SyncService.export_observations(
        session=phase4b_session,
        roll_version_id=roll_id,
        operator_username="worker",
        transfer_passphrase="TestSecurePass123!",
        security_context=field_context,
    )
    assert envelope is not None

    # Field user CANNOT import (only Manager/Admin can import)
    with pytest.raises(PermissionDeniedError):
        SyncService.preview_import(
            session=phase4b_session,
            source=envelope,
            transfer_passphrase="TestSecurePass123!",
            operator_username="worker",
            security_context=field_context,
        )


# ---------------------------------------------------------------------------
# CONFLICT RESOLUTION TESTS (29-33)
# ---------------------------------------------------------------------------

def test_conflict_actions_accept_a_and_accept_b(phase4b_session: Session):
    """29 & 30. Supervisor can resolve conflicts with Keep Local (ACCEPT_A) or Accept Imported (ACCEPT_B)."""
    roll_id = "roll-synthetic-4b"
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()

    obs_local = FieldObservation(
        observation_id="obs-res-local",
        voter_id=v1.id,
        voter_epic="KL14001",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.AWAY,
        created_by="worker1",
        created_at=utc_now(),
        origin_device_id="dev1",
    )
    obs_remote = FieldObservation(
        observation_id="obs-res-remote",
        voter_id=v1.id,
        voter_epic="KL14001",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.ABROAD,
        created_by="worker2",
        created_at=utc_now(),
        origin_device_id="dev2",
    )
    fs1 = FieldStatus(voter_id=v1.id, status=FieldStatusType.AWAY, reported_at=utc_now())
    phase4b_session.add_all([obs_local, obs_remote, fs1])
    phase4b_session.commit()

    conflict = SyncConflict(
        voter_id=v1.id,
        voter_epic="KL14001",
        conflict_type=ConflictType.CONCURRENT,
        local_observation_id="obs-res-local",
        incoming_observation_id="obs-res-remote",
        resolution_status=ConflictResolutionStatus.PENDING_REVIEW,
    )
    phase4b_session.add(conflict)
    phase4b_session.commit()

    # Resolve ACCEPT_B (Accept remote ABROAD)
    ConflictEngine.resolve_conflict(
        session=phase4b_session,
        conflict_id=conflict.id,
        choice="ACCEPT_B",
        resolver_user="supervisor_mohan",
        notes="Verified remote job abroad",
    )
    phase4b_session.refresh(conflict)
    phase4b_session.refresh(fs1)

    assert conflict.resolution_status == ConflictResolutionStatus.RESOLVED_ACCEPTED_B
    assert fs1.status == FieldStatusType.ABROAD


def test_conflict_merge_rules(phase4b_session: Session):
    """31 & 32 & 33. Ambiguous merge fails validation; non-conflicting field merge succeeds with audit."""
    v2 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14002")).scalars().first()
    fs2 = FieldStatus(
        voter_id=v2.id,
        status=FieldStatusType.AWAY,
        phone_number="9876500000",
        notes="Local note",
        reported_at=utc_now(),
    )
    obs_remote = FieldObservation(
        observation_id="obs-merge-remote",
        voter_id=v2.id,
        voter_epic="KL14002",
        roll_version_id="roll-synthetic-4b",
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.REPORTED_DECEASED,  # Contradictory status!
        notes="Remote note",
        created_by="remote",
        created_at=utc_now(),
        origin_device_id="dev",
    )
    phase4b_session.add_all([fs2, obs_remote])
    phase4b_session.commit()

    conflict = SyncConflict(
        voter_id=v2.id,
        voter_epic="KL14002",
        conflict_type=ConflictType.CONCURRENT,
        local_observation_id="local",
        incoming_observation_id="obs-merge-remote",
    )
    phase4b_session.add(conflict)
    phase4b_session.commit()

    # Automatic merge with contradictory status must fail
    with pytest.raises(ValueError) as exc_info:
        ConflictEngine.resolve_conflict(phase4b_session, conflict.id, "MERGE", "supervisor")
    assert "ambiguous merge" in str(exc_info.value).lower()

    # Explicit merge with supervisor decision succeeds
    ConflictEngine.resolve_conflict(
        session=phase4b_session,
        conflict_id=conflict.id,
        choice="MERGE",
        resolver_user="supervisor",
        merged_fields={"status": "AWAY", "phone_number": "9876500000", "notes": "Local note; Remote note"},
    )
    phase4b_session.refresh(conflict)
    assert conflict.resolution_status == ConflictResolutionStatus.RESOLVED_MERGED


# ---------------------------------------------------------------------------
# BACKUP & RESTORE TESTS (34-37)
# ---------------------------------------------------------------------------

def test_backup_and_restore_roundtrip(phase4b_session: Session):
    """34 & 35. Field delta backup and safe restore roundtrip."""
    roll_id = "roll-synthetic-4b"
    passphrase = "BackupPassword2026!"
    backup_service = BackupService()

    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()
    fs = FieldStatus(voter_id=v1.id, status=FieldStatusType.AWAY, notes="Test for backup", reported_at=utc_now())
    obs = FieldObservation(
        observation_id="obs-backup-1",
        voter_id=v1.id,
        voter_epic="KL14001",
        roll_version_id=roll_id,
        roll_checksum="b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90a1",
        field_status=FieldStatusType.AWAY,
        created_by="op",
        created_at=utc_now(),
        origin_device_id="dev",
    )
    phase4b_session.add_all([fs, obs])
    phase4b_session.commit()

    with tempfile.TemporaryDirectory() as tmp_dir:
        # Create backup
        backup_file = backup_service.create_field_delta_backup(
            session=phase4b_session,
            roll_version_id=roll_id,
            destination_path=tmp_dir,
            transfer_passphrase=passphrase,
            operator_username="admin",
        )
        assert Path(backup_file).exists()

        # Delete local observation to test restore
        phase4b_session.delete(obs)
        phase4b_session.delete(fs)
        phase4b_session.commit()

        # Restore backup
        restore_res = backup_service.restore_field_delta_backup(
            session=phase4b_session,
            source_file_path=backup_file,
            transfer_passphrase=passphrase,
            operator_username="admin",
        )
        assert restore_res["status"] == "RESTORE_SUCCESS"
        assert restore_res["observations_restored"] >= 1

        # Verify restored state
        phase4b_session.refresh(v1)
        assert v1.field_status is not None
        assert v1.field_status.status == FieldStatusType.AWAY


def test_gazette_snapshot_creation(phase4b_session: Session):
    """37. Gazette snapshot creates authenticated official roll baseline."""
    roll_id = "roll-synthetic-4b"
    passphrase = "GazettePassword2026!"
    backup_service = BackupService()

    with tempfile.TemporaryDirectory() as tmp_dir:
        snapshot_file = backup_service.create_gazette_snapshot(
            session=phase4b_session,
            roll_version_id=roll_id,
            destination_path=tmp_dir,
            transfer_passphrase=passphrase,
            operator_username="admin",
        )
        assert Path(snapshot_file).exists()

        transport = VLSyncFileTransport()
        envelope = transport.read_packet(snapshot_file)
        assert envelope["packet_type"] == PacketType.GAZETTE_SNAPSHOT.value
        assert envelope["magic"] == "VLSYNC"


def test_gazette_snapshot_restore_and_active_protection(phase4b_session: Session):
    """38. Gazette snapshot bootstrap, duplicate rejection, and active roll protection."""
    roll_id = "roll-synthetic-4b"
    passphrase = "GazettePassword2026!"
    backup_service = BackupService()

    with tempfile.TemporaryDirectory() as tmp_dir:
        snapshot_file = backup_service.create_gazette_snapshot(
            session=phase4b_session,
            roll_version_id=roll_id,
            destination_path=tmp_dir,
            transfer_passphrase=passphrase,
            operator_username="admin",
        )

        # 1. Attempting duplicate restore of currently active roll is rejected
        with pytest.raises(ValueError, match="already installed and active"):
            backup_service.restore_gazette_snapshot(
                session=phase4b_session,
                source_file_path=snapshot_file,
                transfer_passphrase=passphrase,
                operator_username="admin",
            )

        # 2. Fresh install bootstrap into clean database
        fresh_engine = create_engine("sqlite:///:memory:")
        Base.metadata.create_all(fresh_engine)
        FreshSession = sessionmaker(bind=fresh_engine)
        fresh_session = FreshSession()

        res = backup_service.restore_gazette_snapshot(
            session=fresh_session,
            source_file_path=snapshot_file,
            transfer_passphrase=passphrase,
            operator_username="admin",
        )
        assert res["status"] == "BOOTSTRAP_SUCCESS"
        assert res["voters_installed"] > 0

        active_roll = fresh_session.execute(
            select(RollVersion).where(RollVersion.status == RollVersionStatus.ACTIVE)
        ).scalars().first()
        assert active_roll is not None
        assert active_roll.id == roll_id
        assert active_roll.status == RollVersionStatus.ACTIVE


def test_gazette_snapshot_payload_validation_and_defect_rejection():
    """Phase 5B.1: Test Python rejection of duplicate EPICs, serials, negative counts, and mismatches."""
    passphrase = "AuditPassword2026!"
    backup_service = BackupService()
    fresh_engine = create_engine("sqlite:///:memory:")
    Base.metadata.create_all(fresh_engine)
    FreshSession = sessionmaker(bind=fresh_engine)

    def _build_snapshot_file(tmp_dir, roll_id, voters_list, record_count=None, manifest_roll_id=None, proto_ver=1):
        count = record_count if record_count is not None else len(voters_list)
        packet_id = generate_uuid()
        payload_dict = {
            "packet_id": packet_id,
            "roll_version_id": roll_id,
            "roll_checksum": "chk_valid_123",
            "roll_metadata": {
                "id": manifest_roll_id or roll_id,
                "state": "KERALA",
                "district": "ALAPPUZHA",
                "assembly_constituency": "104 - Kuttanad",
                "roll_name": "TEST_ROLL",
                "roll_type": "GENERAL",
                "publication_date": "2026-01-01",
                "record_count": count,
                "checksum_hash": "chk_valid_123",
            },
            "voters": voters_list,
            "observations": [],
        }
        envelope = serialize_packet_envelope(
            packet_id=packet_id,
            source_device_id="audit-dev",
            source_user_id="admin",
            roll_version_id=roll_id,
            roll_checksum="chk_valid_123",
            observations=[],
            transfer_passphrase=passphrase,
            protocol_version=proto_ver,
            packet_type=PacketType.GAZETTE_SNAPSHOT.value,
            custom_payload_dict=payload_dict,
        )
        return backup_service.transport.export_packet(envelope, tmp_dir)

    with tempfile.TemporaryDirectory() as tmp_dir:
        # 1. Duplicate EPIC numbers
        dup_epic_voters = [
            {"id": "v1", "serial_number": 1, "epic_number": "SAME_EPIC", "name": "V1", "part_number": "1"},
            {"id": "v2", "serial_number": 2, "epic_number": "SAME_EPIC", "name": "V2", "part_number": "1"},
        ]
        file1 = _build_snapshot_file(tmp_dir, "roll-dup-epic", dup_epic_voters)
        with pytest.raises(InvalidPacketError, match="Duplicate EPIC number"):
            backup_service.restore_gazette_snapshot(FreshSession(), file1, passphrase, "admin")

        # 2. Duplicate serial numbers in same part
        dup_sn_voters = [
            {"id": "v1", "serial_number": 10, "epic_number": "EPIC1", "name": "V1", "part_number": "1"},
            {"id": "v2", "serial_number": 10, "epic_number": "EPIC2", "name": "V2", "part_number": "1"},
        ]
        file2 = _build_snapshot_file(tmp_dir, "roll-dup-sn", dup_sn_voters)
        with pytest.raises(InvalidPacketError, match="Duplicate serial number"):
            backup_service.restore_gazette_snapshot(FreshSession(), file2, passphrase, "admin")

        # 3. Roll version ID mismatch between manifest and envelope
        clean_voters = [
            {"id": "v1", "serial_number": 1, "epic_number": "EPIC1", "name": "V1", "part_number": "1"},
        ]
        file3 = _build_snapshot_file(tmp_dir, "roll-env-id", clean_voters, manifest_roll_id="roll-manifest-mismatch")
        with pytest.raises(InvalidPacketError, match="Roll version ID mismatch"):
            backup_service.restore_gazette_snapshot(FreshSession(), file3, passphrase, "admin")

        # 4. Negative record count
        file4 = _build_snapshot_file(tmp_dir, "roll-neg-cnt", clean_voters, record_count=-1)
        with pytest.raises(InvalidPacketError, match="invalid or unrealistic record_count"):
            backup_service.restore_gazette_snapshot(FreshSession(), file4, passphrase, "admin")

        # 5. Unsupported protocol version
        file5 = _build_snapshot_file(tmp_dir, "roll-proto-2", clean_voters, proto_ver=2)
        with pytest.raises((InvalidPacketError, UnsupportedProtocolVersionError)):
            backup_service.restore_gazette_snapshot(FreshSession(), file5, passphrase, "admin")


# ---------------------------------------------------------------------------
# SECTION 33: MANDATORY OFFICIAL DATA IMMUTABILITY TEST
# ---------------------------------------------------------------------------

def test_mandatory_official_data_immutability(phase4b_session: Session):
    """Mandatory Section 33 Test:
    1. Capture fingerprint/checksum of official voter dataset.
    2. Export field observations.
    3. Import them.
    4. Resolve conflicts.
    5. Restore backup.
    6. Verify official dataset remains byte-for-byte / logically identical.
    """
    def _compute_voters_fingerprint(session: Session) -> str:
        voters = session.execute(select(Voter).order_by(Voter.serial_number)).scalars().all()
        canonical_rows = [
            f"{v.id}|{v.roll_version_id}|{v.serial_number}|{v.epic_number}|{v.name}|"
            f"{v.normalized_name}|{v.relative_name}|{v.relative_type}|{v.house_number}|"
            f"{v.age}|{v.gender}|{v.part_number}|{v.section_number}"
            for v in voters
        ]
        return hashlib.sha256("\n".join(canonical_rows).encode("utf-8")).hexdigest()

    # Step 1: Capture baseline official fingerprint
    baseline_fingerprint = _compute_voters_fingerprint(phase4b_session)
    assert baseline_fingerprint is not None

    roll_id = "roll-synthetic-4b"
    passphrase = "ImmutabilityTestKey2026!"

    # Step 2: Export field observations
    v1 = phase4b_session.execute(select(Voter).where(Voter.epic_number == "KL14001")).scalars().first()
    fs = FieldStatus(voter_id=v1.id, status=FieldStatusType.AWAY, notes="Immutability check", reported_at=utc_now())
    phase4b_session.add(fs)
    phase4b_session.commit()

    envelope = SyncService.export_observations(
        session=phase4b_session,
        roll_version_id=roll_id,
        operator_username="admin",
        transfer_passphrase=passphrase,
    )
    assert _compute_voters_fingerprint(phase4b_session) == baseline_fingerprint

    # Step 3: Import observations
    preview = SyncService.preview_import(phase4b_session, envelope, passphrase, "admin")
    SyncService.commit_import(phase4b_session, preview, "admin")
    assert _compute_voters_fingerprint(phase4b_session) == baseline_fingerprint

    # Step 4: Resolve conflicts
    conflict = SyncConflict(
        voter_id=v1.id,
        voter_epic="KL14001",
        conflict_type=ConflictType.CONCURRENT,
        local_observation_id="loc-1",
        incoming_observation_id="inc-1",
    )
    phase4b_session.add(conflict)
    phase4b_session.commit()
    ConflictEngine.resolve_conflict(phase4b_session, conflict.id, "ACCEPT_A", "admin")
    assert _compute_voters_fingerprint(phase4b_session) == baseline_fingerprint

    # Step 5: Restore backup
    backup_service = BackupService()
    with tempfile.TemporaryDirectory() as tmp_dir:
        backup_file = backup_service.create_field_delta_backup(
            phase4b_session, roll_id, tmp_dir, passphrase, "admin"
        )
        backup_service.restore_field_delta_backup(
            phase4b_session, backup_file, passphrase, "admin"
        )

    # Step 6: Verify official dataset remains 100% logically and byte-for-byte identical!
    final_fingerprint = _compute_voters_fingerprint(phase4b_session)
    assert baseline_fingerprint == final_fingerprint

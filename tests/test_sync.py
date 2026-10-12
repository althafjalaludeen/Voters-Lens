"""Comprehensive tests for the VoterLens Offline Synchronization Architecture & Protocol."""

from datetime import datetime, timezone, timedelta
import json
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
    Voter,
    generate_uuid,
    utc_now,
)
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
    DeviceConfig,
    FieldObservation,
    SyncConflict,
    SyncPacketDirection,
    SyncPacketRecord,
    SyncPacketStatus,
)
from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    InvalidPacketError,
    RollMismatchError,
    UnsupportedProtocolVersionError,
    deserialize_and_decrypt_packet,
    get_canonical_aad,
    resolve_canonical_voter,
    serialize_packet_envelope,
)
from voterlens.sync.sync_service import SyncService


@pytest.fixture
def sync_db_session():
    """In-memory SQLite database populated strictly with synthetic test data."""
    engine = create_engine("sqlite:///:memory:", echo=False)
    Base.metadata.create_all(engine)
    session_factory = sessionmaker(bind=engine)
    session = session_factory()

    # Seed synthetic roll
    synthetic_roll = RollVersion(
        id="roll-synthetic-001",
        state="Kerala",
        district="Pathanamthitta",
        assembly_constituency="111 - Thiruvalla",
        roll_name="Synthetic Test Roll 2026",
        record_count=3,
        status=RollVersionStatus.ACTIVE,
        checksum_hash="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
    )
    session.add(synthetic_roll)

    # Seed 3 synthetic voters: V001, V002, V003
    v1 = Voter(
        id="voter-uuid-001",
        roll_version_id="roll-synthetic-001",
        serial_number=1,
        epic_number="SYN0000001",
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
        id="voter-uuid-002",
        roll_version_id="roll-synthetic-001",
        serial_number=2,
        epic_number="SYN0000002",
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
        id="voter-uuid-003",
        roll_version_id="roll-synthetic-001",
        serial_number=3,
        epic_number="SYN0000003",
        name="ജോർജ് തോമസ്",
        normalized_name="george thomas",
        relative_name="തോമസ്",
        normalized_relative_name="thomas",
        relative_type="FTHR",
        house_number="12/102",
        normalized_house_number="12/102",
        age=55,
        gender="M",
        part_number="1",
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
# 1. Identity Tests
# ---------------------------------------------------------------------------

def test_device_id_generation_and_persistence(sync_db_session: Session):
    """Device ID must be a UUID, persistent across lookups, not based on voter data."""
    dev1 = SyncService.get_or_create_device_id(sync_db_session)
    assert dev1 is not None
    assert len(dev1) == 36  # UUID length

    # Calling again on same database returns identical persistent device ID
    dev2 = SyncService.get_or_create_device_id(sync_db_session)
    assert dev1 == dev2


def test_stable_voter_identity_resolution(sync_db_session: Session):
    """Canonical voter resolution uses (roll, EPIC) primary and (roll, part, serial) fallback."""
    roll_id = "roll-synthetic-001"

    # Primary lookup by EPIC
    voter = resolve_canonical_voter(sync_db_session, roll_id, voter_epic="SYN0000001")
    assert voter is not None
    assert voter.serial_number == 1
    assert voter.name == "അനിൽ കുമാർ"

    # Fallback lookup by Part & Serial when EPIC is unavailable or modified
    voter_fallback = resolve_canonical_voter(
        sync_db_session, roll_id, voter_epic="UNKNOWN_EPIC", voter_part_serial="1:2"
    )
    assert voter_fallback is not None
    assert voter_fallback.epic_number == "SYN0000002"
    assert voter_fallback.name == "പ്രിയ നായർ"

    # Non-existent voter returns None
    missing = resolve_canonical_voter(sync_db_session, roll_id, voter_epic="NON_EXISTENT")
    assert missing is None


# ---------------------------------------------------------------------------
# 2. Cryptographic Security & Integrity Tests (AES-256-GCM)
# ---------------------------------------------------------------------------

def test_crypto_aes_gcm_roundtrip():
    """Valid AES-256-GCM encryption and decryption roundtrip with AAD."""
    passphrase = "SecretTransferPassphrase2026!"
    salt = b"0123456789abcdef"
    key = derive_key(passphrase, salt)
    aad = b"VOTERLENS_AAD_TEST"
    plaintext = b'{"status": "AWAY", "notes": "Working in Kochi"}'

    ciphertext_with_tag, nonce = encrypt_payload(plaintext, key, associated_data=aad)
    assert len(ciphertext_with_tag) == len(plaintext) + 16  # 16-byte tag appended

    decrypted = decrypt_payload(ciphertext_with_tag, key, nonce, associated_data=aad)
    assert decrypted == plaintext


def test_crypto_wrong_passphrase_rejection():
    """Decryption with wrong passphrase fails with AuthenticationError."""
    salt = b"0123456789abcdef"
    key_correct = derive_key("CorrectPassword", salt)
    key_wrong = derive_key("WrongPassword", salt)
    aad = b"VOTERLENS_AAD_TEST"
    plaintext = b"Sensitive Observation Data"

    ciphertext_with_tag, nonce = encrypt_payload(plaintext, key_correct, associated_data=aad)

    with pytest.raises(AuthenticationError):
        decrypt_payload(ciphertext_with_tag, key_wrong, nonce, associated_data=aad)


def test_crypto_tamper_detection():
    """Modifying even a single bit in ciphertext raises AuthenticationError."""
    salt = b"0123456789abcdef"
    key = derive_key("Password123", salt)
    aad = b"VOTERLENS_AAD_TEST"
    plaintext = b"Tamper Resistance Test Payload"

    ciphertext_with_tag, nonce = encrypt_payload(plaintext, key, associated_data=aad)

    # Flip 1 byte in ciphertext
    corrupted = bytearray(ciphertext_with_tag)
    corrupted[5] ^= 0xFF

    with pytest.raises(AuthenticationError):
        decrypt_payload(bytes(corrupted), key, nonce, associated_data=aad)


def test_crypto_aad_tamper_detection():
    """Modifying unencrypted AAD header (e.g. roll checksum) invalidates the packet."""
    salt = b"0123456789abcdef"
    key = derive_key("Password123", salt)
    aad_original = b"ROLL_CHECKSUM_A"
    aad_tampered = b"ROLL_CHECKSUM_B"
    plaintext = b"Payload with bound AAD"

    ciphertext_with_tag, nonce = encrypt_payload(plaintext, key, associated_data=aad_original)

    # Attempt decryption with tampered AAD
    with pytest.raises(AuthenticationError):
        decrypt_payload(ciphertext_with_tag, key, nonce, associated_data=aad_tampered)


# ---------------------------------------------------------------------------
# 3. Protocol Envelope & Versioning Tests
# ---------------------------------------------------------------------------

def test_protocol_serialization_and_deserialization():
    """Sync packet envelope serializes deterministically and decrypts accurately."""
    observations = [{
        "observation_id": generate_uuid(),
        "voter_epic": "SYN0000001",
        "voter_part_serial": "1:1",
        "roll_version_id": "roll-1",
        "roll_checksum": "checksum-1",
        "field_status": "AWAY",
        "phone_number": "9876543210",
        "notes": "Testing sync",
        "created_by": "operator_1",
        "created_at": utc_now().isoformat(),
        "origin_device_id": generate_uuid(),
        "supersedes_id": None,
        "is_revoked": False,
        "revocation_reason": None,
    }]
    passphrase = "PairingSecret987!"

    packet = serialize_packet_envelope(
        packet_id="pkt-test-001",
        source_device_id="device-test-001",
        source_user_id="operator_anil",
        roll_version_id="roll-1",
        roll_checksum="checksum-1",
        observations=observations,
        transfer_passphrase=passphrase,
    )

    assert packet["protocol_version"] == 1
    assert packet["packet_id"] == "pkt-test-001"
    assert packet["observation_count"] == 1
    assert "ciphertext_hex" in packet

    # Deserialize and decrypt
    metadata, decrypted_obs = deserialize_and_decrypt_packet(packet, passphrase)
    assert metadata["packet_id"] == "pkt-test-001"
    assert len(decrypted_obs) == 1
    assert decrypted_obs[0]["voter_epic"] == "SYN0000001"
    assert decrypted_obs[0]["field_status"] == "AWAY"


def test_protocol_unsupported_version_rejection():
    """Packets with future or unsupported protocol versions must be rejected gracefully."""
    packet = {
        "protocol_version": 99,  # Unsupported version
        "packet_id": "pkt-future",
        "source_device_id": "dev",
        "source_user_id": "user",
        "roll_version_id": "r1",
        "roll_checksum": "c1",
        "observation_count": 0,
        "encryption": {"algorithm": "AES-256-GCM", "salt_hex": "aa", "nonce_hex": "bb"},
        "ciphertext_hex": "cc",
    }
    with pytest.raises(UnsupportedProtocolVersionError):
        deserialize_and_decrypt_packet(packet, "any_passphrase")


# ---------------------------------------------------------------------------
# 4. End-to-End Export & Import Pipeline Tests
# ---------------------------------------------------------------------------

def test_export_and_import_observations_clean(sync_db_session: Session):
    """End-to-end export from Device A and atomic import into Device B."""
    roll_id = "roll-synthetic-001"
    passphrase = "FieldExchangeKey2026"

    # Record local observation on Device A
    v1 = sync_db_session.execute(
        select(Voter).where(Voter.epic_number == "SYN0000001")
    ).scalars().first()
    
    fs1 = FieldStatus(
        voter_id=v1.id,
        status=FieldStatusType.AWAY,
        phone_number="9876543210",
        notes="Working in Ernakulam",
        reported_by="operator_a",
        reported_at=utc_now(),
    )
    sync_db_session.add(fs1)
    sync_db_session.commit()

    # 1. Device A exports observations
    packet = SyncService.export_observations(
        session=sync_db_session,
        roll_version_id=roll_id,
        operator_username="operator_a",
        transfer_passphrase=passphrase,
    )
    assert packet["observation_count"] == 1

    # 2. Check export audit log
    audit_export = sync_db_session.execute(
        select(AuditLog).where(AuditLog.action == "SYNC_EXPORT_CREATED")
    ).scalars().first()
    assert audit_export is not None
    assert audit_export.performed_by == "operator_a"

    # Reset local field_status and field_observations to simulate clean receiving Device B
    sync_db_session.delete(fs1)
    for obs in sync_db_session.execute(select(FieldObservation)).scalars().all():
        sync_db_session.delete(obs)
    sync_db_session.commit()
    assert v1.field_status is None

    # 3. Device B imports the packet
    result = SyncService.import_observations(
        session=sync_db_session,
        packet_data=packet,
        transfer_passphrase=passphrase,
        operator_username="operator_b",
    )

    assert result["status"] == "SUCCESS"
    assert result["imported_count"] == 1
    assert result["conflict_count"] == 0

    # 4. Verify observation materialized in field_status
    sync_db_session.refresh(v1)
    assert v1.field_status is not None
    assert v1.field_status.status == FieldStatusType.AWAY
    assert v1.field_status.phone_number == "9876543210"
    assert v1.field_status.notes == "Working in Ernakulam"

    # 5. Verify observation event store has recorded event
    obs_record = sync_db_session.execute(
        select(FieldObservation).where(FieldObservation.voter_epic == "SYN0000001")
    ).scalars().first()
    assert obs_record is not None
    assert obs_record.field_status == FieldStatusType.AWAY

    # 6. Verify audit log recorded
    audit_import = sync_db_session.execute(
        select(AuditLog).where(AuditLog.action == "SYNC_IMPORT_COMPLETED")
    ).scalars().first()
    assert audit_import is not None
    assert audit_import.performed_by == "operator_b"


# ---------------------------------------------------------------------------
# 5. Idempotency & Duplicate Re-import Tests
# ---------------------------------------------------------------------------

def test_idempotent_duplicate_packet_import(sync_db_session: Session):
    """Importing the same packet twice returns IDEMPOTENT_SKIPPED with 0 mutations."""
    roll_id = "roll-synthetic-001"
    passphrase = "IdempotencyKey"

    v2 = sync_db_session.execute(
        select(Voter).where(Voter.epic_number == "SYN0000002")
    ).scalars().first()
    fs2 = FieldStatus(
        voter_id=v2.id,
        status=FieldStatusType.ABROAD,
        notes="Residing in Dubai",
        reported_by="operator_anil",
    )
    sync_db_session.add(fs2)
    sync_db_session.commit()

    packet = SyncService.export_observations(
        session=sync_db_session,
        roll_version_id=roll_id,
        operator_username="operator_anil",
        transfer_passphrase=passphrase,
    )

    # First import
    res1 = SyncService.import_observations(
        session=sync_db_session,
        packet_data=packet,
        transfer_passphrase=passphrase,
        operator_username="operator_suresh",
    )
    assert res1["status"] in ("SUCCESS", "IDEMPOTENT_SKIPPED")

    # Second import (identical packet)
    res2 = SyncService.import_observations(
        session=sync_db_session,
        packet_data=packet,
        transfer_passphrase=passphrase,
        operator_username="operator_suresh",
    )
    assert res2["status"] == "IDEMPOTENT_SKIPPED"
    assert res2["imported_count"] == 0


# ---------------------------------------------------------------------------
# 6. Roll Checksum & Roll Compatibility Verification
# ---------------------------------------------------------------------------

def test_mismatched_roll_checksum_blocked(sync_db_session: Session):
    """Packets from an unrelated or mismatched electoral roll are blocked immediately."""
    passphrase = "Key"
    obs = [{
        "observation_id": generate_uuid(),
        "voter_epic": "SYN0000001",
        "roll_version_id": "roll-synthetic-001",
        "roll_checksum": "WRONG_CHECKSUM_XYZ_99999999999999999999999999999999999999999999",
        "field_status": "AWAY",
        "created_by": "op",
        "created_at": utc_now().isoformat(),
        "origin_device_id": generate_uuid(),
        "supersedes_id": None,
        "is_revoked": False,
        "revocation_reason": None,
    }]

    packet = serialize_packet_envelope(
        packet_id="pkt-mismatch",
        source_device_id="dev-bad",
        source_user_id="user-bad",
        roll_version_id="roll-synthetic-001",
        roll_checksum="WRONG_CHECKSUM_XYZ_99999999999999999999999999999999999999999999",
        observations=obs,
        transfer_passphrase=passphrase,
    )

    with pytest.raises(RollMismatchError) as exc_info:
        SyncService.import_observations(
            session=sync_db_session,
            packet_data=packet,
            transfer_passphrase=passphrase,
            operator_username="operator_local",
        )
    assert "checksum mismatch" in str(exc_info.value).lower()

    # Rejection audit log must be recorded
    audit_rej = sync_db_session.execute(
        select(AuditLog).where(AuditLog.action == "SYNC_PACKET_REJECTED")
    ).scalars().first()
    assert audit_rej is not None


# ---------------------------------------------------------------------------
# 7. Conflict Detection, Flagging & Resolution Tests
# ---------------------------------------------------------------------------

def test_concurrent_conflict_detection_and_resolution(sync_db_session: Session):
    """Concurrent divergent observations flag a conflict, tag review, and allow resolution."""
    roll_id = "roll-synthetic-001"
    passphrase = "ConflictKey"
    v3 = sync_db_session.execute(
        select(Voter).where(Voter.epic_number == "SYN0000003")
    ).scalars().first()

    # Local state on Device B: George Thomas is marked AWAY
    t_local = datetime(2026, 10, 5, 10, 0, tzinfo=timezone.utc)
    obs_local = FieldObservation(
        observation_id="obs-local-001",
        voter_id=v3.id,
        voter_epic=v3.epic_number,
        roll_version_id=roll_id,
        roll_checksum="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
        field_status=FieldStatusType.AWAY,
        created_by="operator_b",
        created_at=t_local,
        origin_device_id="device-b",
    )
    fs3 = FieldStatus(
        voter_id=v3.id,
        status=FieldStatusType.AWAY,
        reported_by="operator_b",
        reported_at=t_local,
    )
    sync_db_session.add_all([obs_local, fs3])
    sync_db_session.commit()

    # Device A sends concurrent observation: George Thomas REPORTED_DECEASED
    t_incoming = datetime(2026, 10, 5, 10, 5, tzinfo=timezone.utc)
    incoming_obs = [{
        "observation_id": "obs-incoming-002",
        "voter_epic": v3.epic_number,
        "voter_part_serial": "1:3",
        "roll_version_id": roll_id,
        "roll_checksum": "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
        "field_status": "REPORTED_DECEASED",
        "phone_number": None,
        "notes": "Reported deceased by neighbor",
        "created_by": "operator_a",
        "created_at": t_incoming.isoformat(),
        "origin_device_id": "device-a",
        "supersedes_id": None,
        "is_revoked": False,
        "revocation_reason": None,
    }]

    packet = serialize_packet_envelope(
        packet_id="pkt-conflict-001",
        source_device_id="device-a",
        source_user_id="operator_a",
        roll_version_id=roll_id,
        roll_checksum="a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
        observations=incoming_obs,
        transfer_passphrase=passphrase,
    )

    # Import on Device B
    res = SyncService.import_observations(
        session=sync_db_session,
        packet_data=packet,
        transfer_passphrase=passphrase,
        operator_username="operator_b",
    )

    assert res["conflict_count"] == 1
    sync_db_session.refresh(v3)
    sync_db_session.refresh(fs3)

    # 1. Verify conflict record created
    conflict = sync_db_session.execute(
        select(SyncConflict).where(SyncConflict.voter_epic == v3.epic_number)
    ).scalars().first()
    assert conflict is not None
    assert conflict.conflict_type == ConflictType.CONCURRENT
    assert conflict.resolution_status == ConflictResolutionStatus.PENDING_REVIEW

    # 2. Verify voter flagged for review (NEEDS_REVIEW)
    assert fs3.review_status == ReviewStatusType.NEEDS_REVIEW
    assert "Sync Conflict" in fs3.review_reasons

    # 3. Verify both observations preserved in event store
    obs_all = sync_db_session.execute(
        select(FieldObservation).where(FieldObservation.voter_epic == v3.epic_number)
    ).scalars().all()
    assert len(obs_all) == 2

    # 4. Supervisor resolves conflict: Accept incoming observation B (Deceased)
    ConflictEngine.resolve_conflict(
        session=sync_db_session,
        conflict_id=conflict.id,
        choice="ACCEPT_B",
        resolver_user="supervisor_mohan",
        notes="Verified death certificate with village officer",
    )
    sync_db_session.commit()
    sync_db_session.refresh(conflict)
    sync_db_session.refresh(fs3)

    assert conflict.resolution_status == ConflictResolutionStatus.RESOLVED_ACCEPTED_B
    assert fs3.status == FieldStatusType.REPORTED_DECEASED
    assert fs3.review_status == ReviewStatusType.REVIEWED
    assert fs3.reviewed_by == "supervisor_mohan"


# ---------------------------------------------------------------------------
# 8. Absolute Immutability Guarantee Check
# ---------------------------------------------------------------------------

def test_official_voter_records_strictly_immutable(sync_db_session: Session):
    """Synchronization operations must NEVER alter or delete rows in the voters table."""
    voters_before = sync_db_session.execute(select(Voter)).scalars().all()
    before_fingerprints = [
        (v.id, v.epic_number, v.name, v.house_number, v.age, v.gender)
        for v in voters_before
    ]

    # Perform export and import of observations
    roll_id = "roll-synthetic-001"
    passphrase = "SecretImmutabilityKey"
    pkt = SyncService.export_observations(
        session=sync_db_session,
        roll_version_id=roll_id,
        operator_username="operator_test",
        transfer_passphrase=passphrase,
    )
    SyncService.import_observations(
        session=sync_db_session,
        packet_data=pkt,
        transfer_passphrase=passphrase,
        operator_username="operator_test",
    )

    # Check voters after sync
    voters_after = sync_db_session.execute(select(Voter)).scalars().all()
    after_fingerprints = [
        (v.id, v.epic_number, v.name, v.house_number, v.age, v.gender)
        for v in voters_after
    ]

    assert len(voters_before) == len(voters_after) == 3
    assert before_fingerprints == after_fingerprints

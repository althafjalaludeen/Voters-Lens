"""Protocol envelope, serialization, and canonical voter identity resolution."""

from datetime import datetime, timezone
import hashlib
import json
from typing import Any, Dict, List, Optional, Tuple
import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from voterlens.database.models import RollVersion, Voter
from voterlens.sync.crypto import (
    SALT_SIZE_BYTES,
    decrypt_payload,
    derive_key,
    encrypt_payload,
    generate_random_bytes,
)

CURRENT_PROTOCOL_VERSION = 1
SUPPORTED_PROTOCOL_VERSIONS = {1}


class ProtocolError(Exception):
    """Base exception for synchronization protocol violations."""
    pass


class UnsupportedProtocolVersionError(ProtocolError):
    """Raised when incoming packet has an unsupported protocol version."""
    pass


class InvalidPacketError(ProtocolError):
    """Raised when sync packet schema or envelope validation fails."""
    pass


class RollMismatchError(ProtocolError):
    """Raised when packet roll version or roll checksum does not match active roll."""
    pass


def get_canonical_aad(
    protocol_version: int,
    packet_id: str,
    source_device_id: str,
    roll_version_id: str,
    roll_checksum: str,
    observation_count: int,
) -> bytes:
    """Generate deterministic Additional Authenticated Data (AAD) for AES-GCM."""
    canonical_string = (
        f"VOTERLENS_SYNC_V{protocol_version}|{packet_id}|{source_device_id}|"
        f"{roll_version_id}|{roll_checksum}|{observation_count}"
    )
    return canonical_string.encode("utf-8")


def resolve_canonical_voter(
    session: Session,
    roll_version_id: str,
    voter_epic: str,
    voter_part_serial: Optional[str] = None,
) -> Optional[Voter]:
    """Resolve a voter using the canonical identity strategy.
    
    Strategy:
    1. Primary Canonical Identity: (roll_version_id, epic_number)
    2. Fallback Identity: (roll_version_id, part_number, serial_number)
    
    Returns:
        Matching Voter record or None.
    """
    # 1. Primary lookup by EPIC
    if voter_epic:
        stmt = select(Voter).where(
            Voter.roll_version_id == roll_version_id,
            Voter.epic_number == voter_epic,
        )
        voter = session.execute(stmt).scalars().first()
        if voter:
            return voter

    # 2. Fallback lookup by Part & Serial number
    if voter_part_serial and ":" in voter_part_serial:
        try:
            part_str, serial_str = voter_part_serial.split(":", 1)
            serial_int = int(serial_str)
            stmt = select(Voter).where(
                Voter.roll_version_id == roll_version_id,
                Voter.part_number == part_str,
                Voter.serial_number == serial_int,
            )
            return session.execute(stmt).scalars().first()
        except (ValueError, TypeError):
            pass

    return None


def serialize_packet_envelope(
    packet_id: str,
    source_device_id: str,
    source_user_id: str,
    roll_version_id: str,
    roll_checksum: str,
    observations: List[Dict[str, Any]],
    transfer_passphrase: str,
    protocol_version: int = CURRENT_PROTOCOL_VERSION,
    packet_type: str = "FIELD_OBSERVATIONS_SYNC",
    custom_payload_dict: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Serialize and encrypt a field observations synchronization packet.
    
    Args:
        packet_id: Globally unique packet identifier.
        source_device_id: UUID of sending device.
        source_user_id: Identifier of operator creating transfer.
        roll_version_id: Active roll version ID.
        roll_checksum: SHA-256 checksum of active roll.
        observations: List of field observation dictionaries.
        transfer_passphrase: Out-of-band shared passphrase for encryption.
        protocol_version: Protocol format version.
        packet_type: Packet semantic type (e.g. FIELD_OBSERVATIONS_SYNC, GAZETTE_SNAPSHOT, FIELD_DELTA_BACKUP).
        custom_payload_dict: Optional override for full payload dict (used for backups).
        
    Returns:
        Structured packet dictionary ready for transport.
    """
    observation_count = len(observations)
    created_at = datetime.now(timezone.utc).isoformat()
    
    # 1. Prepare raw payload
    if custom_payload_dict is not None:
        payload_dict = custom_payload_dict
    else:
        payload_dict = {
            "packet_id": packet_id,
            "roll_version_id": roll_version_id,
            "roll_checksum": roll_checksum,
            "observations": observations,
        }
    payload_bytes = json.dumps(payload_dict, sort_keys=True).encode("utf-8")

    # 2. Derive encryption key with random salt
    salt = generate_random_bytes(SALT_SIZE_BYTES)
    key = derive_key(transfer_passphrase, salt)

    # 3. Compute AAD
    aad = get_canonical_aad(
        protocol_version=protocol_version,
        packet_id=packet_id,
        source_device_id=source_device_id,
        roll_version_id=roll_version_id,
        roll_checksum=roll_checksum,
        observation_count=observation_count,
    )

    # 4. Encrypt with AES-256-GCM
    ciphertext_with_tag, nonce = encrypt_payload(payload_bytes, key, associated_data=aad)

    # 5. Build envelope with magic and integrity information
    envelope = {
        "magic": "VLSYNC",
        "protocol_version": protocol_version,
        "packet_id": packet_id,
        "created_at": created_at,
        "packet_type": packet_type,
        "source_device_id": source_device_id,
        "source_user_id": source_user_id,
        "roll_version_id": roll_version_id,
        "roll_checksum": roll_checksum,
        "observation_count": observation_count,
        "encryption": {
            "algorithm": "AES-256-GCM",
            "kdf": "PBKDF2-HMAC-SHA256",
            "iterations": 100_000,
            "salt_hex": salt.hex(),
            "nonce_hex": nonce.hex(),
        },
        "ciphertext_hex": ciphertext_with_tag.hex(),
        "file_integrity": {
            "sha256": hashlib.sha256(ciphertext_with_tag).hexdigest(),
        },
    }
    return envelope


def deserialize_and_decrypt_packet(
    packet_data: Dict[str, Any],
    transfer_passphrase: str,
) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Validate, authenticate, and decrypt an incoming synchronization packet.
    
    Args:
        packet_data: Raw dictionary loaded from JSON sync packet.
        transfer_passphrase: Out-of-band shared passphrase for decryption.
        
    Returns:
        Tuple of (envelope_metadata, decrypted_observations_list).
    """
    # 1. Magic check (if present)
    if "magic" in packet_data and packet_data["magic"] != "VLSYNC":
        raise InvalidPacketError(f"Invalid file magic header: '{packet_data['magic']}'. Expected 'VLSYNC'")

    # 2. Schema check
    required_fields = [
        "protocol_version", "packet_id", "source_device_id", "source_user_id",
        "roll_version_id", "roll_checksum", "observation_count", "encryption",
        "ciphertext_hex"
    ]
    for field in required_fields:
        if field not in packet_data:
            raise InvalidPacketError(f"Missing required envelope field: {field}")

    # 3. Protocol version check
    proto_ver = packet_data["protocol_version"]
    if proto_ver not in SUPPORTED_PROTOCOL_VERSIONS:
        raise UnsupportedProtocolVersionError(
            f"Unsupported sync protocol version {proto_ver}. Supported versions: {SUPPORTED_PROTOCOL_VERSIONS}"
        )

    # 4. Extract encryption params
    enc_info = packet_data["encryption"]
    if enc_info.get("algorithm") != "AES-256-GCM":
        raise InvalidPacketError(f"Unsupported encryption algorithm: {enc_info.get('algorithm')}")

    try:
        salt = bytes.fromhex(enc_info["salt_hex"])
        nonce = bytes.fromhex(enc_info["nonce_hex"])
        ciphertext_with_tag = bytes.fromhex(packet_data["ciphertext_hex"])
    except (KeyError, ValueError) as exc:
        raise InvalidPacketError(f"Malformed hexadecimal cryptographic fields: {exc}") from exc

    # 5. File integrity verification (if present)
    if "file_integrity" in packet_data and isinstance(packet_data["file_integrity"], dict):
        declared_hash = packet_data["file_integrity"].get("sha256")
        if declared_hash:
            computed_hash = hashlib.sha256(ciphertext_with_tag).hexdigest()
            if declared_hash != computed_hash:
                raise InvalidPacketError(
                    f"File integrity verification failed: declared SHA-256 '{declared_hash}' "
                    f"does not match computed ciphertext hash '{computed_hash}'"
                )

    # 6. Reconstruct AAD
    aad = get_canonical_aad(
        protocol_version=proto_ver,
        packet_id=packet_data["packet_id"],
        source_device_id=packet_data["source_device_id"],
        roll_version_id=packet_data["roll_version_id"],
        roll_checksum=packet_data["roll_checksum"],
        observation_count=packet_data["observation_count"],
    )

    # 7. Derive key and decrypt (Raises AuthenticationError if tampered)
    key = derive_key(transfer_passphrase, salt, iterations=enc_info.get("iterations", 100_000))
    plaintext_bytes = decrypt_payload(ciphertext_with_tag, key, nonce, associated_data=aad)

    # 8. Parse decrypted payload
    try:
        payload = json.loads(plaintext_bytes.decode("utf-8"))
    except Exception as exc:
        raise InvalidPacketError(f"Failed to parse decrypted JSON payload: {exc}") from exc

    observations = payload.get("observations", [])
    if packet_data.get("packet_type") in ("GAZETTE_SNAPSHOT", "FIELD_DELTA_BACKUP"):
        # For backups, return full payload inside packet_data
        packet_data["_decrypted_payload"] = payload
        return packet_data, observations

    if len(observations) != packet_data["observation_count"]:
        raise InvalidPacketError(
            f"Observation count mismatch: envelope declared {packet_data['observation_count']}, "
            f"payload contained {len(observations)}"
        )

    return packet_data, observations

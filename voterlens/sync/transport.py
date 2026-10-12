"""Transport abstraction layer and reference .vlsync file implementation.

Separates synchronization transport (file exchange, QR, Bluetooth, etc.)
from the underlying canonical reconciliation engine.
"""

from abc import ABC, abstractmethod
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Dict, Optional, Union

from voterlens.sync.protocol import (
    CURRENT_PROTOCOL_VERSION,
    SUPPORTED_PROTOCOL_VERSIONS,
    InvalidPacketError,
    UnsupportedProtocolVersionError,
)

MAX_SYNC_FILE_SIZE_BYTES = 50 * 1024 * 1024  # 50 MB safety threshold
VLSYNC_MAGIC = "VLSYNC"
VLSYNC_EXTENSION = ".vlsync"


class SyncTransport(ABC):
    """Abstract base class for synchronization transport mechanisms."""

    @abstractmethod
    def export_packet(
        self,
        packet_envelope: Dict[str, Any],
        destination: str,
        **kwargs: Any,
    ) -> str:
        """Export serialized and encrypted packet envelope to transport destination."""
        pass

    @abstractmethod
    def read_packet(self, source: str, **kwargs: Any) -> Dict[str, Any]:
        """Read and validate transport container from source."""
        pass

    @abstractmethod
    def validate_container(self, raw_data: Union[bytes, str]) -> Dict[str, Any]:
        """Validate container integrity, size, and header formatting."""
        pass


class VLSyncFileTransport(SyncTransport):
    """Reference transport implementation using encrypted local .vlsync files.
    
    Format:
        VLSYNC
        ├── magic: "VLSYNC"
        ├── protocol_version: int
        ├── packet metadata (id, timestamps, source device, roll, observation count)
        ├── encryption metadata (algorithm, kdf, iterations, salt, nonce)
        ├── authenticated ciphertext (AES-256-GCM + tag)
        └── integrity information (SHA-256)
    """

    def __init__(self, max_file_size: int = MAX_SYNC_FILE_SIZE_BYTES):
        self.max_file_size = max_file_size

    def export_packet(
        self,
        packet_envelope: Dict[str, Any],
        destination: str,
        **kwargs: Any,
    ) -> str:
        """Export packet envelope to a local .vlsync file.
        
        Args:
            packet_envelope: Dictionary containing serialized envelope.
            destination: Target file path or directory.
            
        Returns:
            Absolute path to written .vlsync file.
        """
        dest_path = Path(destination)
        if dest_path.is_dir() or destination.endswith(("/", "\\")):
            dest_path.mkdir(parents=True, exist_ok=True)
            timestamp_str = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H%M%S")
            file_name = f"VoterLens_{timestamp_str}{VLSYNC_EXTENSION}"
            target_file = dest_path / file_name
        else:
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            if not str(dest_path).endswith(VLSYNC_EXTENSION):
                target_file = Path(f"{dest_path}{VLSYNC_EXTENSION}")
            else:
                target_file = dest_path

        # Ensure magic header is stamped
        if "magic" not in packet_envelope:
            packet_envelope["magic"] = VLSYNC_MAGIC

        # Serialize deterministically
        canonical_json = json.dumps(packet_envelope, indent=2, sort_keys=True)
        encoded_bytes = canonical_json.encode("utf-8")

        if len(encoded_bytes) > self.max_file_size:
            raise InvalidPacketError(
                f"Exported packet size ({len(encoded_bytes)} bytes) exceeds maximum limit "
                f"({self.max_file_size} bytes)"
            )

        # Atomic write via temporary file
        temp_dir = target_file.parent
        with tempfile.NamedTemporaryFile("wb", dir=temp_dir, delete=False, suffix=".tmp") as tmp_file:
            tmp_path = Path(tmp_file.name)
            tmp_file.write(encoded_bytes)
            tmp_file.flush()

        # Atomic replace
        tmp_path.replace(target_file)
        return str(target_file.resolve())

    def read_packet(self, source: str, **kwargs: Any) -> Dict[str, Any]:
        """Read and validate a .vlsync file from disk.
        
        Args:
            source: Path to the .vlsync file.
            
        Returns:
            Validated envelope dictionary.
        """
        file_path = Path(source)
        if not file_path.is_file():
            raise FileNotFoundError(f"Sync file not found: {source}")

        file_size = file_path.stat().st_size
        if file_size > self.max_file_size:
            raise InvalidPacketError(
                f"Sync file size ({file_size} bytes) exceeds maximum allowable limit "
                f"({self.max_file_size} bytes)"
            )

        with open(file_path, "rb") as f:
            raw_bytes = f.read()

        return self.validate_container(raw_bytes)

    def validate_container(self, raw_data: Union[bytes, str]) -> Dict[str, Any]:
        """Validate container integrity, magic header, protocol version, and structure.
        
        Args:
            raw_data: Raw byte string or decoded JSON string.
            
        Returns:
            Parsed packet envelope dictionary.
        """
        if isinstance(raw_data, bytes):
            if len(raw_data) > self.max_file_size:
                raise InvalidPacketError(
                    f"Payload size ({len(raw_data)} bytes) exceeds limit ({self.max_file_size} bytes)"
                )
            try:
                decoded_str = raw_data.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise InvalidPacketError(f"Corrupted sync file: invalid UTF-8 encoding ({exc})") from exc
        else:
            decoded_str = raw_data

        try:
            envelope = json.loads(decoded_str)
        except json.JSONDecodeError as exc:
            raise InvalidPacketError(f"Malformed sync container: invalid JSON structure ({exc})") from exc

        if not isinstance(envelope, dict):
            raise InvalidPacketError("Invalid sync container: top-level element must be an object")

        # 1. Magic check
        magic = envelope.get("magic")
        if magic != VLSYNC_MAGIC:
            raise InvalidPacketError(
                f"Invalid sync file magic header '{magic}'. Expected '{VLSYNC_MAGIC}'"
            )

        # 2. Protocol version check
        proto_ver = envelope.get("protocol_version")
        if proto_ver is None:
            raise InvalidPacketError("Sync container missing 'protocol_version'")
        if proto_ver not in SUPPORTED_PROTOCOL_VERSIONS:
            raise UnsupportedProtocolVersionError(
                f"Unsupported protocol version {proto_ver}. Supported: {SUPPORTED_PROTOCOL_VERSIONS}"
            )

        # 3. Mandatory envelope keys
        mandatory_keys = [
            "packet_id", "source_device_id", "source_user_id",
            "roll_version_id", "roll_checksum", "observation_count",
            "encryption", "ciphertext_hex"
        ]
        for key in mandatory_keys:
            if key not in envelope:
                raise InvalidPacketError(f"Sync container missing mandatory field: {key}")

        # 4. Integrity check (if present)
        integrity = envelope.get("file_integrity")
        if integrity and isinstance(integrity, dict):
            declared_sha = integrity.get("sha256")
            ciphertext_hex = envelope.get("ciphertext_hex", "")
            try:
                ciphertext_bytes = bytes.fromhex(ciphertext_hex)
                computed_sha = hashlib.sha256(ciphertext_bytes).hexdigest()
                if declared_sha != computed_sha:
                    raise InvalidPacketError(
                        f"Integrity check failed: declared SHA-256 {declared_sha} "
                        f"does not match computed {computed_sha}"
                    )
            except ValueError as exc:
                raise InvalidPacketError(f"Corrupted hexadecimal ciphertext: {exc}") from exc

        return envelope

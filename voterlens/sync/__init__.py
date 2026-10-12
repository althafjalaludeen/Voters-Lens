"""VoterLens Offline Synchronization Module."""

from voterlens.sync.backup import BackupService
from voterlens.sync.conflict_engine import ConflictAnalysisResult, ConflictEngine
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
    DeviceConfig,
    FieldObservation,
    PacketType,
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
from voterlens.sync.sync_service import SyncService
from voterlens.sync.transport import SyncTransport, VLSyncFileTransport
from voterlens.sync.validation import (
    filter_valid_observations_for_export,
    validate_observation_for_export,
)

__all__ = [
    "BackupService",
    "CURRENT_PROTOCOL_VERSION",
    "AuthenticationError",
    "ConflictAnalysisResult",
    "ConflictEngine",
    "ConflictResolutionStatus",
    "ConflictType",
    "CryptoError",
    "DeviceConfig",
    "ExportScope",
    "ExportScopeFilter",
    "FieldObservation",
    "ImportPreview",
    "InvalidPacketError",
    "PacketType",
    "PreviewEngine",
    "PreviewRecord",
    "ProtocolError",
    "RollMismatchError",
    "SyncPacketDirection",
    "SyncPacketRecord",
    "SyncPacketStatus",
    "SyncService",
    "SyncTransport",
    "TrustedDevice",
    "VLSyncFileTransport",
    "WeakPassphraseError",
    "decrypt_payload",
    "derive_key",
    "deserialize_and_decrypt_packet",
    "encrypt_payload",
    "filter_valid_observations_for_export",
    "generate_transfer_secret",
    "resolve_canonical_voter",
    "serialize_packet_envelope",
    "validate_observation_for_export",
    "validate_transfer_passphrase",
]

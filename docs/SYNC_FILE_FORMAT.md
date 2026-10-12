# VoterLens — .vlsync File Format Specification

## 1. Overview

The `.vlsync` file format is the reference offline synchronization transport container for VoterLens. It packages field observations into an authenticated, encrypted, deterministic file container designed for air-gapped field exchange (micro-SD card, USB drive, offline file sharing).

## 2. Container Hierarchy

A `.vlsync` container follows a deterministic structure:

```
VLSYNC
├── magic: "VLSYNC"
├── protocol_version: 1
├── packet metadata
│   ├── packet_id: UUIDv4
│   ├── source_device_id: UUIDv4
│   ├── source_user_id: string
│   ├── roll_version_id: UUID
│   ├── roll_checksum: string (SHA-256)
│   ├── observation_count: integer
│   └── created_at: ISO-8601 UTC timestamp
├── encryption metadata
│   ├── algorithm: "AES-256-GCM"
│   ├── kdf: "PBKDF2-HMAC-SHA256"
│   ├── kdf_iterations: 100000
│   ├── salt_hex: 16-byte hex
│   ├── nonce_hex: 12-byte hex (96 bits)
│   └── tag_hex: 16-byte hex (128 bits)
├── authenticated ciphertext
│   └── ciphertext_hex: hex-encoded ciphertext
└── integrity information
    └── file_integrity:
        └── sha256: SHA-256 hex digest of ciphertext bytes
```

## 3. Cryptographic Specification

### 3.1 Encryption Algorithm
- **Cipher**: AES-256 in Galois/Counter Mode (AES-256-GCM)
- **Key Length**: 256 bits (32 bytes)
- **Nonce/IV**: 96 bits (12 bytes), generated via cryptographic CSPRNG (`os.urandom(12)`) per export
- **Tag**: 128 bits (16 bytes), authenticated by GCM

### 3.2 Key Derivation Function (KDF)
- **Algorithm**: PBKDF2-HMAC-SHA256
- **Iterations**: 100,000 iterations
- **Salt**: Fresh 16 bytes generated cryptographically per file
- **Input**: User-provided transfer passphrase (never persisted, never logged)

### 3.3 Associated Authenticated Data (AAD)
To ensure packet metadata cannot be tampered with or swapped out without invalidating the cryptographic tag, the GCM cipher binds the following pipe-delimited AAD:

```
VOTERLENS_SYNC_V<protocol_version>|<packet_id>|<source_device_id>|<roll_version_id>|<roll_checksum>|<observation_count>
```

Example AAD:
```
VOTERLENS_SYNC_V1|f47ac10b-58cc-4372-a567-0e02b2c3d479|8a21e428-1111-4444-9999-123456789abc|e7f9a1b2-3c4d-5e6f-7a8b-9c0d1e2f3a4b|3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b|24
```

Any modification to `protocol_version`, `packet_id`, `source_device_id`, `roll_version_id`, `roll_checksum`, or `observation_count` causes immediate AES-GCM tag verification failure upon decryption.

## 4. Deterministic Serialization

To avoid non-deterministic serialization discrepancies across platforms (Python and Dart/Flutter):
- All JSON objects are serialized with sorted keys (`sort_keys=True` in Python).
- Standard UTF-8 encoding without BOM.
- Explicit 2-space indentation.

## 5. File Naming Convention & Security Considerations

- **Filename format**: `VoterLens_<YYYY-MM-DD>_<HHMMSS>.vlsync`
- **Security rule**: Filename metadata is strictly informational. The application never relies on filename for security, routing, or identity verification. The authenticated packet envelope and AAD determine all authoritative metadata.
- **Maximum file size**: 50 MB threshold (`MAX_SYNC_FILE_SIZE_BYTES`) to prevent memory exhaustion and zip-bomb style denial of service attacks.

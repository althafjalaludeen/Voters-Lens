# VoterLens — Synchronization Protocol Specification (v1)

## 1. Protocol Overview & Versioning

The VoterLens Sync Protocol (v1) defines a deterministic, secure, and transport-agnostic message format for exchanging local electoral field observations between offline installations.

* **Current Protocol Version**: `1` (Integer)
* **Versioning Policy**: Forward compatibility must be explicit. Receiving devices MUST reject any packet whose `protocol_version` exceeds supported versions (`UnsupportedProtocolVersionError`). Protocol versions are strictly monotonic integers.

---

## 2. Packet Envelope Specification

Every packet is a JSON-serialized document composed of two sections:
1. **Unencrypted Envelope Header**: Routing, versioning, and cryptographic parameters required to verify and decrypt the payload.
2. **Encrypted Ciphertext**: AES-256-GCM authenticated ciphertext encapsulating field observations.

```json
{
  "protocol_version": 1,
  "packet_id": "c1f7b991-8d2a-4f5e-9a1b-3c4d5e6f7a8b",
  "created_at": "2026-10-05T03:30:00.000000+00:00",
  "packet_type": "FIELD_OBSERVATIONS_SYNC",
  "source_device_id": "d0e1f2a3-b4c5-4d6e-8f9a-0b1c2d3e4f5a",
  "source_user_id": "anil_field_op",
  "roll_version_id": "r8b9c0d1-e2f3-4a5b-6c7d-8e9f0a1b2c3d",
  "roll_checksum": "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
  "observation_count": 2,
  "encryption": {
    "algorithm": "AES-256-GCM",
    "kdf": "PBKDF2-HMAC-SHA256",
    "iterations": 100000,
    "salt_hex": "4a7b2c9e1f3d8a5b6c0e2f4a8b1c3d5e",
    "nonce_hex": "1a2b3c4d5e6f7a8b9c0d1e2f"
  },
  "ciphertext_hex": "9f8e7d6c5b4a3f2e1d0c...[hex-encoded ciphertext + 16-byte tag]"
}
```

---

## 3. Decrypted Payload Schema

Inside the AES-256-GCM ciphertext lies the decrypted observation payload:

```json
{
  "packet_id": "c1f7b991-8d2a-4f5e-9a1b-3c4d5e6f7a8b",
  "roll_version_id": "r8b9c0d1-e2f3-4a5b-6c7d-8e9f0a1b2c3d",
  "roll_checksum": "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
  "observations": [
    {
      "observation_id": "obs-001-uuid-4",
      "voter_epic": "KL/14/098/123456",
      "voter_part_serial": "1:12",
      "roll_version_id": "r8b9c0d1-e2f3-4a5b-6c7d-8e9f0a1b2c3d",
      "roll_checksum": "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90",
      "field_status": "AWAY",
      "phone_number": "9847012345",
      "notes": "Working in Ernakulam, returns on weekends",
      "created_by": "anil_field_op",
      "created_at": "2026-10-05T03:25:00.000000+00:00",
      "origin_device_id": "d0e1f2a3-b4c5-4d6e-8f9a-0b1c2d3e4f5a",
      "supersedes_id": null,
      "is_revoked": false,
      "revocation_reason": null
    }
  ]
}
```

---

## 4. Cryptographic Binding via Additional Authenticated Data (AAD)

To prevent an adversary from tampering with unencrypted envelope headers (e.g., swapping `packet_id`, altering `roll_checksum`, or forging `source_device_id`), the protocol enforces cryptographic binding via AES-GCM Additional Authenticated Data (AAD).

### Canonical AAD Construction:
```
VOTERLENS_SYNC_V<protocol_version>|<packet_id>|<source_device_id>|<roll_version_id>|<roll_checksum>|<observation_count>
```

Example:
```
VOTERLENS_SYNC_V1|c1f7b991...|d0e1f2a3...|r8b9c0d1...|a1b2c3d4...|2
```

If an attacker modifies even a single character in the unencrypted header, the GCM tag verification will fail, immediately aborting the import before any database action occurs.

---

## 5. Stable Canonical Voter Identity Strategy

In offline environments, internal database auto-increment IDs or locally generated row UUIDs cannot be assumed identical across independently deployed databases.

VoterLens implements a two-tier identity resolution strategy:

1. **Primary Canonical Identity: `(roll_checksum, epic_number)`**
   - Electoral Photo Identity Card (EPIC) is the constitutional, statutory unique identifier for electors across India.
   - Combined with `roll_checksum`, it uniquely identifies the exact voter record across all installations.
2. **Fallback Identity: `(roll_checksum, part_number, serial_number)`**
   - Employed in the rare event of damaged voter cards where the EPIC was illegible during OCR import, or when resolving legacy records.
   - Serial number is strictly unique within a given polling station part.

If both lookups fail, the observation is flagged with `ConflictType.VOTER_NOT_FOUND` and sent to the supervisor review queue.

---

## 6. Detailed 14-Stage Atomic Import Pipeline

Every incoming sync packet must traverse all 14 stages in strict sequence:

| Stage | Operation | Description / Enforcement |
| :---: | :--- | :--- |
| **1** | **Envelope Parsing** | Verify JSON structure and ensure all mandatory header fields exist. |
| **2** | **Version Check** | Verify `protocol_version` is supported (current: `1`). Reject if unsupported. |
| **3** | **AAD Reconstruction** | Rebuild canonical AAD byte string from header attributes. |
| **4** | **Decryption & Auth** | Derive AES-256 key via PBKDF2; verify GCM tag and decrypt payload. |
| **5** | **Roll Verification** | Match packet `roll_checksum` against local active roll. Block if mismatched. |
| **6** | **Trusted Peer Check** | (Optional policy) Verify `source_device_id` exists in `trusted_devices`. |
| **7** | **Idempotency Check** | Check `sync_packets` for `packet_id` with `direction = IMPORT`. Return early if duplicate. |
| **8** | **Transaction Start** | Open atomic SQLite transaction (`session.begin()`). |
| **9** | **Voter Resolution** | Map each observation to local voter via canonical identity strategy. |
| **10**| **Deduplication** | Filter out observations whose `observation_id` is already stored in `field_observations`. |
| **11**| **Conflict Analysis** | Execute `ConflictEngine` to categorize as `STALE`, `CONCURRENT`, or `ACTIONABLE`. |
| **12**| **Event & State Write**| Append events to `field_observations`; materialize non-conflicting states to `field_status`. |
| **13**| **Immutability Check**| Assert that `voters` table row count and contents have NOT changed. Rollback if violated. |
| **14**| **Commit & Audit** | Commit transaction; record `SyncPacketRecord`; emit `SYNC_IMPORT_COMPLETED` audit event. |

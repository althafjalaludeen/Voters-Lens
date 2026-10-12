# VoterLens — Synchronization Import & Export Architecture

## 1. Overview

VoterLens synchronization enables peer-to-peer field data exchange across offline devices without internet, local servers, or cloud dependencies. The import and export workflows follow strict architectural invariants:

1. **Official electoral data is strictly immutable**: Sync operations never insert, modify, or delete official voter rows or roll versions.
2. **Two-stage import**: No data enters live tables without preview inspection.
3. **Idempotence & Replay Protection**: Importing the same file multiple times is a safe no-op.
4. **Transport independence**: All workflows interact through `SyncTransport`.

---

## 2. Export Workflow

```
User triggers Export
        ↓
Authorize Role (FIELD_USER, MANAGER, or ADMIN)
        ↓
Select Scope (ALL_ELIGIBLE_FIELD_OBSERVATIONS / PART / HOUSE)
        ↓
Collect Observations from append-only store (field_observations)
        ↓
Validate Observations against canonical schema
        ↓
Assemble Canonical Packet with metadata & roll checksum
        ↓
Serialize deterministically (canonical JSON)
        ↓
Encrypt payload with AES-256-GCM + PBKDF2 (user transfer passphrase)
        ↓
Bind AAD with metadata invariants
        ↓
Write .vlsync file atomically via temporary file
        ↓
Record SYNC_EXPORT_COMPLETED audit event
        ↓
Return file path for sharing/saving
```

### 2.1 Export Validation
Every observation is validated prior to export:
- `observation_id` must be valid UUIDv4.
- Canonical voter identity (`roll_checksum`, `epic_number` or `part_number`/`serial_number`) must match active roll.
- Field status must be a recognized statutory value.
- Originating device ID and timestamp must be intact.

---

## 3. Two-Stage Import Workflow

To prevent unexpected overwrites and silent data corruption, import is divided into two distinct stages:

### Stage 1: Inspect / Validate / Preview
```
User selects .vlsync file & enters transfer passphrase
        ↓
Container validation (magic header, protocol version, size limit)
        ↓
Key derivation & AES-256-GCM authenticated decryption
        ↓
AAD verification (detects metadata tampering or packet mismatch)
        ↓
SHA-256 integrity check against ciphertext bytes
        ↓
Replay check (queries sync_packets for packet_id)
        ↓
Roll compatibility check (active roll checksum == packet roll checksum)
        ↓
Canonical voter resolution for each observation:
    Step 1: Match (roll_checksum, epic_number)
    Step 2: Fallback (roll_checksum, part_number, serial_number)
        ↓
Conflict classification (NEW, DUPLICATE, IDENTICAL, STALE, CONCURRENT, VOTER_NOT_FOUND)
        ↓
Generate ImportPreview model (NO LIVE DATABASE MODIFICATION)
        ↓
Render iOS-style Import Preview UI to user
```

### Stage 2: Commit
```
User reviews preview and confirms commit
        ↓
Authorize Role (MANAGER or ADMIN required)
        ↓
Open atomic database transaction
        ↓
1. Insert accepted observations into field_observations (append-only)
2. Update materialized state in field_status for clean/accepted observations
3. Insert unresolved concurrent observations into sync_conflicts
4. Record SYNC_IMPORT_COMMITTED audit log entry
5. Record packet in sync_packets with COMMITTED status
        ↓
Commit transaction (Rollback completely on any failure)
        ↓
Refresh UI and clear temporary memory/buffers
```

---

## 4. Replay Protection & Packet States

Packets are tracked in the `sync_packets` table with the following lifecycle states:
- `RECEIVED`: File container parsed and authenticated.
- `VALIDATED`: Metadata and observations validated.
- `PREVIEWED`: Preview generated and presented to user.
- `COMMITTED`: Accepted records successfully merged.
- `REJECTED`: Blocked due to roll mismatch or tampering.
- `FAILED`: Decryption failure or corrupted payload.

If a `packet_id` has already been `COMMITTED`, subsequent import attempts immediately return `ALREADY_IMPORTED` without reprocessing or re-inserting records.

---

## 5. Security & Sensitive Data Handling

- **Passphrase Lifecycle**: User-entered passphrases exist solely in transient memory during key derivation and are never persisted, stored in preferences, or logged to disk.
- **Temporary Plaintext**: Decrypted payloads are processed in memory and never written to permanent disk storage.
- **Audit Logs**: Record packet ID, timestamps, user ID, device ID, and record counts; never contain sensitive contact numbers or passphrases.

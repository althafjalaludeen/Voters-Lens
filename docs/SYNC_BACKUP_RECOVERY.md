# VoterLens — Backup & Disaster Recovery Architecture

## 1. Overview

VoterLens implements an offline encrypted backup architecture using the same transport format and cryptographic engine as field synchronization. This guarantees that backups are authenticated, tamper-evident, and version-bound.

## 2. Backup Classifications

VoterLens defines two distinct, non-overlapping backup types:

### 2.1 Type A: Gazette Snapshot
- **Contents**: Official immutable roll baseline (`roll_versions`, official metadata, statutory roll checksum).
- **Purpose**: Archival snapshot of the verified official electoral register as issued by election authorities.
- **Immutability Guarantee**: Strictly read-only; contains zero field observations or operational data.

### 2.2 Type B: Field Delta Backup
- **Contents**:
  - `field_observations` (complete append-only observation stream)
  - `field_status` (materialized state)
  - `sync_conflicts` (pending and resolved conflict records)
  - `audit_logs` (security and status transition audit events)
- **Purpose**: Preserves all localized field work and supervisor decisions across devices.

## 3. Container Packaging

Both backup types are packaged into encrypted `.vlsync` containers:
- **AES-256-GCM** encryption with PBKDF2-HMAC-SHA256 key derivation.
- AAD binds the backup type, packet ID, device ID, and roll checksum.
- Cryptographic integrity verification via SHA-256 digest.

## 4. Restore Safety & Invariants

Restoring a backup adheres to strict safety invariants:

1. **Roll Compatibility Enforcement**:
   - Before restoring any field delta backup, the active roll's checksum is compared against the backup's `roll_checksum`.
   - If the checksums do not match, the restore operation is **strictly blocked** with `ROLL_MISMATCH` to prevent corrupting state across different electoral roll versions.
2. **Official Data Protection**:
   - Restoring a field delta backup never modifies statutory voter records in the `voters` table.
3. **Audit Continuity**:
   - The restore operation records an audit event documenting the restore timestamp, user ID, device ID, and restored observation count.

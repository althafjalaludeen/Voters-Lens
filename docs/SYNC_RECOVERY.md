# VoterLens — Synchronization Recovery & Backup Strategy

## 1. Backup Philosophy: Roll Independence

A critical hazard in electoral roll applications is restoring an entire database backup that accidentally overwrites or reverts the official statutory electoral roll.

VoterLens implements a **Two-Tier Backup Architecture**:

```
┌─────────────────────────────────────────────────────────────┐
│ TIER 1: STATUTORY ELECTORAL ROLL SNAPSHOT                    │
│   - Captured once at initial gazette publication import.    │
│   - Validated against official election commission hash.    │
│   - Immutable and permanently archived.                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ TIER 2: LOCAL FIELD DATA DELTA BACKUP                       │
│   - Contains: field_observations, field_status_history,     │
│     sync_conflicts, audit_logs.                             │
│   - Excludes: bulk voter records, PDFs, images.             │
│   - Compact (< 500 KB for 1,000+ observations).             │
│   - Can be exported as a standard encrypted sync packet!    │
└─────────────────────────────────────────────────────────────┘
```

By using the synchronization packet format as the native format for field data backups, restoring a backup uses the exact same validated, conflict-aware, non-destructive import pipeline.

---

## 2. Recovery Scenarios (Scenarios A through F)

---

### Scenario A: Local Database Corrupted
* **Failure Mode**: Flash storage corruption, filesystem bad sectors, or improper storage unmount causes SQLite database corruption.
* **Recovery Procedure**:
  1. Initialize fresh local database using standard migration routines (`create_tables()`).
  2. Re-import official electoral roll PDF/gazette from authorized source to establish the immutable `voters` baseline with matching `roll_checksum`.
  3. Replay recent encrypted sync packets or field backup packets through the 14-stage import pipeline.
  4. The system materializes all verified observations and historical audit trails accurately.

---

### Scenario B: Import Interrupted (Power Loss / USB Unplugged Mid-Transfer)
* **Failure Mode**: The device loses battery power, crashes, or the USB drive is abruptly yanked out during Stage 10 of the import.
* **Recovery Procedure**:
  1. **SQLite WAL Atomic Rollback**: All database modifications in Stages 8–13 occur within an explicit SQLite transaction (`session.begin()`).
  2. Because the transaction was uncommitted, SQLite's Write-Ahead Log automatically discards uncommitted journal pages upon reopening.
  3. Zero partial or corrupt records persist in `field_observations` or `field_status`.
  4. The operator simply re-inserts the drive and runs the import again.

---

### Scenario C: Application Crashes During Sync
* **Failure Mode**: Out-of-memory exception or OS termination of the VoterLens process while processing a packet.
* **Recovery Procedure**:
  1. On restart, `AppDatabase.open()` executes standard SQLite crash recovery, cleaning uncommitted locks.
  2. The packet's `packet_id` was never committed as `IMPORTED`, so subsequent re-import attempts are not falsely marked as duplicates.
  3. Audit log records the event upon subsequent inspection.

---

### Scenario D: Device Lost or Destroyed
* **Failure Mode**: A physical phone or tablet is dropped in water or misplaced in the field.
* **Recovery Procedure**:
  1. **Revocation**: The supervisor marks the lost unit's `device_id` as untrusted in the `trusted_devices` table.
  2. **Data Recovery**: Because the lost device regularly exported sync packets to the supervisor console, all observations up to the last transfer are safely preserved in the supervisor database.
  3. **Replacement Provisioning**: A replacement device is provisioned with a fresh `device_id`, paired with the supervisor, and loaded with the latest field state via an export packet.

---

### Scenario E: Wrong Packet Imported (Operator Error)
* **Failure Mode**: An operator mistakenly imports a sync packet containing bad observations or unintended test data.
* **Recovery Procedure**:
  1. **Audit Traceability**: Every imported observation records the `packet_id` and origin timestamp in `field_observations` and `field_status_history`.
  2. **Tombstone Revocation**: An administrator can execute an observation revocation for the specific `packet_id` or author.
  3. The `is_revoked` flag is set on affected observations, and the materialized `field_status` reverts to prior verified observations.
  4. The official `voters` records remain completely untouched throughout.

---

### Scenario F: Old Backup Restored
* **Failure Mode**: A well-meaning operator restores an outdated SQLite file from last month onto an active field unit.
* **Recovery Procedure**:
  1. When the restored device connects to peer devices or imports recent sync packets, the `ConflictEngine` identifies that incoming observations are newer than the old restored state.
  2. Newer observations cleanly supersede the restored outdated records.
  3. Any conflicting diverged records are flagged into the Review Queue for supervisor inspection.

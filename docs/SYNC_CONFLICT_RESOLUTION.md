# VoterLens — Synchronization Conflict Classification & Resolution

## 1. Principles of Conflict Resolution

VoterLens operates in decentralized election field environments where multiple workers may observe the same voter at different times. The conflict engine adheres to three core rules:

1. **No Naive Last-Write-Wins (LWW)**: Timestamps alone never silently overwrite concurrent divergent observations.
2. **Preserve Complete History**: All valid observations are appended to `field_observations`, preserving provenance even when an observation is stale or superseded.
3. **Supervisor-Driven Resolution**: When observations diverge concurrently, human supervisors decide the materialized state.

---

## 2. Classification Hierarchy

During Stage 1 of import, each observation in the packet is evaluated against local state:

| Classification | Condition | Materialization Action | Observation Store Action |
| :--- | :--- | :--- | :--- |
| **NEW** | No local observation exists for voter | Immediately updates `field_status` | Inserted into `field_observations` |
| **DUPLICATE** | Exact same `observation_id` exists locally | Ignored (No-op) | Ignored |
| **IDENTICAL** | Different `observation_id`, identical field status, phone, notes | Ignored (No-op) | Appended to `field_observations` |
| **STALE** | Incoming observation timestamp is strictly older than latest local observation | Ignored (No rollback of current status) | Appended to `field_observations` for audit |
| **CONCURRENT** | Incoming observation has different status within conflict window or diverges from local | Escalated to `sync_conflicts` queue | Appended to `field_observations` |
| **VOTER_NOT_FOUND** | Voter cannot be resolved via EPIC or (Part, Serial) | Rejected | Ignored |
| **ROLL_MISMATCH** | Packet roll checksum differs from local active roll | Entire packet blocked | None |

---

## 3. Conflict Resolution Actions

When a concurrent conflict is created, it appears in the Conflict Center. Supervisors have three resolution actions:

### 3.1 Keep Local (`ACCEPT_A`)
- Retains local observation status in `field_status`.
- Marks conflict in `sync_conflicts` as `RESOLVED` with resolution strategy `ACCEPT_LOCAL`.
- Emits audit event `SYNC_CONFLICT_RESOLVED`.

### 3.2 Accept Imported (`ACCEPT_B`)
- Updates `field_status` to match the imported observation status, phone, and notes.
- Marks conflict as `RESOLVED` with strategy `ACCEPT_IMPORTED`.
- Appends status transition to `field_status_history`.
- Emits audit event `SYNC_CONFLICT_RESOLVED`.

### 3.3 Merge (`MERGE`)
- Evaluates field-level differences:
  - Status (Local vs Imported)
  - Phone Number (Local vs Imported)
  - Notes (Local vs Imported)
- If both sides changed the same field to conflicting non-empty values, automatic merge is disallowed, and the supervisor must make an explicit choice.
- When valid, a merged state is materialized into `field_status` and an audit entry is recorded.

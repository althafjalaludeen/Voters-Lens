# VoterLens — Synchronization Conflict & Reconciliation Model

## 1. Principles of Offline Reconciliation

In an offline multi-device field operational setting, conflicting observations are normal and expected occurrences:
* Worker A in the morning interviews a resident who says their brother is `AWAY` in Ernakulam.
* Worker B in the evening speaks with a neighbor who claims the brother is permanently `ABROAD` in Dubai.
* Worker C reports an elderly elector has `REPORTED_DECEASED`.

A naive distributed algorithm like **"Last-Write-Wins" (LWW)** or **"Latest Timestamp Wins"** is dangerous and fundamentally flawed in election tracking:
1. **Clock Skew & Drift**: Offline phones frequently have clock drifts of minutes or hours, or may have dead batteries that reset device clocks.
2. **Intentional Clock Manipulation**: Any rogue operator could set their device date to the future to permanently win conflicts.
3. **Loss of Critical Intelligence**: Overwriting an earlier observation destroys context, contact numbers, and notes that may be vital for official verification.

Therefore, VoterLens adopts an **Evidence-Preserving Conflict Model**:
> *"Never silently discard an observation. Record all evidence, preserve historical provenance, and escalate divergent field reports to human supervisor review."*

---

## 2. Taxonomy of Synchronization Conflicts

The sync engine evaluates every observation against the active local database and classifies it into one of nine explicit categories:

| Conflict Category | Severity | Description | System Action |
| :--- | :--- | :--- | :--- |
| **`DUPLICATE`** | None | Exact `observation_id` is already stored locally. | **Idempotent Skip**: No mutation to database state; logged as skipped. |
| **`IDENTICAL`** | None | Different `observation_id`, but status, phone, and notes match existing state exactly. | **Merge**: Record incoming event in event store for provenance; no status change. |
| **`STALE`** | Low | Observation's `created_at` is earlier than the latest accepted observation, and it does not explicitly supersede it. | **Historical Record**: Append to event store for historical record; do not alter current `field_status`. |
| **`CONCURRENT`** | High | Different devices report different verification statuses for the same voter without an explicit superseding link. | **Conflict Raised**: Append event to event store; record row in `sync_conflicts`; tag voter as `NEEDS_REVIEW`. |
| **`ROLL_MISMATCH`** | Critical | Packet's `roll_checksum` does not match the active local roll checksum. | **Packet Abort**: Entire import aborted (`RollMismatchError`); audit log recorded. |
| **`VOTER_NOT_FOUND`**| Medium | The observation's EPIC and part/serial do not exist in the active roll. | **Unmatched Record**: Record conflict in `sync_conflicts`; do not create orphan status. |
| **`INVALID_OBSERVATION`**| Medium | Malformed payload, invalid status enum string, or unparseable timestamp. | **Validation Rejection**: Reject observation; record audit warning. |
| **`PERMISSION_CONFLICT`**| High | Observation author lacked permission tier (e.g. VIEWER attempting to submit changes). | **Authorization Failure**: Discard observation; record security audit log. |
| **`SCHEMA_VERSION_MISMATCH`**| Critical | Packet protocol version is unsupported by the local client. | **Packet Abort**: Reject packet gracefully (`UnsupportedProtocolVersionError`). |

---

## 3. Clock Skew & Timestamp Trust Model

Because device clocks cannot be unconditionally trusted, timestamps are treated as **supporting evidence, not absolute authority**:

```
Observation Metadata:
├── created_at     (Claimed timestamp from origin device)
├── origin_device  (Identity of originating device)
└── received_at    (Local UTC timestamp when packet was accepted into this database)
```

### Clock Skew Rules:
1. **Timezone Normalization**: All timestamps are parsed and converted to ISO 8601 UTC prior to any comparison.
2. **Future Timestamp Clamping**: If an incoming observation's `created_at` exceeds the receiver's local clock by more than 24 hours, it is flagged as `CLOCK_ANOMALY` and routed to the supervisor queue.
3. **Explicit Superseding Links**: When an operator edits an existing observation on Device A, the system records `supersedes_id = <previous_observation_id>`. When Device B receives this, it respects the causal chain rather than relying purely on clock timestamps.

---

## 4. Supervisor Review & Resolution Workflow

When a `CONCURRENT` conflict is detected:

1. **Both Events Preserved**: Both Device A and Device B observations are inserted into `field_observations`.
2. **Conflict Queue Registration**: An entry is created in `sync_conflicts` with `resolution_status = PENDING_REVIEW`.
3. **UI Highlighting**: The voter's `field_status.review_status` is updated to `NEEDS_REVIEW`, triggering the Review Queue badge in the mobile/desktop UI.
4. **Supervisor Decision**: A manager or administrator inspects the conflict details on the Review Queue screen:

```
┌─────────────────────────────────────────────────────────────┐
│ CONFLICT RESOLUTION: Voter KL/14/098/123456 (George Thomas)  │
├─────────────────────────────────────────────────────────────┤
│ Observation A (Local Device):                               │
│ Status: AWAY • Operator: anil • Time: 10:00 AM              │
│ Notes: "Working in Ernakulam"                               │
├─────────────────────────────────────────────────────────────┤
│ Observation B (Incoming from Unit-04):                      │
│ Status: REPORTED_DECEASED • Operator: suresh • Time: 10:05 AM│
│ Notes: "Reported deceased by ward member"                   │
├─────────────────────────────────────────────────────────────┤
│ Resolution Choices:                                         │
│ [ Accept A (Away) ]   [ Accept B (Deceased) ]   [ Custom ]  │
└─────────────────────────────────────────────────────────────┘
```

* **Action 1: Accept A**: Retains current status; marks conflict `RESOLVED_ACCEPTED_A`.
* **Action 2: Accept B**: Materializes observation B into `field_status`; appends entry to `field_status_history`; marks conflict `RESOLVED_ACCEPTED_B`.
* **Action 3: Custom / Re-visit**: Supervisor inputs updated verified status (e.g. following official phone call or death certificate inspection).

Once resolved, if no other unresolved conflicts remain for the voter, `review_status` is cleared to `REVIEWED`.

---

## 5. Deletion & Tombstone Revocation Model

In distributed offline synchronization, **physical deletion (`DELETE FROM table`) is strictly prohibited**:
* If Device A deletes a record physically, and then syncs with Device B, Device B cannot distinguish whether Device A deleted the record or simply never had it. Device B would re-inject the deleted observation!

### Tombstone Architecture:
To withdraw or revoke an inaccurate observation:
1. An observation is flagged with `is_revoked = True`.
2. The reason is recorded in `revocation_reason` (e.g. *"Entered for wrong elector by typographical error"*).
3. The sync engine propagates this tombstone observation to peer devices.
4. Peers receiving the tombstone mark their local copy as revoked without deleting historical audit entries.
5. If the revoked observation was the active status in `field_status`, the materialized view falls back to the prior valid observation or resets to `NO_ISSUE`.

# VOTERLENS — APPLICATION ARCHITECTURE (PHASE 2)

## 1. Architectural Overview

VoterLens is designed as an **offline-first, localized electoral-roll verification and exploration system**.
The architecture strictly enforces separation of concerns between **Official Immutable Electoral Records** and **Local Mutable Field Observations**, mediated by a unified service and repository layer designed for direct integration with the future Flutter UI.

```
                    VOTERLENS APPLICATION
                              │
    ┌─────────────────────────┴─────────────────────────┐
    │                                                   │
OFFICIAL DATA (READ-ONLY)                     LOCAL DATA (EDITABLE)
• Published Electoral Roll Snapshots          • Field Observations (NO_ISSUE, AWAY, etc.)
• 524 Verified Voter Records (Kerala Roll)    • Resident Contact Numbers & Notes
• Official Polling Station & Part Info        • Review Queue Flags & Resolutions
• Card Layout & Photo Geometry                • Append-Only Transition Audit History
    │                                                   │
    └─────────────────────────┬─────────────────────────┘
                              │
                    REPOSITORY LAYER
        [ElectoralRollRepository, VoterRepository,
         FieldStatusRepository, AuditRepository,
         ElectoralAreaRepository, UserRepository]
                              │
                    SERVICE & LOGIC LAYER
        [RollService, SearchService, VoterService,
         FieldStatusService, ReviewService, AuditService]
                              │
                    SECURITY & RBAC CONTEXT
        [Admin, Manager, Field User, Viewer Permissions]
                              │
                    APPLICATION INTERFACE (DTOs)
        [VoterSearchResult, VoterDetail, HouseholdGroup,
         AreaStatistics, VoterListResponse, ComparisonReport]
                              │
                    FUTURE FLUTTER UI
        (No Direct SQL Execution — Uses Service Interfaces)
```

---

## 2. Layer Separation & Clean Contracts

### 2.1 The Two Fundamental Data Domains

1. **Official Electoral Roll Data (Strictly Read-Only)**:
   - Contains extracted official values: `epic_number`, `name`, `relative_name`, `relative_type`, `house_number`, `age`, `gender`, `part_number`, `serial_number`, `polling_station_name`, and `photo_path`.
   - Normalizers generate `normalized_name`, `normalized_relative_name`, and `normalized_house_number` for search indexing without altering original text.
   - Immutability is enforced at the database repository layer via `ImmutableElectoralRollError` exceptions if any update or deletion is attempted on an active roll.

2. **Local Field Information (Audited and Editable)**:
   - Contains localized data: `status` (`NO_ISSUE`, `AWAY`, `ABROAD`, `REPORTED_DECEASED`, `UNABLE_TO_VERIFY`), `phone_number`, `notes`, `review_status`, and `review_reasons`.
   - Stored in a separate table (`field_status`) referencing `voters.id`.
   - Modifying a field status never touches or updates the official `voters` table.
   - Every single status modification triggers an append-only audit entry in `field_status_history`.

---

## 3. Data Transfer Objects (DTO) Contract

The future Flutter client communicates exclusively with strongly-typed DTOs, isolating the UI from database schemas and SQL dialect specifics:

* **`VoterSearchResult`**:
  Compact representation for lazy-loaded list views, virtual lists, and search queries. Exposes voter ID, name, relative name, EPIC, house, age, gender, part, serial, polling station, photo availability, field status badge, and phone number.
* **`VoterDetail`**:
  Full structural split containing:
  - `official`: `VoterOfficialDTO` (all immutable electoral roll parameters, verified photo status).
  - `field`: `VoterFieldDTO` (field status, phone, notes, review status, reviewer, and full chronological history).
* **`HouseholdGroup`**:
  Grouped representation by normalized house number while preserving original house strings, containing household voter counts and constituent voter lists.
* **`AreaStatistics`**:
  High-level constituency and polling part aggregations (total voters, gender distribution, field status counts, review queue counts).
* **`VoterListResponse`**:
  Standardized paginated envelope (`items`, `total_count`, `page`, `page_size`, `total_pages`, `has_next`, `has_prev`).

---

## 4. Key Application Workflows

### 4.1 Cold Startup to Full Voter List
```
App Launch
  ↓
Check ElectoralAreaConfig (Local SQLite)
  ↓
Resolve Active RollVersion (status = ACTIVE)
  ↓
Query Full Voter List (Default: serial_number ASC within active part)
  ↓
Paginated Return (50 items/page, < 3 ms retrieval)
```

### 4.2 Field Verification Submission
```
Field Operator selects Voter
  ↓
Service checks UPDATE_FIELD_STATUS permission
  ↓
FieldStatusService.set_status(voter_id, new_status, notes)
  ↓
1. Update field_status table
2. Append to field_status_history
3. Log non-sensitive event in audit_logs
4. Keep official Voter record untouched
```

### 4.3 Manual Review Queue
```
Importer / Auto-Detector scans records
  ↓
Flag anomalies (Missing EPIC, Missing relative, Missing house, Invalid age)
  ↓
Set review_status = NEEDS_REVIEW with comma-separated reasons
  ↓
Supervisor inspects Review Queue
  ↓
ReviewService.mark_as_reviewed(voter_id, reviewer, notes)
  ↓
Record marked REVIEWED with audit logging
```

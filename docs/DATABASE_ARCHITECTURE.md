# VOTERLENS — DATABASE ARCHITECTURE (PHASE 2)

## 1. Conceptual Database Layers

The local SQLite database (`data/voterlens.db`) is structured into eight conceptual layers:

```
┌────────────────────────────────────────────────────────────────────────┐
│ 1. Roll Management: roll_versions, electoral_area_configs              │
├────────────────────────────────────────────────────────────────────────┤
│ 2. Official Voter Records: voters (Immutable electoral data)           │
├────────────────────────────────────────────────────────────────────────┤
│ 3. Local Field Information: field_status (Status, Phone, Notes)        │
├────────────────────────────────────────────────────────────────────────┤
│ 4. Field-Status History: field_status_history (Append-only audit)      │
├────────────────────────────────────────────────────────────────────────┤
│ 5. Users / Operators: users (RBAC access tiers)                        │
├────────────────────────────────────────────────────────────────────────┤
│ 6. Audit Logs: audit_logs (System & administrative actions)            │
├────────────────────────────────────────────────────────────────────────┤
│ 7. Import Records: import_reports (Validation summaries)               │
├────────────────────────────────────────────────────────────────────────┤
│ 8. Search / Indexing Metadata: voters_fts (FTS5 virtual index)         │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Table Schemas & Relational Integrity

### 2.1 `roll_versions`
Tracks lifecycle of official published electoral rolls.
* `id` VARCHAR(36) PRIMARY KEY
* `state` VARCHAR(100) NOT NULL
* `district` VARCHAR(100) NOT NULL
* `assembly_constituency` VARCHAR(150) NOT NULL
* `roll_name` VARCHAR(200) NOT NULL
* `roll_type` VARCHAR(50) DEFAULT 'GENERAL'
* `publication_date` VARCHAR(50)
* `source_reference` VARCHAR(255)
* `imported_at` TIMESTAMP WITH TIME ZONE
* `record_count` INTEGER DEFAULT 0
* `status` ENUM ('IMPORTING', 'ACTIVE', 'ARCHIVED', 'FAILED')
* `checksum_hash` VARCHAR(64)

### 2.2 `electoral_area_configs`
Stores local active area setup.
* `id` VARCHAR(36) PRIMARY KEY
* `state` VARCHAR(100) NOT NULL
* `district` VARCHAR(100) NOT NULL
* `assembly_constituency` VARCHAR(150) NOT NULL
* `selected_part_number` VARCHAR(50)
* `active_roll_id` VARCHAR(36) REFERENCES `roll_versions.id`
* `created_at`, `updated_at` TIMESTAMP WITH TIME ZONE

### 2.3 `voters` (Official Data — Strictly Immutable)
* `id` VARCHAR(36) PRIMARY KEY
* `roll_version_id` VARCHAR(36) NOT NULL REFERENCES `roll_versions.id`
* `serial_number` INTEGER NOT NULL
* `epic_number` VARCHAR(50) NOT NULL
* `name` VARCHAR(255) NOT NULL
* `normalized_name` VARCHAR(255) NOT NULL
* `relative_name` VARCHAR(255) NOT NULL
* `normalized_relative_name` VARCHAR(255) NOT NULL
* `relative_type` VARCHAR(50) DEFAULT 'OTHER'
* `house_number` VARCHAR(100) NOT NULL
* `normalized_house_number` VARCHAR(100) NOT NULL
* `age` INTEGER NOT NULL
* `gender` VARCHAR(20) NOT NULL
* `part_number` VARCHAR(50) NOT NULL
* `section_number` VARCHAR(50)
* `section_name` VARCHAR(255)
* `polling_station_name` VARCHAR(255)
* `polling_station_address` TEXT
* `photo_path` VARCHAR(500)
* `ocr_confidence` FLOAT
* `raw_data` TEXT
* `created_at` TIMESTAMP WITH TIME ZONE

### 2.4 `field_status` (Local Mutable Data)
* `id` VARCHAR(36) PRIMARY KEY
* `voter_id` VARCHAR(36) UNIQUE NOT NULL REFERENCES `voters.id`
* `status` ENUM ('NO_ISSUE', 'AWAY', 'ABROAD', 'REPORTED_DECEASED', 'UNABLE_TO_VERIFY')
* `phone_number` VARCHAR(50)
* `notes` TEXT
* `review_status` ENUM ('NOT_REVIEWED', 'NEEDS_REVIEW', 'REVIEWED')
* `review_reasons` TEXT
* `reviewed_by` VARCHAR(100)
* `reviewed_at` TIMESTAMP WITH TIME ZONE
* `reported_by` VARCHAR(100)
* `reported_at`, `updated_at` TIMESTAMP WITH TIME ZONE

### 2.5 `field_status_history` (Append-Only Audit Log)
* `id` VARCHAR(36) PRIMARY KEY
* `voter_id` VARCHAR(36) NOT NULL REFERENCES `voters.id`
* `old_status` VARCHAR(50) NOT NULL
* `new_status` VARCHAR(50) NOT NULL
* `notes` TEXT
* `changed_by` VARCHAR(100)
* `changed_at` TIMESTAMP WITH TIME ZONE

### 2.6 `users` & `audit_logs`
* `users`: `id`, `username`, `full_name`, `role` (`ADMIN`, `MANAGER`, `FIELD_USER`, `VIEWER`), `is_active`, timestamps.
* `audit_logs`: `id`, `action`, `entity_type`, `entity_id`, `performed_by`, `details` (sanitized JSON), `timestamp`.

---

## 3. Roll Version Lifecycle Rules

```
                      ┌────────────────┐
                      │   IMPORTING    │
                      └───────┬────────┘
                              │
               ┌──────────────┴──────────────┐
               │ Validation & Batch Insert   │
               ▼                             ▼
        ┌─────────────┐               ┌─────────────┐
        │   ACTIVE    │               │   FAILED    │
        └──────┬──────┘               └─────────────┘
               │
   New roll activated for area
               ▼
        ┌─────────────┐
        │  ARCHIVED   │
        └─────────────┘
```

1. **Single Active Roll Guarantee**:
   Only one roll can be `ACTIVE` for any given electoral constituency.
2. **Atomic Archival**:
   Activating a new roll transitions the existing `ACTIVE` roll to `ARCHIVED`. Existing records are never deleted.
3. **Incomplete Roll Protection**:
   Rolls with 0 records or in `FAILED` status can never be promoted to `ACTIVE`.
4. **Official Data Locking**:
   Once a roll transitions from `IMPORTING` to `ACTIVE`, all official voter records become permanently locked and immutable.

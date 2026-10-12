# VOTERLENS — OFFLINE-FIRST ARCHITECTURE (PHASE 2)

## 1. Core Product Principle

VoterLens is built upon a strict **offline-first guarantee**:
Once an electoral roll is processed and activated, normal daily operation of the application requires **zero network connectivity**.

Under normal operation, VoterLens does **NOT** require:
* Internet access
* Connection to official election commission servers
* Cloud databases or sync endpoints
* Remote image servers or CDNs
* Background phone-home analytics

```
              EXPLICIT IMPORT (ADMIN ONLY)
              [Official PDF / Scanned Roll]
                           ↓
                   LOCAL OCR & PARSE
                           ↓
                   LOCAL VALIDATION
                           ↓
              LOCAL SQLITE DATABASE & PHOTOS
                           ↓
                     LOCKED & OFFLINE
                           ↓
                NORMAL APPLICATION USAGE
     ┌─────────────────────┼─────────────────────┐
     ▼                     ▼                     ▼
VOTER LISTING       FULL-TEXT SEARCH     FIELD OBSERVATIONS
(100% Offline)       (100% Offline)        (100% Offline)
```

---

## 2. Rigorous Network Prohibition Validation

Offline integrity is enforced through automated unit tests (`tests/test_offline_guarantee.py`) that actively monkeypatch the Python `socket` module:

```python
def forbidden_socket(*args, **kwargs):
    raise RuntimeError("CRITICAL ERROR: Network access attempted during normal offline operation!")

monkeypatch.setattr(socket, "socket", forbidden_socket)
```

All standard operations execute successfully under socket-blocking conditions:
* Application startup and area configuration resolution
* Full voter listing and pagination
* Multi-criteria search (EPIC, Malayalam name, House, Gender)
* Household grouping queries
* Voter detail retrieval
* Photograph path verification and lazy byte streaming
* Field status updates and append-only history retrieval
* Review queue inspection and review completion
* Polling area statistics aggregation

---

## 3. Photograph Handling & Memory Safeguards

Voter photograph management adheres to strict memory and network constraints:

1. **Local File Storage**:
   Photographs are cropped during the import pipeline and stored locally under `photos/{roll_id}/page_{xx}_card_{yy}.jpg`.
2. **Path Verification Without Decoding**:
   The `VoterService` and search DTOs evaluate photo presence via lightweight filesystem stat calls (`Path(path).exists()`), populating `photo_available: bool` and `photo_status: "PHOTO_AVAILABLE" | "PHOTO_UNAVAILABLE"`.
3. **Lazy Image Loading**:
   Full image bytes are only read on-demand when a user inspects an individual voter detail card (`get_voter_photo_bytes`). Under no circumstances is the 524+ photo library loaded into RAM simultaneously.
4. **Fallback Representation**:
   If a photograph was absent or corrupted on the original electoral roll, the UI receives a deterministic `photo_available = False` indicator, triggering a client-side placeholder without throwing exceptions.

---

## 4. Manual Roll Update Workflow

VoterLens does **not** poll or scrape the election website automatically. Roll updates follow an explicit, administrator-authorized workflow:

```
Administrator Settings
  ↓
Electoral Roll Management
  ↓
Import New Roll Version (Select Local PDF)
  ↓
Execution of Local Pipeline
  (OCR → Normalizer → Validator)
  ↓
Validation Report Review
  (0 rejected cards, 100% card reconciliation)
  ↓
Explicit "Activate Roll" Action
  ↓
Current Active Roll is Archived; New Roll Becomes ACTIVE
```
Until this sequence is executed, the current active roll remains locked, trusted, and untouched.

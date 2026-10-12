# VOTERLENS — SECURITY & PRIVACY MODEL (PHASE 2)

## 1. Security Philosophy & Threat Model

VoterLens manages published public electoral rolls combined with sensitive local field observations.
The security architecture is designed around:
1. **Official Data Immutability**: Preventing tampering or unintentional edits to statutory electoral records.
2. **Local Data Minimization**: Collecting only authorized field verification notes and phone numbers.
3. **Data Inference Prohibition**: Explicit structural barriers preventing political profiling or religious inference.
4. **Service-Layer Access Control**: Enforcing permissions in Python logic independent of client UI controls.

---

## 2. Role-Based Access Control (RBAC)

The application defines four distinct user tiers:

```
┌─────────────┬─────────────────────────────────────────────────────────────────────────┐
│ Role        │ Permitted Capabilities                                                  │
├─────────────┼─────────────────────────────────────────────────────────────────────────┤
│ ADMIN       │ • Setup Electoral Area Configuration                                    │
│             │ • Activate, Archive, and Compare Electoral Rolls                        │
│             │ • Manage User Accounts and Roles                                        │
│             │ • View Comprehensive System Audit Logs                                  │
│             │ • All capabilities of Manager and Field User                            │
├─────────────┼─────────────────────────────────────────────────────────────────────────┤
│ MANAGER     │ • View and Search Voter Records                                         │
│             │ • Inspect and Manage the Anomaly Review Queue (`mark_as_reviewed`)      │
│             │ • Record and Update Field Observations (`set_status`, notes)            │
│             │ • Access Field Verification Audit History and Logs                      │
├─────────────┼─────────────────────────────────────────────────────────────────────────┤
│ FIELD_USER  │ • View and Search Voter Records within Assigned Area                    │
│             │ • Submit Field Observations (`NO_ISSUE`, `AWAY`, `ABROAD`, etc.)        │
│             │ • Record Verified Contact Numbers and Verification Notes                │
│             │ • Strictly prohibited from roll management or review sign-off           │
├─────────────┼─────────────────────────────────────────────────────────────────────────┤
│ VIEWER      │ • Read-only access to search and view voter lists and details           │
│             │ • Prohibited from making field observations or administrative changes   │
└─────────────┴─────────────────────────────────────────────────────────────────────────┘
```

### Granular Service-Layer Permissions
Permissions are verified inside service methods using `SecurityContext.require_permission(Permission)`:
* `Permission.MANAGE_ROLLS`
* `Permission.ACTIVATE_ROLL`
* `Permission.MANAGE_USERS`
* `Permission.VIEW_AUDIT_LOGS`
* `Permission.VIEW_VOTERS`
* `Permission.SEARCH_VOTERS`
* `Permission.UPDATE_FIELD_STATUS`
* `Permission.REVIEW_RECORDS`

---

## 3. Data Privacy & Ethical Boundaries

Electoral datasets contain personal identifiable information. VoterLens strictly adheres to data minimization:

### 3.1 Strict Prohibition on Sensitive Inferences
* **Religion & Caste**: The application code contains **zero inference logic**. Religion is never inferred from names, surnames, house names, localities, or languages.
* **Political Preference & Targeting**: VoterLens does **not** implement turnout prediction, likelihood-to-vote scoring, or political party affiliation modeling.
* **Household Grouping Scope**: Household grouping queries group voters by normalized house number as an organizational convenience; the data layer explicitly does not assume or assert verified familial relationships.

---

## 4. Audit Trail & Log Sanitization

To balance accountability with privacy, the `AuditService` implements automated log sanitization:
1. **Never Log Sensitive Personal Voter Details**:
   Audit entries record actions (e.g., `FIELD_STATUS_CHANGED`, `ROLL_ACTIVATED`) with entity IDs, operator usernames, and previous/new status values.
2. **Stripping Personal Data Fields**:
   Names, relative names, photo paths, and raw voter dictionaries are automatically stripped from audit payload objects before persisting to `audit_logs`.
3. **Append-Only History**:
   Field status transitions stored in `field_status_history` are strictly append-only, preserving a permanent chronological record of observations without mutating official records.

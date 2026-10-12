# VoterLens — Synchronization Threat Model & Security Analysis

## 1. Threat Modeling Overview & Assumptions

The VoterLens synchronization layer is engineered for field use in local election operational environments. Because the system operates 100% offline, traditional cloud access control, TLS certificates, and centralized identity providers cannot be assumed.

### Core Assumptions:
* Physical devices (smartphones, tablets, laptops) may be carried outdoors by ad-hoc field operators.
* Transfer media (USB drives, SD cards, local file shares, direct P2P) traverse untrusted physical custody.
* Adversaries may range from accidental mishandlers and inquisitive third parties to malicious political adversaries seeking to disrupt field tracking, inject false voter statuses, or extract voter contact numbers.
* The statutory electoral roll itself is immutable; attacks focus primarily on intercepting, manipulating, or corrupting local field observations.

---

## 2. In-Depth Analysis of Mandatory Threats (Threats 1–12)

---

### Threat 1: Unauthorized Person Obtains a Transfer File
* **Attack Scenario**: A USB flash drive or exported `.vlsync` file is dropped or intercepted by an unauthorized individual.
* **Risk**: Exposure of electors' contact phone numbers, relocation notes, or field verification statuses.
* **Mitigation**:
  * **AES-256-GCM Authenticated Encryption**: The observation payload is encrypted using a 256-bit symmetric key derived via PBKDF2 (100,000 iterations of HMAC-SHA256) with a unique 16-byte cryptographic salt.
  * **Zero Plaintext Observations**: No voter names, phone numbers, or field observations appear in plaintext within the envelope. An attacker without the transfer passphrase / pairing secret sees only high-entropy pseudorandom bytes.
  * **Key Non-Persistence in Packets**: Keys are never embedded in the packet file, source code, or unencrypted metadata.

---

### Threat 2: Transfer File is Modified (Tampering / Bit-Flipping)
* **Attack Scenario**: An adversary modifies values in the packet envelope or payload (e.g. altering voter statuses from `AWAY` to `REPORTED_DECEASED`, or changing `source_device_id`).
* **Risk**: False electoral intelligence, unwarranted disenfranchisement alarms, or corruption of local database state.
* **Mitigation**:
  * **GCM 128-bit Authentication Tag**: Any modification to the ciphertext triggers an `AuthenticationError` during decryption.
  * **Additional Authenticated Data (AAD) Binding**: Critical envelope fields (`packet_id`, `source_device_id`, `roll_version_id`, `roll_checksum`, `observation_count`) are bound to the cryptographic tag. Changing any cleartext header attribute breaks tag validation.
  * **Atomic Discard**: Decryption failure aborts the entire pipeline before any database writes occur.

---

### Threat 3: Old Packet is Replayed (Replay Attack)
* **Attack Scenario**: An adversary captures a valid sync packet from week 1 and attempts to re-import it in week 3 to revert newer field observations.
* **Risk**: Stale field observations overwrite accurate, verified intelligence.
* **Mitigation**:
  * **Packet UUID & History Tracking**: Each packet has a globally unique `packet_id`. Once processed, it is recorded in `sync_packets`.
  * **Temporal Conflict Detection**: In the `ConflictEngine`, observations with timestamps earlier than the current accepted state are classified as `ConflictType.STALE`. They are recorded in the append-only event store for provenance, but **never** overwrite newer materialized statuses in `field_status`.

---

### Threat 4: Same Packet Imported Multiple Times
* **Attack Scenario**: An operator accidentally imports the same USB transfer file twice on the same device.
* **Risk**: Duplicated observations, inflated counter stats, or corrupted historical timelines.
* **Mitigation**:
  * **Strict Idempotency**: Stage 7 checks `sync_packets` for `(packet_id, direction=IMPORT, status=IMPORTED)`.
  * **Immediate Safe Return**: Re-import returns `IDEMPOTENT_SKIPPED` with `imported_count: 0`, performing zero writes to `field_status` or `field_observations`.

---

### Threat 5: Packet Belongs to Another Electoral Roll (Cross-Roll Injection)
* **Attack Scenario**: A worker operating in Constituency A receives a USB packet created by workers in Constituency B and mistakenly attempts to import it.
* **Risk**: Applying observation statuses to incorrect voters who happen to share common names or serial numbers.
* **Mitigation**:
  * **Cryptographic Roll Checksum Binding**: The packet specifies `roll_checksum` (SHA-256 hash of the entire statutory roll).
  * **Pre-Execution Checksum Matching**: In Stage 5, the receiver verifies `packet.roll_checksum == local.active_roll.checksum_hash`.
  * If the checksums do not match byte-for-byte, import is blocked immediately (`RollMismatchError`) and logged as `SYNC_PACKET_REJECTED`.

---

### Threat 6: Malicious Device Sends Fabricated Observations
* **Attack Scenario**: A rogue or compromised field worker unit generates fabricated voter observations (e.g. falsely marking 200 electors as `REPORTED_DECEASED`).
* **Risk**: Widespread data poisoning and disruption of field operations.
* **Mitigation**:
  * **Peer Pairing / Trusted Device Gate**: Optional setting requiring `source_device_id` to exist in `trusted_devices`.
  * **Review Queue Routing**: Any observation marking a voter as `REPORTED_DECEASED` or conflicting with local state is flagged with `ReviewStatusType.NEEDS_REVIEW`.
  * **Attribution & Provenance**: Every observation permanently preserves `created_by`, `origin_device_id`, and `created_at`. Rogue operators can be immediately identified and their specific `origin_device_id` revoked.

---

### Threat 7: Device Clock is Manipulated (Clock Skew / Forgery)
* **Attack Scenario**: A worker's device clock is intentionally set to the future (e.g. year 2030) or past (year 2020) to force their observations to win or lose conflict evaluations.
* **Risk**: Subversion of "latest timestamp wins" resolution rules.
* **Mitigation**:
  * **No Blind "Latest Timestamp Wins"**: Divergent concurrent observations between different devices are classified as `ConflictType.CONCURRENT` and escalated to human supervisor review.
  * **Dual Timestamp Tracking**: Every event records both origin `created_at` and receiving `received_at`. Discrepancies between local arrival time and claimed creation time are flagged as clock-skew anomalies.

---

### Threat 8: Operator Loses Device (Device Theft / Misplacement)
* **Attack Scenario**: A field tablet or phone running VoterLens is lost or stolen in the field.
* **Risk**: Unauthorized extraction of local database or unauthorized generation of sync packets.
* **Mitigation**:
  * **Device De-Authorization / Revocation**: Supervisors can mark the lost device's `device_id` as `is_trusted = False` in `trusted_devices`. Future packets from that device are rejected across all operational units.
  * **OS-Level Storage Encryption**: SQLite files and transfer keys reside in application sandboxed storage encrypted by the OS keystore.

---

### Threat 9: Encryption Key is Lost
* **Attack Scenario**: Operators forget the transfer passphrase or lose the pairing QR code before an import.
* **Risk**: Inability to import collected observations.
* **Mitigation**:
  * **Non-Destructive Failure**: Decryption failure leaves both the database and the transfer packet completely untouched.
  * **Re-Export Capability**: The exporting device retains the local `field_observations` in its database and can re-export a fresh packet using a newly generated supervisor passphrase at any time.

---

### Threat 10: User Accidentally Imports an Outdated Packet
* **Attack Scenario**: An operator finds an old backup packet from two weeks ago and accidentally imports it over today's data.
* **Risk**: Rolling back recent progress.
* **Mitigation**:
  * **Stale Classification**: Observations in the packet with timestamps older than current observations are labeled `ConflictType.STALE`.
  * **Non-Overwriting Event Ingestion**: They are appended to the historical event log but do not mutate the materialized `field_status`.

---

### Threat 11: Sensitive Packet is Copied to an Unauthorized Computer
* **Attack Scenario**: A packet file is copied to an unmanaged desktop or laptop outside the campaign.
* **Risk**: Data mining of voter notes and phone numbers.
* **Mitigation**:
  * **High-Workfactor PBKDF2**: Deriving the key requires 100,000 rounds of HMAC-SHA256, rendering brute-force dictionary attacks computationally prohibitive.
  * **Minimal Payload Minimization**: Packets contain only discrete observation delta fields—no complete voter lists, addresses, or gazette PDFs.

---

### Threat 12: Conflicting Field Observations are Silently Overwritten
* **Attack Scenario**: Device A records voter as `AWAY`, while Device B records voter as `ABROAD`. Without notice, one overwrites the other.
* **Risk**: Loss of critical local knowledge; operational confusion.
* **Mitigation**:
  * **Conflict Engine Guarantee**: Divergent observations generate a `SyncConflict` record.
  * **Dual Event Retention**: Both records are saved in `field_observations`.
  * **UI Review Flagging**: The voter is tagged with `NEEDS_REVIEW` and surfaced on the Review Queue screen for explicit supervisor decision.

---

## 3. Four-Tier Security Level Model

```
┌────────────────────────────────────────────────────────────────────────┐
│ LEVEL 4: MALICIOUS OPERATOR                                            │
│   Mitigations: RBAC permissions + supervisor review queue +            │
│   immutable audit logging + observation provenance attribution.        │
├────────────────────────────────────────────────────────────────────────┤
│ LEVEL 3: UNAUTHORIZED / ROGUE DEVICE                                   │
│   Mitigations: Trusted device registry + device-level revocation +     │
│   out-of-band pairing secrets.                                         │
├────────────────────────────────────────────────────────────────────────┤
│ LEVEL 2: UNAUTHORIZED MODIFICATION & INTERCEPTION                     │
│   Mitigations: AES-256-GCM authenticated encryption + AAD header       │
│   binding + 128-bit authentication tag verification.                   │
├────────────────────────────────────────────────────────────────────────┤
│ LEVEL 1: ACCIDENTAL CORRUPTION & MISMATCH                              │
│   Mitigations: SHA-256 roll checksum matching + protocol version       │
│   checks + JSON schema validation + SQLite atomic transactions.        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Phase 4A Security Boundary & Limitations

### What Phase 4A Protects Against:
* Accidental file corruption and partial transfer reads.
* Cross-roll data pollution between differing constituencies or versions.
* Unauthorized viewing or eavesdropping of packet contents in transit.
* Malicious modification or tampering of envelope or payload bytes.
* Replay of identical or outdated packets.
* Silent data loss during concurrent conflicting field reports.
* Accidental modification of official statutory voter records.

### What Phase 4A Does Not Cover (Requires Future Operational / Physical Controls):
* Physical hardware compromise / root extraction of an active unlocked device.
* Malicious operators with verified supervisor credentials deliberately approving inaccurate field observations.
* Social engineering attacks to obtain the supervisor transfer passphrase.

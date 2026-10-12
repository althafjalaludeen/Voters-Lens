import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/sync_models.dart';
import '../database/app_database.dart';

class VLSyncCrypto {
  static const int pbkdf2Iterations = 100000;
  static const int saltSizeBytes = 16;
  static const int nonceSizeBytes = 12;

  static List<int> getCanonicalAad({
    required int protocolVersion,
    required String packetId,
    required String sourceDeviceId,
    required String rollVersionId,
    required String rollChecksum,
    required int observationCount,
  }) {
    final str =
        'VOTERLENS_SYNC_V$protocolVersion|$packetId|$sourceDeviceId|$rollVersionId|$rollChecksum|$observationCount';
    return utf8.encode(str);
  }

  static Future<SecretKey> deriveKey(String passphrase, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: pbkdf2Iterations,
      bits: 256,
    );
    return await pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
  }

  static Future<List<int>> encryptPayload({
    required List<int> plaintext,
    required SecretKey key,
    required List<int> nonce,
    required List<int> aad,
  }) async {
    final algorithm = AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    // AesGcm in cryptography library produces ciphertext + 16-byte tag
    final combined = <int>[...secretBox.cipherText, ...secretBox.mac.bytes];
    return combined;
  }

  static Future<List<int>> decryptPayload({
    required List<int> ciphertextWithTag,
    required SecretKey key,
    required List<int> nonce,
    required List<int> aad,
  }) async {
    if (ciphertextWithTag.length < 16) {
      throw const FormatException('Ciphertext is too short to contain authentication tag');
    }
    final algorithm = AesGcm.with256bits();
    final cipherText = ciphertextWithTag.sublist(0, ciphertextWithTag.length - 16);
    final tagBytes = ciphertextWithTag.sublist(ciphertextWithTag.length - 16);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(tagBytes));
    return await algorithm.decrypt(secretBox, secretKey: key, aad: aad);
  }
}

class VLSyncFileEngine {
  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  VLSyncFileEngine(this._db);

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  /// Exports field observations to an encrypted .vlsync file.
  Future<String> exportToFile({
    required String targetDirectory,
    required String transferPassphrase,
    required String operatorUsername,
    String? selectedPartNumber,
  }) async {
    final roll = _db.getActiveRoll();
    if (roll == null) {
      throw StateError('No active electoral roll found to export observations from');
    }

    final deviceId = _db.getDeviceId();
    final packetId = _uuid.v4();

    // Gather observations from database
    final observations = _db.getAllEligibleObservations(
      rollVersionId: roll.id,
      partNumber: selectedPartNumber,
    );

    final payloadMap = {
      'packet_id': packetId,
      'roll_version_id': roll.id,
      'roll_checksum': roll.checksumHash,
      'observations': observations,
    };
    final payloadBytes = utf8.encode(jsonEncode(payloadMap));

    // Cryptographic preparation with CSPRNG
    final secureRandom = Random.secure();
    final salt = List<int>.generate(16, (_) => secureRandom.nextInt(256));
    final nonce = List<int>.generate(12, (_) => secureRandom.nextInt(256));
    final key = await VLSyncCrypto.deriveKey(transferPassphrase, salt);

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: 1,
      packetId: packetId,
      sourceDeviceId: deviceId,
      rollVersionId: roll.id,
      rollChecksum: roll.checksumHash ?? '',
      observationCount: observations.length,
    );

    final ciphertextWithTag = await VLSyncCrypto.encryptPayload(
      plaintext: payloadBytes,
      key: key,
      nonce: nonce,
      aad: aad,
    );

    final sha256Checksum = crypto.sha256.convert(ciphertextWithTag).toString();

    final envelope = {
      'magic': 'VLSYNC',
      'protocol_version': 1,
      'packet_id': packetId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'packet_type': 'FIELD_OBSERVATIONS_SYNC',
      'source_device_id': deviceId,
      'source_user_id': operatorUsername,
      'roll_version_id': roll.id,
      'roll_checksum': roll.checksumHash,
      'observation_count': observations.length,
      'encryption': {
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': 100000,
        'salt_hex': _bytesToHex(salt),
        'nonce_hex': _bytesToHex(nonce),
      },
      'ciphertext_hex': _bytesToHex(ciphertextWithTag),
      'file_integrity': {
        'sha256': sha256Checksum,
      },
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(envelope);

    final dir = Directory(targetDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final timeStr = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').replaceAll('-', '');
    final filePath = '${dir.path}/VoterLens_$timeStr.vlsync';
    final file = File(filePath);
    await file.writeAsString(jsonStr);

    // Record export in sync_packets
    _db.recordSyncPacket(
      packetId: packetId,
      direction: 'EXPORT',
      protocolVersion: 1,
      sourceDeviceId: deviceId,
      sourceUserId: operatorUsername,
      rollVersionId: roll.id,
      rollChecksum: roll.checksumHash ?? '',
      observationCount: observations.length,
      status: 'CREATED',
      statusMessage: 'Exported ${observations.length} observations to $filePath',
    );

    // Audit log
    _db.logAudit(
      action: 'SYNC_EXPORT_COMPLETED',
      entityType: 'SyncPacket',
      entityId: packetId,
      performedBy: operatorUsername,
      details: 'Exported ${observations.length} observations to $filePath',
    );

    return filePath;
  }

  /// Inspects, decrypts, authenticates and generates an import preview without mutating DB state.
  Future<ImportPreviewItem> previewVLSyncFile({
    required String filePath,
    required String transferPassphrase,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Sync file does not exist', filePath);
    }

    final content = await file.readAsString();
    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      throw const FormatException('Invalid .vlsync file: malformed JSON format');
    }

    // 1. Magic check
    if (envelope['magic'] != 'VLSYNC') {
      throw const FormatException('Invalid .vlsync file: missing or incorrect VLSYNC magic header');
    }

    // 2. Protocol version
    final protoVer = envelope['protocol_version'] as int? ?? 1;
    if (protoVer != 1) {
      throw FormatException('Unsupported sync protocol version: $protoVer');
    }

    final packetId = envelope['packet_id'] as String;
    final sourceDeviceId = envelope['source_device_id'] as String;
    final sourceUserId = envelope['source_user_id'] as String? ?? 'remote';
    final rollVersionId = envelope['roll_version_id'] as String;
    final rollChecksum = envelope['roll_checksum'] as String;
    final observationCount = envelope['observation_count'] as int? ?? 0;
    final createdAt = envelope['created_at'] as String? ?? DateTime.now().toIso8601String();

    final enc = envelope['encryption'] as Map<String, dynamic>?;
    if (enc == null || enc['algorithm'] != 'AES-256-GCM') {
      throw const FormatException('Unsupported encryption parameters');
    }

    final salt = _hexToBytes(enc['salt_hex'] as String);
    final nonce = _hexToBytes(enc['nonce_hex'] as String);
    final ciphertextWithTag = _hexToBytes(envelope['ciphertext_hex'] as String);

    // Integrity check
    final integrity = envelope['file_integrity'] as Map<String, dynamic>?;
    if (integrity != null && integrity['sha256'] != null) {
      final computedSha = crypto.sha256.convert(ciphertextWithTag).toString();
      if (computedSha != integrity['sha256']) {
        throw const FormatException('Integrity verification failed: SHA-256 checksum mismatch');
      }
    }

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: protoVer,
      packetId: packetId,
      sourceDeviceId: sourceDeviceId,
      rollVersionId: rollVersionId,
      rollChecksum: rollChecksum,
      observationCount: observationCount,
    );

    final key = await VLSyncCrypto.deriveKey(transferPassphrase, salt);

    // Decrypt payload
    final List<int> plaintext;
    try {
      plaintext = await VLSyncCrypto.decryptPayload(
        ciphertextWithTag: ciphertextWithTag,
        key: key,
        nonce: nonce,
        aad: aad,
      );
    } catch (e) {
      throw const FormatException('Authentication failed: incorrect transfer passphrase or corrupted file');
    }

    final payload = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    final rawObs = (payload['observations'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    // Roll compatibility verification
    final activeRoll = _db.getActiveRoll();
    final isCompatibleRoll = activeRoll != null && activeRoll.checksumHash == rollChecksum;
    String? rejectionReason;
    if (!isCompatibleRoll) {
      rejectionReason = 'This synchronization file belongs to a different electoral-roll version.';
    }

    // Check idempotency
    final isAlreadyImported = _db.isPacketImported(packetId);
    if (isAlreadyImported) {
      rejectionReason = 'This synchronization file has already been imported.';
    }

    final canCommit = isCompatibleRoll && !isAlreadyImported;

    // Classify observations
    final previewRecords = <PreviewRecordItem>[];
    int newCount = 0;
    int dupCount = 0;
    int identicalCount = 0;
    int staleCount = 0;
    int concurrentCount = 0;
    int rollMismatchCount = 0;
    int voterNotFoundCount = 0;

    for (final obs in rawObs) {
      final obsId = obs['observation_id'] as String? ?? 'UNKNOWN';
      final epic = obs['voter_epic'] as String? ?? '';
      final partSerial = obs['voter_part_serial'] as String?;
      final incomingStatus = obs['field_status'] as String? ?? 'NO_ISSUE';
      final phone = obs['phone_number'] as String?;
      final notes = obs['notes'] as String?;
      final obsCreatedAt = obs['created_at'] as String? ?? createdAt;
      final originDev = obs['origin_device_id'] as String? ?? sourceDeviceId;

      if (!isCompatibleRoll) {
        rollMismatchCount++;
        previewRecords.add(
          PreviewRecordItem(
            observationId: obsId,
            voterEpic: epic,
            voterPartSerial: partSerial,
            incomingStatus: incomingStatus,
            classification: 'ROLL_MISMATCH',
            message: 'Roll version mismatch',
            isSafeToImport: false,
            requiresReview: false,
            isRejected: true,
            phoneNumber: phone,
            notes: notes,
            createdAt: obsCreatedAt,
            originDeviceId: originDev,
            rawObservation: obs,
          ),
        );
        continue;
      }

      // Resolve voter in local database
      final voter = _db.resolveCanonicalVoter(
        rollVersionId: activeRoll.id,
        epicNumber: epic,
        partSerial: partSerial,
      );

      if (voter == null) {
        voterNotFoundCount++;
        previewRecords.add(
          PreviewRecordItem(
            observationId: obsId,
            voterEpic: epic,
            voterPartSerial: partSerial,
            incomingStatus: incomingStatus,
            classification: 'VOTER_NOT_FOUND',
            message: 'Voter with EPIC $epic not found in active roll',
            isSafeToImport: false,
            requiresReview: true,
            isRejected: true,
            phoneNumber: phone,
            notes: notes,
            createdAt: obsCreatedAt,
            originDeviceId: originDev,
            rawObservation: obs,
          ),
        );
        continue;
      }

      // Check conflict classification against local state
      final localFs = voter.fieldStatus;
      final localObs = _db.getLatestObservationForEpic(epic);

      if (_db.isObservationIdExists(obsId)) {
        dupCount++;
        previewRecords.add(
          PreviewRecordItem(
            observationId: obsId,
            voterEpic: epic,
            voterPartSerial: partSerial,
            voterName: voter.name,
            incomingStatus: incomingStatus,
            localStatus: localFs.status.name,
            classification: 'DUPLICATE',
            message: 'Observation already present locally',
            isSafeToImport: false,
            requiresReview: false,
            isRejected: false,
            phoneNumber: phone,
            notes: notes,
            createdAt: obsCreatedAt,
            originDeviceId: originDev,
            rawObservation: obs,
          ),
        );
        continue;
      }

      if (localObs != null) {
        // Identical check
        if (localObs['field_status'] == incomingStatus &&
            (localObs['phone_number'] ?? '') == (phone ?? '') &&
            (localObs['notes'] ?? '') == (notes ?? '')) {
          identicalCount++;
          previewRecords.add(
            PreviewRecordItem(
              observationId: obsId,
              voterEpic: epic,
              voterPartSerial: partSerial,
              voterName: voter.name,
              incomingStatus: incomingStatus,
              localStatus: localFs.status.name,
              classification: 'IDENTICAL',
              message: 'Matches current local state exactly',
              isSafeToImport: false,
              requiresReview: false,
              isRejected: false,
              phoneNumber: phone,
              notes: notes,
              createdAt: obsCreatedAt,
              originDeviceId: originDev,
              rawObservation: obs,
            ),
          );
          continue;
        }

        // Temporal stale check
        final incomingTime = DateTime.tryParse(obsCreatedAt) ?? DateTime.now();
        final localTime = DateTime.tryParse(localObs['created_at'] as String? ?? '') ?? DateTime.now();

        if (incomingTime.isBefore(localTime)) {
          staleCount++;
          previewRecords.add(
            PreviewRecordItem(
              observationId: obsId,
              voterEpic: epic,
              voterPartSerial: partSerial,
              voterName: voter.name,
              incomingStatus: incomingStatus,
              localStatus: localFs.status.name,
              classification: 'STALE',
              message: 'Observation is older than local record (will be appended to history only)',
              isSafeToImport: true,
              requiresReview: false,
              isRejected: false,
              phoneNumber: phone,
              notes: notes,
              createdAt: obsCreatedAt,
              originDeviceId: originDev,
              rawObservation: obs,
            ),
          );
          continue;
        }

        // Divergent concurrent observation
        if (localObs['field_status'] != incomingStatus) {
          concurrentCount++;
          previewRecords.add(
            PreviewRecordItem(
              observationId: obsId,
              voterEpic: epic,
              voterPartSerial: partSerial,
              voterName: voter.name,
              incomingStatus: incomingStatus,
              localStatus: localFs.status.name,
              classification: 'CONCURRENT',
              message: 'Concurrent divergence: local (${localFs.status.name}) vs imported ($incomingStatus)',
              isSafeToImport: false,
              requiresReview: true,
              isRejected: false,
              phoneNumber: phone,
              notes: notes,
              createdAt: obsCreatedAt,
              originDeviceId: originDev,
              rawObservation: obs,
            ),
          );
          continue;
        }
      }

      // Clean new observation
      newCount++;
      previewRecords.add(
        PreviewRecordItem(
          observationId: obsId,
          voterEpic: epic,
          voterPartSerial: partSerial,
          voterName: voter.name,
          incomingStatus: incomingStatus,
          localStatus: localFs.status.name,
          classification: 'NEW',
          message: 'Safe to import and materialize',
          isSafeToImport: true,
          requiresReview: false,
          isRejected: false,
          phoneNumber: phone,
          notes: notes,
          createdAt: obsCreatedAt,
          originDeviceId: originDev,
          rawObservation: obs,
        ),
      );
    }

    return ImportPreviewItem(
      packetId: packetId,
      sourceDeviceId: sourceDeviceId,
      sourceUserId: sourceUserId,
      rollVersionId: rollVersionId,
      rollChecksum: rollChecksum,
      createdAt: createdAt,
      totalRecords: rawObs.length,
      newRecords: newCount,
      duplicateRecords: dupCount,
      identicalRecords: identicalCount,
      staleRecords: staleCount,
      concurrentConflicts: concurrentCount,
      rollMismatchRecords: rollMismatchCount,
      voterNotFoundRecords: voterNotFoundCount,
      invalidRecords: 0,
      permissionConflictRecords: 0,
      isCompatibleRoll: isCompatibleRoll,
      canCommit: canCommit,
      rejectionReason: rejectionReason,
      records: previewRecords,
      rawEnvelope: envelope,
    );
  }

  /// Commits previewed observations into SQLite inside an atomic transaction.
  Future<Map<String, dynamic>> commitImport({
    required ImportPreviewItem preview,
    required String operatorUsername,
  }) async {
    final role = operatorUsername.trim().toUpperCase();
    if (role != 'ADMIN' && role != 'MANAGER') {
      throw ArgumentError('Unauthorized: commitImport requires Manager or Admin privileges (got: $operatorUsername)');
    }

    if (!preview.canCommit) {
      throw StateError(preview.rejectionReason ?? 'Cannot commit rejected synchronization file');
    }

    return _db.commitImportObservations(
      preview: preview,
      operatorUsername: operatorUsername,
    );
  }

  /// Inspects, decrypts, and generates a preview for a Gazette Snapshot without mutating DB state.
  Future<GazetteSnapshotPreview> previewGazetteSnapshotFile({
    required String filePath,
    required String transferPassphrase,
  }) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('Snapshot file does not exist', filePath);
    }

    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      throw const FormatException('Snapshot file is empty');
    }

    final Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      throw const FormatException('Invalid .vlsync file: malformed JSON format');
    }

    // 1. Magic check
    if (envelope['magic'] != 'VLSYNC') {
      throw const FormatException('Invalid .vlsync file: missing or incorrect VLSYNC magic header');
    }

    // 2. Protocol version
    final protoVer = envelope['protocol_version'] as int? ?? 1;
    if (protoVer != 1) {
      throw FormatException('Unsupported sync protocol version: $protoVer');
    }

    // 3. Packet type check
    final packetType = envelope['packet_type'] as String? ?? '';
    if (packetType != 'GAZETTE_SNAPSHOT') {
      throw FormatException("Expected packet_type 'GAZETTE_SNAPSHOT', got '$packetType'");
    }

    final packetId = envelope['packet_id'] as String;
    final sourceDeviceId = envelope['source_device_id'] as String;
    final rollVersionId = envelope['roll_version_id'] as String;
    final rollChecksum = envelope['roll_checksum'] as String;
    final observationCount = envelope['observation_count'] as int? ?? 0;

    final enc = envelope['encryption'] as Map<String, dynamic>?;
    if (enc == null || enc['algorithm'] != 'AES-256-GCM') {
      throw const FormatException('Unsupported encryption parameters');
    }

    final salt = _hexToBytes(enc['salt_hex'] as String);
    final nonce = _hexToBytes(enc['nonce_hex'] as String);
    final ciphertextWithTag = _hexToBytes(envelope['ciphertext_hex'] as String);

    // Integrity check
    final integrity = envelope['file_integrity'] as Map<String, dynamic>?;
    if (integrity != null && integrity['sha256'] != null) {
      final computedSha = crypto.sha256.convert(ciphertextWithTag).toString();
      if (computedSha != integrity['sha256']) {
        throw const FormatException('Integrity verification failed: SHA-256 checksum mismatch');
      }
    }

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: protoVer,
      packetId: packetId,
      sourceDeviceId: sourceDeviceId,
      rollVersionId: rollVersionId,
      rollChecksum: rollChecksum,
      observationCount: observationCount,
    );

    final key = await VLSyncCrypto.deriveKey(transferPassphrase, salt);

    // Decrypt payload
    final List<int> plaintext;
    try {
      plaintext = await VLSyncCrypto.decryptPayload(
        ciphertextWithTag: ciphertextWithTag,
        key: key,
        nonce: nonce,
        aad: aad,
      );
    } catch (e) {
      throw const FormatException('Authentication failed: incorrect transfer passphrase or corrupted file');
    }

    final Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } catch (e) {
      throw const FormatException('Failed to parse decrypted JSON payload');
    }

    return _db.previewGazetteSnapshot(
      envelope: envelope,
      payload: payload,
    );
  }

  /// Bootstraps or installs a statutory roll from a validated Gazette Snapshot inside an atomic transaction.
  Future<Map<String, dynamic>> bootstrapGazetteSnapshot({
    required GazetteSnapshotPreview preview,
    required String operatorUsername,
    bool allowReplaceActive = false,
  }) async {
    final role = operatorUsername.trim().toUpperCase();
    if (role != 'ADMIN' && role != 'MANAGER') {
      throw ArgumentError('Unauthorized: bootstrapGazetteSnapshot requires Manager or Admin privileges (got: $operatorUsername)');
    }

    if (!preview.isSafeToInstall && preview.rejectionReason != null) {
      throw StateError(preview.rejectionReason!);
    }

    return _db.installGazetteSnapshot(
      preview: preview,
      operatorUsername: operatorUsername,
      allowReplaceActive: allowReplaceActive,
    );
  }

  /// Exports the statutory official roll to an authenticated, encrypted Gazette Snapshot .vlsync file.
  Future<String> exportGazetteSnapshotToFile({
    required String targetDirectory,
    required String transferPassphrase,
    required String operatorUsername,
    String? rollVersionId,
  }) async {
    final role = operatorUsername.trim().toUpperCase();
    if (role != 'ADMIN' && role != 'MANAGER') {
      throw ArgumentError('Unauthorized: exportGazetteSnapshot requires Manager or Admin privileges (got: $operatorUsername)');
    }

    final roll = rollVersionId != null
        ? _db.listRolls().firstWhere((r) => r.id == rollVersionId)
        : _db.getActiveRoll();

    if (roll == null) {
      throw StateError('No active or specified electoral roll found to snapshot');
    }

    final deviceId = _db.getDeviceId();
    final packetId = _uuid.v4();

    // Fetch all voters for the roll
    final voterRows = _db.rawDb.select(
      'SELECT * FROM voters WHERE roll_version_id = ? ORDER BY serial_number ASC',
      [roll.id],
    );

    final votersList = voterRows.map((r) => {
      'id': r['id'],
      'serial_number': r['serial_number'],
      'epic_number': r['epic_number'],
      'name': r['name'],
      'normalized_name': r['normalized_name'],
      'relative_name': r['relative_name'],
      'normalized_relative_name': r['normalized_relative_name'],
      'relative_type': r['relative_type'],
      'house_number': r['house_number'],
      'normalized_house_number': r['normalized_house_number'],
      'age': r['age'],
      'gender': r['gender'],
      'part_number': r['part_number'],
      'section_number': r['section_number'],
      'section_name': r['section_name'],
      'polling_station_name': r['polling_station_name'],
      'polling_station_address': r['polling_station_address'],
      'photo_path': r['photo_path'],
      'ocr_confidence': r['ocr_confidence'],
    }).toList();

    final payloadMap = {
      'packet_id': packetId,
      'roll_version_id': roll.id,
      'roll_checksum': roll.checksumHash,
      'roll_metadata': {
        'id': roll.id,
        'state': roll.state,
        'district': roll.district,
        'assembly_constituency': roll.assemblyConstituency,
        'roll_name': roll.rollName,
        'roll_type': roll.rollType,
        'publication_date': roll.publicationDate,
        'record_count': votersList.length,
        'checksum_hash': roll.checksumHash,
      },
      'voters': votersList,
      'observations': [],
    };

    final payloadBytes = utf8.encode(jsonEncode(payloadMap));

    final secureRandom = Random.secure();
    final salt = List<int>.generate(16, (_) => secureRandom.nextInt(256));
    final nonce = List<int>.generate(12, (_) => secureRandom.nextInt(256));
    final key = await VLSyncCrypto.deriveKey(transferPassphrase, salt);

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: 1,
      packetId: packetId,
      sourceDeviceId: deviceId,
      rollVersionId: roll.id,
      rollChecksum: roll.checksumHash ?? '',
      observationCount: 0,
    );

    final ciphertextWithTag = await VLSyncCrypto.encryptPayload(
      plaintext: payloadBytes,
      key: key,
      nonce: nonce,
      aad: aad,
    );

    final sha256Checksum = crypto.sha256.convert(ciphertextWithTag).toString();

    final envelope = {
      'magic': 'VLSYNC',
      'protocol_version': 1,
      'packet_id': packetId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'packet_type': 'GAZETTE_SNAPSHOT',
      'source_device_id': deviceId,
      'source_user_id': operatorUsername,
      'roll_version_id': roll.id,
      'roll_checksum': roll.checksumHash,
      'observation_count': 0,
      'encryption': {
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': 100000,
        'salt_hex': _bytesToHex(salt),
        'nonce_hex': _bytesToHex(nonce),
      },
      'ciphertext_hex': _bytesToHex(ciphertextWithTag),
      'file_integrity': {
        'sha256': sha256Checksum,
      },
    };

    final jsonStr = const JsonEncoder.withIndent('  ').convert(envelope);

    final dir = Directory(targetDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final timeStr = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').replaceAll('-', '');
    final filePath = '${dir.path}/GazetteSnapshot_${roll.rollName}_$timeStr.vlsync';
    final file = File(filePath);
    await file.writeAsString(jsonStr);

    _db.recordSyncPacket(
      packetId: packetId,
      direction: 'EXPORT',
      protocolVersion: 1,
      sourceDeviceId: deviceId,
      sourceUserId: operatorUsername,
      rollVersionId: roll.id,
      rollChecksum: roll.checksumHash ?? '',
      observationCount: 0,
      status: 'CREATED',
      statusMessage: 'Exported Gazette Snapshot for ${roll.rollName} (${votersList.length} voters)',
    );

    _db.logAudit(
      action: 'GAZETTE_SNAPSHOT_CREATED',
      entityType: 'RollVersion',
      entityId: roll.id,
      performedBy: operatorUsername,
      details: 'Created Gazette Snapshot containing ${votersList.length} voters at $filePath',
    );

    return filePath;
  }
}

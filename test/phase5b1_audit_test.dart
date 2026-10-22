import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:voterlens/core/constants/field_status.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/core/sync/vlsync_transport.dart';
import 'package:voterlens/domain/entities/filter_criteria.dart';

void main() {
  const testPassphrase = 'AuditSecurePassphrase2026!';

  String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<String> createAuditSnapshotFile({
    required Directory tempDir,
    required String rollVersionId,
    required String rollChecksum,
    required String rollName,
    required List<Map<String, dynamic>> voters,
    String? state,
    String? district,
    String? assemblyConstituency,
    int? declaredRecordCount,
    dynamic rawRecordCount,
    String? declaredChecksum,
    int protocolVersion = 1,
    String packetType = 'GAZETTE_SNAPSHOT',
    String? customManifestRollId,
    String? customPayloadPacketId,
    String? customPayloadRollId,
    String? customPayloadChecksum,
    Map<String, dynamic>? customMetadataOverride,
  }) async {
    final filePath = '${tempDir.path}/audit_snapshot_${DateTime.now().microsecondsSinceEpoch}.vlsync';
    final file = File(filePath);

    final packetId = 'packet-audit-${DateTime.now().microsecondsSinceEpoch}';
    final salt = Uint8List.fromList(List.generate(16, (i) => (i + 17) & 0xff));
    final nonce = Uint8List.fromList(List.generate(12, (i) => (i + 31) & 0xff));

    final count = declaredRecordCount ?? voters.length;

    final rollMeta = customMetadataOverride ?? {
      'id': customManifestRollId ?? rollVersionId,
      'state': state ?? 'KERALA',
      'district': district ?? 'PATHANAMTHITTA',
      'assembly_constituency': assemblyConstituency ?? '111 - Thiruvalla',
      'roll_name': rollName,
      'roll_type': 'GENERAL',
      'publication_date': '2026-01-01',
      'record_count': rawRecordCount ?? count,
      'checksum_hash': declaredChecksum ?? rollChecksum,
    };

    final payload = {
      'packet_id': customPayloadPacketId ?? packetId,
      'roll_version_id': customPayloadRollId ?? rollVersionId,
      'roll_checksum': customPayloadChecksum ?? rollChecksum,
      'roll_metadata': rollMeta,
      'voters': voters,
      'observations': [],
    };

    final payloadJson = jsonEncode(payload);
    final plaintext = utf8.encode(payloadJson);

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: protocolVersion,
      packetId: packetId,
      sourceDeviceId: 'audit-source-device-01',
      rollVersionId: rollVersionId,
      rollChecksum: rollChecksum,
      observationCount: 0,
    );

    final key = await VLSyncCrypto.deriveKey(testPassphrase, salt);
    final ciphertextWithTag = await VLSyncCrypto.encryptPayload(
      plaintext: plaintext,
      key: key,
      nonce: nonce,
      aad: aad,
    );

    final sha256Hex = crypto.sha256.convert(ciphertextWithTag).toString();

    final envelope = {
      'magic': 'VLSYNC',
      'protocol_version': protocolVersion,
      'packet_id': packetId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'packet_type': packetType,
      'source_device_id': 'audit-source-device-01',
      'source_user_id': 'election_commissioner',
      'roll_version_id': rollVersionId,
      'roll_checksum': rollChecksum,
      'observation_count': 0,
      'encryption': {
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2-HMAC-SHA256',
        'iterations': 100000,
        'salt_hex': bytesToHex(salt),
        'nonce_hex': bytesToHex(nonce),
      },
      'ciphertext_hex': bytesToHex(ciphertextWithTag),
      'file_integrity': {
        'sha256': sha256Hex,
      },
    };

    await file.writeAsString(jsonEncode(envelope));
    return filePath;
  }

  List<Map<String, dynamic>> standardSampleVoters(String rollId) {
    return [
      {
        'id': '$rollId-v-1',
        'roll_version_id': rollId,
        'serial_number': 1,
        'epic_number': 'AUD0000001',
        'name': 'Devan Nair',
        'normalized_name': 'devan nair',
        'relative_name': 'Gopalan Nair',
        'normalized_relative_name': 'gopalan nair',
        'relative_type': 'FATHER',
        'house_number': '10/200',
        'normalized_house_number': '10/200',
        'age': 45,
        'gender': 'MALE',
        'part_number': '1',
        'section_number': '1',
        'section_name': 'Ward 1',
        'polling_station_name': 'Govt UP School',
        'polling_station_address': 'Main Hall',
        'photo_path': null,
        'ocr_confidence': 0.99,
      },
      {
        'id': '$rollId-v-2',
        'roll_version_id': rollId,
        'serial_number': 2,
        'epic_number': 'AUD0000002',
        'name': 'Lekshmi Nair',
        'normalized_name': 'lekshmi nair',
        'relative_name': 'Devan Nair',
        'normalized_relative_name': 'devan nair',
        'relative_type': 'HUSBAND',
        'house_number': '10/200',
        'normalized_house_number': '10/200',
        'age': 42,
        'gender': 'FEMALE',
        'part_number': '1',
        'section_number': '1',
        'section_name': 'Ward 1',
        'polling_station_name': 'Govt UP School',
        'polling_station_address': 'Main Hall',
        'photo_path': null,
        'ocr_confidence': 0.98,
      },
    ];
  }

  group('Phase 5B.1 Audit: Atomic Replacement & SQLite Invariants', () {
    late Directory tempDir;
    late AppDatabase appDb;
    late VLSyncFileEngine engine;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_audit_');
      appDb = AppDatabase.openInMemory();
      engine = VLSyncFileEngine(appDb);
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('1. Successful replacement activates exactly one roll while deactivating the previous', () async {
      // Step 1: Install Roll A
      final fileA = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-audit-A',
        rollChecksum: 'checksum_roll_A',
        rollName: 'AUDIT_ROLL_A',
        voters: standardSampleVoters('roll-audit-A'),
      );
      final previewA = await engine.previewGazetteSnapshotFile(
        filePath: fileA,
        transferPassphrase: testPassphrase,
      );
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');

      final activeBefore = appDb.getActiveRoll();
      expect(activeBefore, isNotNull);
      expect(activeBefore!.id, 'roll-audit-A');
      expect(activeBefore.status, 'ACTIVE');

      // Step 2: Replace with Roll B authorized
      final fileB = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-audit-B',
        rollChecksum: 'checksum_roll_B',
        rollName: 'AUDIT_ROLL_B',
        voters: standardSampleVoters('roll-audit-B'),
      );
      final previewB = await engine.previewGazetteSnapshotFile(
        filePath: fileB,
        transferPassphrase: testPassphrase,
      );
      expect(previewB.isReplacingExistingRoll, isTrue);

      final resultB = await engine.bootstrapGazetteSnapshot(
        preview: previewB,
        operatorUsername: 'ADMIN',
        allowReplaceActive: true,
      );
      expect(resultB['status'], 'BOOTSTRAP_SUCCESS');

      // Post-condition: Exactly ONE roll is active in SQLite
      final activeRows = appDb.rawDb.select("SELECT * FROM roll_versions WHERE status = 'ACTIVE'");
      expect(activeRows.length, equals(1));
      expect(activeRows.first['id'], equals('roll-audit-B'));

      // Roll A is now SUPERSEDED
      final rollARows = appDb.rawDb.select("SELECT * FROM roll_versions WHERE id = 'roll-audit-A'");
      expect(rollARows.first['status'], equals('SUPERSEDED'));

      // Electoral area config reflects active roll B
      final area = appDb.getAreaConfig();
      expect(area!.activeRollId, equals('roll-audit-B'));
    });

    test('2. SQLite engine invariant enforces at most one ACTIVE roll', () {
      // Direct raw insertion attempt of two ACTIVE rolls violates unique partial index
      appDb.rawDb.execute(
        "INSERT INTO roll_versions (id, state, district, assembly_constituency, roll_name, status) VALUES ('r1', 'S', 'D', 'AC', 'R1', 'ACTIVE')",
      );

      // Attempting to insert second ACTIVE roll without deactivating r1 throws SqliteException
      expect(
        () => appDb.rawDb.execute(
          "INSERT INTO roll_versions (id, state, district, assembly_constituency, roll_name, status) VALUES ('r2', 'S', 'D', 'AC', 'R2', 'ACTIVE')",
        ),
        throwsException,
      );
    });

    test('3. Failed replacement leaves previous active roll untouched and consistent', () async {
      // Step 1: Install Roll A
      final fileA = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-audit-stable',
        rollChecksum: 'checksum_stable',
        rollName: 'STABLE_ROLL',
        voters: standardSampleVoters('roll-audit-stable'),
      );
      final previewA = await engine.previewGazetteSnapshotFile(
        filePath: fileA,
        transferPassphrase: testPassphrase,
      );
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');

      // Step 2: Attempt replacement with unauthorized flag allowReplaceActive=false
      final fileB = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-audit-fail',
        rollChecksum: 'checksum_fail',
        rollName: 'FAIL_ROLL',
        voters: standardSampleVoters('roll-audit-fail'),
      );
      final previewB = await engine.previewGazetteSnapshotFile(
        filePath: fileB,
        transferPassphrase: testPassphrase,
      );

      expect(
        () => engine.bootstrapGazetteSnapshot(
          preview: previewB,
          operatorUsername: 'ADMIN',
          allowReplaceActive: false,
        ),
        throwsA(isA<StateError>()),
      );

      // Roll A is still ACTIVE, and Roll B was not created or activated
      final active = appDb.getActiveRoll();
      expect(active!.id, equals('roll-audit-stable'));
      expect(active.status, equals('ACTIVE'));

      final rollBRows = appDb.rawDb.select("SELECT * FROM roll_versions WHERE id = 'roll-audit-fail'");
      expect(rollBRows, isEmpty);
    });

    test('4. Field observations on old roll are never reassigned or modified on roll replacement', () async {
      // 1. Install Roll A
      final fileA = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-obs-A',
        rollChecksum: 'chk_obs_A',
        rollName: 'OBS_ROLL_A',
        voters: standardSampleVoters('roll-obs-A'),
      );
      final previewA = await engine.previewGazetteSnapshotFile(filePath: fileA, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');

      // 2. Add an observation on voter-1 under Roll A
      appDb.updateFieldInfo(
        'roll-obs-A-v-1',
        status: FieldStatusType.reportedDeceased,
        notes: 'Confirmed in field visit',
        user: 'field_agent_raman',
      );

      final obsBefore = appDb.rawDb.select('SELECT * FROM field_observations WHERE roll_version_id = ?', ['roll-obs-A']);
      expect(obsBefore.length, equals(1));
      expect(obsBefore.first['roll_version_id'], equals('roll-obs-A'));
      expect(obsBefore.first['roll_checksum'], equals('chk_obs_A'));

      // 3. Replace Roll A with Roll B
      final fileB = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-obs-B',
        rollChecksum: 'chk_obs_B',
        rollName: 'OBS_ROLL_B',
        voters: standardSampleVoters('roll-obs-B'),
      );
      final previewB = await engine.previewGazetteSnapshotFile(filePath: fileB, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewB, operatorUsername: 'ADMIN', allowReplaceActive: true);

      // 4. Verify observation still belongs to Roll A and has not been altered or reassigned
      final obsAfter = appDb.rawDb.select('SELECT * FROM field_observations WHERE roll_version_id = ?', ['roll-obs-A']);
      expect(obsAfter.length, equals(1));
      expect(obsAfter.first['roll_version_id'], equals('roll-obs-A'));
      expect(obsAfter.first['roll_checksum'], equals('chk_obs_A'));

      // Roll B has 0 observations
      final obsRollB = appDb.rawDb.select('SELECT * FROM field_observations WHERE roll_version_id = ?', ['roll-obs-B']);
      expect(obsRollB, isEmpty);
    });

    test('5. Re-opening on-disk database after bootstrap preserves consistency across restart', () async {
      final diskDbPath = '${tempDir.path}/persistent_voterlens.db';

      // Stage 1: Bootstrap roll on disk DB (explicitly unencrypted diagnostic test)
      {
        final diskDb = AppDatabase.open(customPath: diskDbPath, allowPlaintext: true);
        final diskEngine = VLSyncFileEngine(diskDb);

        final snapFile = await createAuditSnapshotFile(
          tempDir: tempDir,
          rollVersionId: 'roll-disk-01',
          rollChecksum: 'chk_disk_01',
          rollName: 'DISK_ROLL',
          voters: standardSampleVoters('roll-disk-01'),
        );
        final preview = await diskEngine.previewGazetteSnapshotFile(
          filePath: snapFile,
          transferPassphrase: testPassphrase,
        );
        await diskEngine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'ADMIN');

        expect(diskDb.getActiveRoll()!.id, 'roll-disk-01');
        diskDb.close();
      }

      // Stage 2: Re-open DB simulating fresh app launch (explicitly unencrypted diagnostic test)
      {
        final reopenedDb = AppDatabase.open(customPath: diskDbPath, allowPlaintext: true);
        final active = reopenedDb.getActiveRoll();
        expect(active, isNotNull);
        expect(active!.id, 'roll-disk-01');
        expect(active.rollName, 'DISK_ROLL');
        expect(active.status, 'ACTIVE');

        final area = reopenedDb.getAreaConfig();
        expect(area, isNotNull);
        expect(area!.activeRollId, 'roll-disk-01');

        final voters = reopenedDb.searchVoters('roll-disk-01', const FilterCriteria());
        expect(voters.length, 2);

        reopenedDb.close();
      }
    });
  });

  group('Phase 5B.1 Audit: Payload Validation & Defect Detection', () {
    late Directory tempDir;
    late AppDatabase appDb;
    late VLSyncFileEngine engine;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_payload_audit_');
      appDb = AppDatabase.openInMemory();
      engine = VLSyncFileEngine(appDb);
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('1. Duplicate EPIC numbers within snapshot payload is rejected before activation', () async {
      final voters = [
        {
          'id': 'v-dup-epic-1',
          'roll_version_id': 'roll-dup-epic',
          'serial_number': 1,
          'epic_number': 'SAME_EPIC_001',
          'name': 'Voter One',
          'part_number': '1',
        },
        {
          'id': 'v-dup-epic-2',
          'roll_version_id': 'roll-dup-epic',
          'serial_number': 2,
          'epic_number': 'SAME_EPIC_001', // Duplicate EPIC!
          'name': 'Voter Two',
          'part_number': '1',
        },
      ];

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-dup-epic',
        rollChecksum: 'chk_dup_epic',
        rollName: 'DUP_EPIC_ROLL',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      expect(preview.isSafeToInstall, isFalse);
      expect(preview.rejectionReason, contains('Duplicate EPIC number'));

      // Ensure installation fails safely
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'ADMIN'),
        throwsA(isA<StateError>()),
      );

      expect(appDb.getActiveRoll(), isNull);
    });

    test('2. Duplicate serial numbers within same part is rejected before activation', () async {
      final voters = [
        {
          'id': 'v-dup-sn-1',
          'roll_version_id': 'roll-dup-sn',
          'serial_number': 42,
          'epic_number': 'EPIC_SN_01',
          'name': 'Voter A',
          'part_number': '1',
        },
        {
          'id': 'v-dup-sn-2',
          'roll_version_id': 'roll-dup-sn',
          'serial_number': 42, // Duplicate serial number in part 1!
          'epic_number': 'EPIC_SN_02',
          'name': 'Voter B',
          'part_number': '1',
        },
      ];

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-dup-sn',
        rollChecksum: 'chk_dup_sn',
        rollName: 'DUP_SN_ROLL',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      expect(preview.isSafeToInstall, isFalse);
      expect(preview.rejectionReason, contains('Duplicate serial number'));

      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'ADMIN'),
        throwsA(isA<StateError>()),
      );
    });

    test('3. Duplicate voter IDs within payload is rejected before activation', () async {
      final voters = [
        {
          'id': 'same-id-100',
          'roll_version_id': 'roll-dup-id',
          'serial_number': 1,
          'epic_number': 'EPIC_ID_01',
          'name': 'Voter ID 1',
          'part_number': '1',
        },
        {
          'id': 'same-id-100', // Duplicate ID!
          'roll_version_id': 'roll-dup-id',
          'serial_number': 2,
          'epic_number': 'EPIC_ID_02',
          'name': 'Voter ID 2',
          'part_number': '1',
        },
      ];

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-dup-id',
        rollChecksum: 'chk_dup_id',
        rollName: 'DUP_ID_ROLL',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      expect(preview.isSafeToInstall, isFalse);
      expect(preview.rejectionReason, contains('Duplicate voter ID'));
    });

    test('4. Negative or unrealistic record counts are safely rejected', () async {
      final voters = standardSampleVoters('roll-record-count');

      // Negative record count
      final fileNeg = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-record-count-neg',
        rollChecksum: 'chk_neg',
        rollName: 'NEG_COUNT',
        voters: voters,
        rawRecordCount: -5,
      );
      final previewNeg = await engine.previewGazetteSnapshotFile(filePath: fileNeg, transferPassphrase: testPassphrase);
      expect(previewNeg.isSafeToInstall, isFalse);
      expect(previewNeg.rejectionReason, contains('cannot be negative'));

      // Unrealistic record count (> 500,000)
      final fileExcess = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-record-count-excess',
        rollChecksum: 'chk_excess',
        rollName: 'EXCESS_COUNT',
        voters: voters,
        rawRecordCount: 600000,
      );
      final previewExcess = await engine.previewGazetteSnapshotFile(filePath: fileExcess, transferPassphrase: testPassphrase);
      expect(previewExcess.isSafeToInstall, isFalse);
      expect(previewExcess.rejectionReason, contains('exceeds maximum supported limit'));
    });

    test('5. Manifest vs Envelope roll version ID mismatch is rejected', () async {
      final voters = standardSampleVoters('roll-envelope-id');

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-envelope-id',
        customManifestRollId: 'roll-manifest-mismatch-id', // Mismatch!
        rollChecksum: 'chk_mismatch',
        rollName: 'MISMATCH_ROLL',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      expect(preview.isSafeToInstall, isFalse);
      expect(preview.rejectionReason, contains('Roll version ID mismatch'));
    });

    test('6. Payload packet ID and checksum mismatches are rejected', () async {
      final voters = standardSampleVoters('roll-packet-mismatch');

      // Packet ID mismatch
      final file1 = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-packet-mismatch',
        rollChecksum: 'chk_packet_mismatch',
        rollName: 'PACKET_MISMATCH',
        voters: voters,
        customPayloadPacketId: 'forged-packet-id-999',
      );
      final preview1 = await engine.previewGazetteSnapshotFile(filePath: file1, transferPassphrase: testPassphrase);
      expect(preview1.isSafeToInstall, isFalse);
      expect(preview1.rejectionReason, contains('Packet ID mismatch'));

      // Checksum mismatch inside payload
      final file2 = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-packet-mismatch',
        rollChecksum: 'chk_packet_mismatch',
        rollName: 'CHECKSUM_MISMATCH',
        voters: voters,
        customPayloadChecksum: 'forged_checksum_999',
      );
      final preview2 = await engine.previewGazetteSnapshotFile(filePath: file2, transferPassphrase: testPassphrase);
      expect(preview2.isSafeToInstall, isFalse);
      expect(preview2.rejectionReason, contains('Checksum mismatch'));
    });

    test('7. Unsupported protocol version in envelope is rejected', () async {
      final voters = standardSampleVoters('roll-proto');

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-proto',
        rollChecksum: 'chk_proto',
        rollName: 'PROTO_2',
        voters: voters,
        protocolVersion: 2, // Unsupported!
      );

      expect(
        () => engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase),
        throwsA(isA<FormatException>()),
      );
    });

    test('8. Foreign key violation (voter specifies different roll_version_id) is rejected', () async {
      final voters = [
        {
          'id': 'v-fk-1',
          'roll_version_id': 'DIFFERENT_ROLL_999', // Mismatched roll_version_id!
          'serial_number': 1,
          'epic_number': 'EPIC_FK_01',
          'name': 'FK Voter',
          'part_number': '1',
        },
      ];

      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-fk-target',
        rollChecksum: 'chk_fk',
        rollName: 'FK_ROLL',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      expect(preview.isSafeToInstall, isFalse);
      expect(preview.rejectionReason, contains('Foreign key violation'));
    });

    test('9. Missing or invalid field types in voter records fail safely without logging voter names', () async {
      // Invalid serial_number <= 0
      final badSerialVoter = [
        {
          'id': 'v-bad-serial',
          'roll_version_id': 'roll-bad-voters',
          'serial_number': -1, // Invalid serial!
          'epic_number': 'EPIC_BAD_SN',
          'name': 'Secret Name Never Leaked',
          'part_number': '1',
        },
      ];
      final file1 = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-bad-voters',
        rollChecksum: 'chk_bad_1',
        rollName: 'BAD_VOTER_1',
        voters: badSerialVoter,
      );
      final preview1 = await engine.previewGazetteSnapshotFile(filePath: file1, transferPassphrase: testPassphrase);
      expect(preview1.isSafeToInstall, isFalse);
      expect(preview1.rejectionReason, contains('invalid \'serial_number\''));
      // Verify voter personal name is not leaked in the rejection reason
      expect(preview1.rejectionReason, isNot(contains('Secret Name Never Leaked')));

      // Invalid age > 150
      final badAgeVoter = [
        {
          'id': 'v-bad-age',
          'roll_version_id': 'roll-bad-voters-2',
          'serial_number': 1,
          'epic_number': 'EPIC_BAD_AGE',
          'name': 'Confidential Citizen',
          'part_number': '1',
          'age': 999, // Impossible age!
        },
      ];
      final file2 = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-bad-voters-2',
        rollChecksum: 'chk_bad_2',
        rollName: 'BAD_VOTER_2',
        voters: badAgeVoter,
      );
      final preview2 = await engine.previewGazetteSnapshotFile(filePath: file2, transferPassphrase: testPassphrase);
      expect(preview2.isSafeToInstall, isFalse);
      expect(preview2.rejectionReason, contains('invalid \'age\''));
      expect(preview2.rejectionReason, isNot(contains('Confidential Citizen')));
    });

    test('10. Service-level RBAC authorization strictly blocks non-privileged users', () async {
      final voters = standardSampleVoters('roll-rbac');
      final file = await createAuditSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-rbac',
        rollChecksum: 'chk_rbac',
        rollName: 'RBAC_TEST',
        voters: voters,
      );

      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);

      // FIELD_USER is unauthorized
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'FIELD_USER'),
        throwsA(isA<ArgumentError>()),
      );

      // VIEWER is unauthorized
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'VIEWER'),
        throwsA(isA<ArgumentError>()),
      );

      // MANAGER is authorized
      final resultManager = await engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'MANAGER');
      expect(resultManager['status'], 'BOOTSTRAP_SUCCESS');
    });
  });
}

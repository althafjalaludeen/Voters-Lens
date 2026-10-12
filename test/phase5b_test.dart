import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:voterlens/core/constants/field_status.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/core/sync/vlsync_transport.dart';
import 'package:voterlens/domain/entities/sync_models.dart';

void main() {
  const testPassphrase = 'GazetteSecureBootstrap2026!';
  const uuid = Uuid();

  Future<String> createSnapshotFile({
    required Directory tempDir,
    required String rollVersionId,
    required String rollChecksum,
    required String rollName,
    required List<Map<String, dynamic>> voters,
    String? declaredChecksum,
    int? declaredRecordCount,
    Map<String, dynamic>? customMetadata,
    String packetType = 'GAZETTE_SNAPSHOT',
    int protocolVersion = 1,
    String magic = 'VLSYNC',
    String passphrase = testPassphrase,
    bool corruptCiphertext = false,
    bool tamperedSha256 = false,
    bool emptyFile = false,
    bool malformedJson = false,
  }) async {
    final packetId = uuid.v4();
    final filePath = '${tempDir.path}/snapshot_$packetId.vlsync';
    final file = File(filePath);

    if (emptyFile) {
      await file.writeAsString('');
      return filePath;
    }

    if (malformedJson) {
      await file.writeAsString('{ "magic": "VLSYNC", "broken_json": ');
      return filePath;
    }

    final effectiveChecksum = declaredChecksum ?? rollChecksum;
    final effectiveCount = declaredRecordCount ?? voters.length;

    final rollMeta = customMetadata ?? {
      'id': rollVersionId,
      'state': 'DELHI',
      'district': 'CENTRAL',
      'assembly_constituency': 'AC-01',
      'roll_name': rollName,
      'roll_type': 'GENERAL',
      'publication_date': '2026-01-01',
      'record_count': effectiveCount,
      'checksum_hash': effectiveChecksum,
    };

    final payloadMap = {
      'packet_id': packetId,
      'roll_version_id': rollVersionId,
      'roll_checksum': rollChecksum,
      'roll_metadata': rollMeta,
      'voters': voters,
      'observations': [],
    };

    final payloadBytes = utf8.encode(jsonEncode(payloadMap));
    final secureRandom = Random.secure();
    final salt = List<int>.generate(16, (_) => secureRandom.nextInt(256));
    final nonce = List<int>.generate(12, (_) => secureRandom.nextInt(256));
    final key = await VLSyncCrypto.deriveKey(passphrase, salt);

    final aad = VLSyncCrypto.getCanonicalAad(
      protocolVersion: protocolVersion,
      packetId: packetId,
      sourceDeviceId: 'bootstrap-source-unit-01',
      rollVersionId: rollVersionId,
      rollChecksum: rollChecksum,
      observationCount: 0,
    );

    var ciphertextWithTag = await VLSyncCrypto.encryptPayload(
      plaintext: payloadBytes,
      key: key,
      nonce: nonce,
      aad: aad,
    );

    if (corruptCiphertext) {
      // Flip some bits in ciphertext
      final corrupted = List<int>.from(ciphertextWithTag);
      corrupted[5] = (corrupted[5] ^ 0xFF);
      ciphertextWithTag = corrupted;
    }

    String sha256Hex = crypto.sha256.convert(ciphertextWithTag).toString();
    if (tamperedSha256) {
      sha256Hex = '0000000000000000000000000000000000000000000000000000000000000000';
    }

    String bytesToHex(List<int> bytes) =>
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final envelope = {
      'magic': magic,
      'protocol_version': protocolVersion,
      'packet_id': packetId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'packet_type': packetType,
      'source_device_id': 'bootstrap-source-unit-01',
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

  List<Map<String, dynamic>> sampleVoters(String rollId) {
    return [
      {
        'id': 'voter-001',
        'roll_version_id': rollId,
        'serial_number': 1,
        'epic_number': 'ABC1000001',
        'name': 'Aarav Sharma',
        'normalized_name': 'aarav sharma',
        'relative_name': 'Rajesh Sharma',
        'normalized_relative_name': 'rajesh sharma',
        'relative_type': 'FATHER',
        'house_number': '12A',
        'normalized_house_number': '12a',
        'age': 32,
        'gender': 'MALE',
        'part_number': '1',
        'section_number': '1',
        'section_name': 'Main Street',
        'polling_station_name': 'Govt High School',
        'polling_station_address': 'Room 1, School Road',
        'photo_path': null,
        'ocr_confidence': 1.0,
      },
      {
        'id': 'voter-002',
        'roll_version_id': rollId,
        'serial_number': 2,
        'epic_number': 'ABC1000002',
        'name': 'Priya Sharma',
        'normalized_name': 'priya sharma',
        'relative_name': 'Aarav Sharma',
        'normalized_relative_name': 'aarav sharma',
        'relative_type': 'HUSBAND',
        'house_number': '12A',
        'normalized_house_number': '12a',
        'age': 29,
        'gender': 'FEMALE',
        'part_number': '1',
        'section_number': '1',
        'section_name': 'Main Street',
        'polling_station_name': 'Govt High School',
        'polling_station_address': 'Room 1, School Road',
        'photo_path': null,
        'ocr_confidence': 1.0,
      },
    ];
  }

  group('Phase 5B: Gazette Snapshot Bootstrapping', () {
    late Directory tempDir;
    late AppDatabase appDb;
    late VLSyncFileEngine engine;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_phase5b_test_');
      appDb = AppDatabase.openInMemory();
      engine = VLSyncFileEngine(appDb);
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('1. Valid snapshot on a fresh installation bootstraps and activates roll cleanly', () async {
      // Pre-condition: fresh install has NO active roll
      expect(appDb.getActiveRoll(), isNull);
      expect(appDb.getAreaConfig(), isNull);

      final voters = sampleVoters('roll-delhi-fresh');
      final checksum = 'sha256_canonical_checksum_delhi_001';

      final file = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-delhi-fresh',
        rollChecksum: checksum,
        rollName: 'DELHI_AC01_2026',
        voters: voters,
      );

      // Preview snapshot
      final preview = await engine.previewGazetteSnapshotFile(
        filePath: file,
        transferPassphrase: testPassphrase,
      );

      expect(preview.isSafeToInstall, isTrue);
      expect(preview.isReplacingExistingRoll, isFalse);
      expect(preview.existingActiveRollName, isNull);
      expect(preview.rejectionReason, isNull);
      expect(preview.rollName, 'DELHI_AC01_2026');
      expect(preview.state, 'DELHI');
      expect(preview.district, 'CENTRAL');
      expect(preview.assemblyConstituency, 'AC-01');
      expect(preview.recordCount, 2);
      expect(preview.voterRecordsInPayload, 2);
      expect(preview.rollChecksum, checksum);

      // Bootstrap / Install
      final result = await engine.bootstrapGazetteSnapshot(
        preview: preview,
        operatorUsername: 'ADMIN',
      );

      expect(result['status'], 'BOOTSTRAP_SUCCESS');
      expect(result['voters_installed'], 2);
      expect(result['roll_name'], 'DELHI_AC01_2026');

      // Post-condition: Roll is now ACTIVE and area config is initialized
      final active = appDb.getActiveRoll();
      expect(active, isNotNull);
      expect(active!.id, 'roll-delhi-fresh');
      expect(active.rollName, 'DELHI_AC01_2026');
      expect(active.checksumHash, checksum);
      expect(active.recordCount, 2);

      final area = appDb.getAreaConfig();
      expect(area, isNotNull);
      expect(area!.assemblyConstituency, 'AC-01');
      expect(area.activeRollId, 'roll-delhi-fresh');

      // Statutory voters populated
      final v1 = appDb.resolveCanonicalVoter(rollVersionId: 'roll-delhi-fresh', epicNumber: 'ABC1000001');
      expect(v1, isNotNull);
      expect(v1!.name, 'Aarav Sharma');
      expect(v1.partNumber, '1');

      final v2 = appDb.resolveCanonicalVoter(rollVersionId: 'roll-delhi-fresh', epicNumber: 'ABC1000002');
      expect(v2, isNotNull);
      expect(v2!.name, 'Priya Sharma');

      // Audit log and Sync Packet created
      final packets = appDb.getSyncPackets();
      expect(packets.any((p) => p['packet_id'] == preview.packetId && p['direction'] == 'IMPORT'), isTrue);

      final audits = appDb.rawDb.select(
        "SELECT * FROM audit_logs WHERE action = 'GAZETTE_SNAPSHOT_RESTORED' AND entity_id = ?",
        ['roll-delhi-fresh'],
      );
      expect(audits.length, 1);
      expect(audits.first['performed_by'], 'ADMIN');
    });

    test('2. Empty or missing snapshot file is rejected with clear error', () async {
      // Non-existent file
      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: '${tempDir.path}/non_existent.vlsync',
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FileSystemException>()),
      );

      // Empty file
      final emptyFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-empty',
        rollChecksum: 'c1',
        rollName: 'EMPTY',
        voters: [],
        emptyFile: true,
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: emptyFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('3. Corrupted snapshot or incorrect passphrase is fundamentally rejected', () async {
      final voters = sampleVoters('roll-corrupt');
      final validFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-corrupt',
        rollChecksum: 'c_corrupt',
        rollName: 'CORRUPT_TEST',
        voters: voters,
      );

      // Incorrect passphrase
      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: validFile,
          transferPassphrase: 'WrongPassphrase!',
        ),
        throwsA(isA<FormatException>()),
      );

      // Corrupted ciphertext bits (AES-GCM authentication tag failure)
      final corruptFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-corrupt-bits',
        rollChecksum: 'c_corrupt_bits',
        rollName: 'CORRUPT_BITS',
        voters: voters,
        corruptCiphertext: true,
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: corruptFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );

      // Tampered SHA256 file integrity check
      final tamperedHashFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-tamper-hash',
        rollChecksum: 'c_tamper_hash',
        rollName: 'TAMPER_HASH',
        voters: voters,
        tamperedSha256: true,
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: tamperedHashFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );

      // Malformed JSON container
      final malformedFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-malformed',
        rollChecksum: 'c_malformed',
        rollName: 'MALFORMED',
        voters: voters,
        malformedJson: true,
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: malformedFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('4. Incorrect checksum or voter count mismatch is rejected', () async {
      final voters = sampleVoters('roll-chk');

      // Checksum mismatch: manifest checksum != envelope checksum
      final mismatchChecksumFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-chk',
        rollChecksum: 'envelope_checksum_111',
        declaredChecksum: 'declared_checksum_222',
        rollName: 'MISMATCH_CHECKSUM',
        voters: voters,
      );

      final preview1 = await engine.previewGazetteSnapshotFile(
        filePath: mismatchChecksumFile,
        transferPassphrase: testPassphrase,
      );
      expect(preview1.isSafeToInstall, isFalse);
      expect(preview1.rejectionReason, contains('checksum'));

      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview1, operatorUsername: 'ADMIN'),
        throwsA(isA<StateError>()),
      );

      // Record count mismatch: declared 10 but payload only has 2
      final mismatchCountFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-count',
        rollChecksum: 'chk_count',
        declaredRecordCount: 10,
        rollName: 'MISMATCH_COUNT',
        voters: voters,
      );

      final preview2 = await engine.previewGazetteSnapshotFile(
        filePath: mismatchCountFile,
        transferPassphrase: testPassphrase,
      );
      expect(preview2.isSafeToInstall, isFalse);
      expect(preview2.rejectionReason, contains('count mismatch'));

      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview2, operatorUsername: 'ADMIN'),
        throwsA(isA<StateError>()),
      );
    });

    test('5. Unsupported format/protocol version or missing mandatory fields is rejected', () async {
      final voters = sampleVoters('roll-format');

      // Invalid magic
      final badMagicFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-bad-magic',
        rollChecksum: 'c_magic',
        rollName: 'BAD_MAGIC',
        voters: voters,
        magic: 'NOT_VLSYNC',
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: badMagicFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );

      // Unsupported protocol version
      final badProtoFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-proto',
        rollChecksum: 'c_proto',
        rollName: 'BAD_PROTO',
        voters: voters,
        protocolVersion: 99,
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: badProtoFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );

      // Incorrect packet_type
      final wrongPacketFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-wrong-type',
        rollChecksum: 'c_wrong_type',
        rollName: 'WRONG_TYPE',
        voters: voters,
        packetType: 'FIELD_OBSERVATIONS_SYNC',
      );

      expect(
        () => engine.previewGazetteSnapshotFile(
          filePath: wrongPacketFile,
          transferPassphrase: testPassphrase,
        ),
        throwsA(isA<FormatException>()),
      );

      // Missing mandatory roll_metadata field (missing district)
      final missingMetaFieldFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-missing-meta',
        rollChecksum: 'c_missing_meta',
        rollName: 'MISSING_META',
        voters: voters,
        customMetadata: {
          'id': 'roll-missing-meta',
          'state': 'DELHI',
          // district missing!
          'assembly_constituency': 'AC-01',
          'roll_name': 'MISSING_META',
          'checksum_hash': 'c_missing_meta',
          'record_count': 2,
        },
      );

      final previewMissingMeta = await engine.previewGazetteSnapshotFile(
        filePath: missingMetaFieldFile,
        transferPassphrase: testPassphrase,
      );
      expect(previewMissingMeta.isSafeToInstall, isFalse);
      expect(previewMissingMeta.rejectionReason, contains('district'));

      // Missing mandatory voter record field
      final malformedVoters = [
        {
          'id': 'voter-bad',
          'name': 'Bad Voter',
          // missing serial_number, epic_number, part_number!
        }
      ];
      final badVoterFile = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-bad-voter',
        rollChecksum: 'c_bad_voter',
        rollName: 'BAD_VOTER',
        voters: malformedVoters,
      );

      final previewBadVoter = await engine.previewGazetteSnapshotFile(
        filePath: badVoterFile,
        transferPassphrase: testPassphrase,
      );
      expect(previewBadVoter.isSafeToInstall, isFalse);
      expect(previewBadVoter.rejectionReason, contains('missing mandatory field'));
    });

    test('6. Duplicate import of already active roll is safely blocked', () async {
      final voters = sampleVoters('roll-dup');
      final checksum = 'checksum_duplicate_test';

      final file = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-dup',
        rollChecksum: checksum,
        rollName: 'DELHI_DUP_TEST',
        voters: voters,
      );

      // First import succeeds
      final preview1 = await engine.previewGazetteSnapshotFile(
        filePath: file,
        transferPassphrase: testPassphrase,
      );
      await engine.bootstrapGazetteSnapshot(preview: preview1, operatorUsername: 'MANAGER');

      // Second import of identical active roll is rejected
      final preview2 = await engine.previewGazetteSnapshotFile(
        filePath: file,
        transferPassphrase: testPassphrase,
      );
      expect(preview2.isSafeToInstall, isFalse);
      expect(preview2.rejectionReason, contains('already installed and active'));

      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview2, operatorUsername: 'MANAGER'),
        throwsA(isA<StateError>()),
      );
    });

    test('7. Existing active roll protection prevents silent overwrite without authorization', () async {
      // 1. Install initial Roll A
      final votersA = sampleVoters('roll-A');
      final fileA = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-A',
        rollChecksum: 'chk_roll_A',
        rollName: 'ROLL_ALPHA',
        voters: votersA,
      );
      final previewA = await engine.previewGazetteSnapshotFile(filePath: fileA, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');
      expect(appDb.getActiveRoll()!.id, 'roll-A');

      // 2. Prepare Snapshot for Roll B (different roll)
      final votersB = [
        {
          'id': 'voter-b1',
          'roll_version_id': 'roll-B',
          'serial_number': 1,
          'epic_number': 'XYZ9000001',
          'name': 'Brijesh Kumar',
          'part_number': '2',
        }
      ];
      final fileB = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-B',
        rollChecksum: 'chk_roll_B',
        rollName: 'ROLL_BETA',
        voters: votersB,
      );

      // 3. Preview Roll B shows replacement warning
      final previewB = await engine.previewGazetteSnapshotFile(filePath: fileB, transferPassphrase: testPassphrase);
      expect(previewB.isReplacingExistingRoll, isTrue);
      expect(previewB.existingActiveRollName, 'ROLL_ALPHA');

      // 4. Attempting to install without allowReplaceActive throws StateError
      expect(
        () => engine.bootstrapGazetteSnapshot(
          preview: previewB,
          operatorUsername: 'ADMIN',
          allowReplaceActive: false, // Disallowed
        ),
        throwsA(isA<StateError>()),
      );

      // Verify Roll A is still ACTIVE and untouched
      expect(appDb.getActiveRoll()!.id, 'roll-A');
      expect(appDb.getActiveRoll()!.status, 'ACTIVE');
    });

    test('8. Authorized replacement transitions previous roll to SUPERSEDED', () async {
      // Install Roll A
      final votersA = sampleVoters('roll-A2');
      final fileA = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-A2',
        rollChecksum: 'chk_A2',
        rollName: 'ROLL_A2',
        voters: votersA,
      );
      final previewA = await engine.previewGazetteSnapshotFile(filePath: fileA, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');

      // Install Roll B with explicit authorization
      final votersB = [
        {
          'id': 'voter-b2',
          'roll_version_id': 'roll-B2',
          'serial_number': 1,
          'epic_number': 'XYZ9000002',
          'name': 'Deepak Verma',
          'part_number': '1',
        }
      ];
      final fileB = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-B2',
        rollChecksum: 'chk_B2',
        rollName: 'ROLL_B2',
        voters: votersB,
      );
      final previewB = await engine.previewGazetteSnapshotFile(filePath: fileB, transferPassphrase: testPassphrase);

      final result = await engine.bootstrapGazetteSnapshot(
        preview: previewB,
        operatorUsername: 'ADMIN',
        allowReplaceActive: true, // Explicit authorization
      );
      expect(result['status'], 'BOOTSTRAP_SUCCESS');

      // Roll B is now ACTIVE
      final active = appDb.getActiveRoll();
      expect(active, isNotNull);
      expect(active!.id, 'roll-B2');
      expect(active.rollName, 'ROLL_B2');

      // Roll A is now SUPERSEDED in database
      final oldRoll = appDb.rawDb.select('SELECT status FROM roll_versions WHERE id = ?', ['roll-A2']).first;
      expect(oldRoll['status'], 'SUPERSEDED');
    });

    test('9. Interrupted installation triggers complete transaction rollback', () {
      final initialRolls = appDb.listRolls().length;
      final initialVoters = appDb.rawDb.select('SELECT COUNT(*) AS cnt FROM voters').first['cnt'] as int;

      // Malformed preview with a voter record that triggers failure midway
      final badPreview = GazetteSnapshotPreview(
        packetId: 'fail-packet',
        sourceDeviceId: 'dev-1',
        sourceUserId: 'admin',
        rollVersionId: 'roll-fail',
        rollChecksum: 'fail_chk',
        rollName: 'FAIL_ROLL',
        state: 'DELHI',
        district: 'CENTRAL',
        assemblyConstituency: 'AC-01',
        rollType: 'GENERAL',
        recordCount: 2,
        voterRecordsInPayload: 2,
        isSafeToInstall: true,
        rawPayload: {
          'voters': [
            {
              'id': 'good-voter',
              'serial_number': 1,
              'epic_number': 'OK100',
              'name': 'Good Voter',
              'part_number': '1',
            },
            {
              'id': 'broken-voter',
              // Missing serial_number & epic_number -> throws in insertion loop
            },
          ]
        },
      );

      expect(
        () => appDb.installGazetteSnapshot(
          preview: badPreview,
          operatorUsername: 'ADMIN',
        ),
        throwsA(isA<FormatException>()),
      );

      // Verify complete rollback: zero partial records inserted
      expect(appDb.listRolls().length, initialRolls);
      final postVoters = appDb.rawDb.select('SELECT COUNT(*) AS cnt FROM voters').first['cnt'] as int;
      expect(postVoters, initialVoters);
      expect(appDb.getActiveRoll(), isNull);
    });

    test('10. Existing field observations and audit history are strictly preserved', () async {
      // 1. Install initial roll
      final votersA = sampleVoters('roll-preserve');
      final fileA = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-preserve',
        rollChecksum: 'chk_preserve',
        rollName: 'ROLL_PRESERVE',
        voters: votersA,
      );
      final previewA = await engine.previewGazetteSnapshotFile(filePath: fileA, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewA, operatorUsername: 'ADMIN');

      // 2. Record field observations
      appDb.updateFieldInfo(
        'voter-001',
        status: FieldStatusType.reportedDeceased,
        notes: 'Confirmed in field visit',
        user: 'field_agent_raman',
      );

      final obsBefore = appDb.rawDb.select('SELECT * FROM field_observations WHERE voter_id = ?', ['voter-001']);
      expect(obsBefore.length, 1);
      final initialObsId = obsBefore.first['observation_id'];

      final auditsBefore = appDb.rawDb.select('SELECT COUNT(*) AS cnt FROM audit_logs').first['cnt'] as int;

      // 3. Install a second roll with authorization
      final votersB = [
        {
          'id': 'voter-b-new',
          'roll_version_id': 'roll-new',
          'serial_number': 1,
          'epic_number': 'NEW999',
          'name': 'New Resident',
          'part_number': '1',
        }
      ];
      final fileB = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-new',
        rollChecksum: 'chk_new',
        rollName: 'ROLL_NEW',
        voters: votersB,
      );
      final previewB = await engine.previewGazetteSnapshotFile(filePath: fileB, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: previewB, operatorUsername: 'ADMIN', allowReplaceActive: true);

      // 4. Verify field observations and history remain 100% intact
      final obsAfter = appDb.rawDb.select('SELECT * FROM field_observations WHERE observation_id = ?', [initialObsId]);
      expect(obsAfter.length, 1);
      expect(obsAfter.first['field_status'], 'REPORTED_DECEASED');
      expect(obsAfter.first['created_by'], 'field_agent_raman');
      expect(obsAfter.first['notes'], 'Confirmed in field visit');

      // Prior audit logs preserved
      final auditsAfter = appDb.rawDb.select('SELECT COUNT(*) AS cnt FROM audit_logs').first['cnt'] as int;
      expect(auditsAfter, greaterThan(auditsBefore));
    });

    test('11. Official statutory records remain immutable during normal field operations', () async {
      final voters = sampleVoters('roll-immut');
      final file = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-immut',
        rollChecksum: 'chk_immut',
        rollName: 'ROLL_IMMUT',
        voters: voters,
      );
      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'ADMIN');

      // Capture voter bitwise state
      final vBefore = appDb.rawDb.select('SELECT * FROM voters WHERE id = ?', ['voter-001']).first;
      final rollBefore = appDb.rawDb.select('SELECT * FROM roll_versions WHERE id = ?', ['roll-immut']).first;

      // Perform local observation update
      appDb.updateFieldInfo('voter-001', status: FieldStatusType.away, user: 'agent');

      final vAfter = appDb.rawDb.select('SELECT * FROM voters WHERE id = ?', ['voter-001']).first;
      final rollAfter = appDb.rawDb.select('SELECT * FROM roll_versions WHERE id = ?', ['roll-immut']).first;

      // Verify every statutory voter attribute is bitwise identical
      expect(vAfter['name'], vBefore['name']);
      expect(vAfter['epic_number'], vBefore['epic_number']);
      expect(vAfter['serial_number'], vBefore['serial_number']);
      expect(vAfter['part_number'], vBefore['part_number']);
      expect(vAfter['house_number'], vBefore['house_number']);
      expect(vAfter['age'], vBefore['age']);
      expect(vAfter['gender'], vBefore['gender']);

      expect(rollAfter['checksum_hash'], rollBefore['checksum_hash']);
      expect(rollAfter['record_count'], rollBefore['record_count']);
    });

    test('12. Service-level RBAC enforces Manager/Admin permission for bootstrapping', () async {
      final voters = sampleVoters('roll-rbac');
      final file = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-rbac',
        rollChecksum: 'chk_rbac',
        rollName: 'ROLL_RBAC',
        voters: voters,
      );
      final preview = await engine.previewGazetteSnapshotFile(filePath: file, transferPassphrase: testPassphrase);

      // FIELD_USER / VIEWER must be rejected
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'FIELD_USER'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'VIEWER'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'GUEST'),
        throwsA(isA<ArgumentError>()),
      );

      // MANAGER / ADMIN succeeds
      expect(
        () => engine.bootstrapGazetteSnapshot(preview: preview, operatorUsername: 'MANAGER'),
        returnsNormally,
      );
    });

    test('13. Gazette snapshot export and bootstrap round-trip entirely offline', () async {
      // 1. Install synthetic baseline
      final voters = sampleVoters('roll-roundtrip');
      final file1 = await createSnapshotFile(
        tempDir: tempDir,
        rollVersionId: 'roll-roundtrip',
        rollChecksum: 'chk_rt_1',
        rollName: 'DELHI_RT_2026',
        voters: voters,
      );
      final preview1 = await engine.previewGazetteSnapshotFile(filePath: file1, transferPassphrase: testPassphrase);
      await engine.bootstrapGazetteSnapshot(preview: preview1, operatorUsername: 'ADMIN');

      // 2. Export using Dart engine (exportGazetteSnapshotToFile)
      final exportDir = Directory('${tempDir.path}/exports')..createSync();
      final exportedFile = await engine.exportGazetteSnapshotToFile(
        targetDirectory: exportDir.path,
        transferPassphrase: 'RoundtripPassword999!',
        operatorUsername: 'ADMIN',
      );

      expect(File(exportedFile).existsSync(), isTrue);

      // 3. Open a separate fresh second database (simulating another field device)
      final freshDb = AppDatabase.openInMemory();
      final freshEngine = VLSyncFileEngine(freshDb);
      expect(freshDb.getActiveRoll(), isNull);

      // 4. Preview exported file on second device
      final preview2 = await freshEngine.previewGazetteSnapshotFile(
        filePath: exportedFile,
        transferPassphrase: 'RoundtripPassword999!',
      );

      expect(preview2.isSafeToInstall, isTrue);
      expect(preview2.rollName, 'DELHI_RT_2026');
      expect(preview2.recordCount, 2);

      // 5. Bootstrap on second device
      final result2 = await freshEngine.bootstrapGazetteSnapshot(
        preview: preview2,
        operatorUsername: 'MANAGER',
      );

      expect(result2['status'], 'BOOTSTRAP_SUCCESS');
      expect(freshDb.getActiveRoll()!.rollName, 'DELHI_RT_2026');
      expect(freshDb.getActiveRoll()!.recordCount, 2);

      final v = freshDb.resolveCanonicalVoter(rollVersionId: 'roll-roundtrip', epicNumber: 'ABC1000001');
      expect(v, isNotNull);
      expect(v!.name, 'Aarav Sharma');
    });
  });
}

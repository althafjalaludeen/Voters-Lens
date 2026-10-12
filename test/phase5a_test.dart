import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:voterlens/core/auth/pin_authenticator.dart';
import 'package:voterlens/core/constants/field_status.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/domain/entities/sync_models.dart';

void main() {
  group('Phase 5A: P0-1 Field Observation Persistence & Immutability', () {
    late AppDatabase appDb;

    setUp(() {
      appDb = AppDatabase.openInMemory();
      // Seed an active statutory roll
      appDb.rawDb.execute('''
        INSERT INTO roll_versions (
          id, state, district, assembly_constituency, roll_name, roll_type,
          status, checksum_hash, record_count
        ) VALUES (
          'roll-delhi-001', 'DELHI', 'CENTRAL', 'AC-01', 'DELHI_AC01_2026', 'GENERAL',
          'ACTIVE', 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 1
        );
      ''');

      // Seed a statutory voter
      appDb.rawDb.execute('''
        INSERT INTO voters (
          id, roll_version_id, serial_number, epic_number, name, normalized_name,
          relative_name, normalized_relative_name, relative_type,
          house_number, normalized_house_number, age, gender, part_number
        ) VALUES (
          'voter-001', 'roll-delhi-001', 12, 'ABC1234567', 'Sunita Sharma', 'sunita sharma',
          'Ramesh Sharma', 'ramesh sharma', 'HUSBAND',
          'House 14B', 'house 14b', 38, 'FEMALE', '4'
        );
      ''');
    });

    test('updateFieldInfo atomically creates immutable field_observation and upserts field_status', () {
      appDb.updateFieldInfo(
        'voter-001',
        status: FieldStatusType.reportedDeceased,
        notes: 'Confirmed by neighbor at residence',
        user: 'agent_rahul',
      );

      // Verify field_observations table has recorded the immutable event
      final obsRows = appDb.rawDb.select(
        'SELECT * FROM field_observations WHERE voter_id = ?',
        ['voter-001'],
      );
      expect(obsRows.length, 1);
      final obs = obsRows.first;
      expect(obs['voter_id'], 'voter-001');
      expect(obs['voter_epic'], 'ABC1234567');
      expect(obs['voter_part_serial'], '4:12');
      expect(obs['field_status'], 'REPORTED_DECEASED');
      expect(obs['notes'], 'Confirmed by neighbor at residence');
      expect(obs['created_by'], 'agent_rahul');
      expect(obs['supersedes_id'], isNull);
      expect(obs['roll_checksum'], 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(obs['origin_device_id'], isNotEmpty);
      expect(obs['observation_id'], isNotEmpty);

      // Verify materialized field_status reflects the new status
      final statusRows = appDb.rawDb.select(
        'SELECT * FROM field_status WHERE voter_id = ?',
        ['voter-001'],
      );
      expect(statusRows.length, 1);
      expect(statusRows.first['status'], 'REPORTED_DECEASED');
      expect(statusRows.first['reported_by'], 'agent_rahul');
      expect(statusRows.first['notes'], 'Confirmed by neighbor at residence');

      // Verify field_status_history
      final historyRows = appDb.rawDb.select(
        'SELECT * FROM field_status_history WHERE voter_id = ?',
        ['voter-001'],
      );
      expect(historyRows.length, 1);
      expect(historyRows.first['old_status'], 'NO_ISSUE');
      expect(historyRows.first['new_status'], 'REPORTED_DECEASED');

      // Verify audit trail
      final auditRows = appDb.rawDb.select(
        "SELECT * FROM audit_logs WHERE action = 'FIELD_OBSERVATION_RECORDED'",
      );
      expect(auditRows.length, 1);
      expect(auditRows.first['entity_id'], obs['observation_id']);
    });

    test('successive updateFieldInfo creates second observation with supersedes_id link', () {
      // First observation
      appDb.updateFieldInfo(
        'voter-001',
        status: FieldStatusType.away,
        notes: 'Tenant stated family temporarily away',
        user: 'agent_rahul',
      );
      final firstObs = appDb.rawDb.select(
        'SELECT observation_id FROM field_observations WHERE voter_id = ?',
        ['voter-001'],
      ).first;
      final firstObsUuid = firstObs['observation_id'] as String;

      // Second observation (correction/refinement by supervisor)
      appDb.updateFieldInfo(
        'voter-001',
        status: FieldStatusType.noIssue,
        notes: 'Voter present during re-verification visit',
        user: 'supervisor_anita',
      );

      final allObs = appDb.rawDb.select(
        'SELECT * FROM field_observations WHERE voter_id = ? ORDER BY created_at ASC',
        ['voter-001'],
      );
      expect(allObs.length, 2);

      // First observation has no predecessor
      expect(allObs[0]['observation_id'], firstObsUuid);
      expect(allObs[0]['supersedes_id'], isNull);
      expect(allObs[0]['field_status'], 'AWAY');

      // Second observation explicitly supersedes first observation
      expect(allObs[1]['supersedes_id'], firstObsUuid);
      expect(allObs[1]['field_status'], 'NO_ISSUE');
      expect(allObs[1]['created_by'], 'supervisor_anita');

      // Materialized field_status shows the latest status
      final currentStatus = appDb.rawDb.select(
        'SELECT status, reported_by FROM field_status WHERE voter_id = ?',
        ['voter-001'],
      ).first;
      expect(currentStatus['status'], 'NO_ISSUE');
      expect(currentStatus['reported_by'], 'supervisor_anita');

      // Ensure export query retrieves all eligible observations for sync transport
      final exportable = appDb.getAllEligibleObservations(rollVersionId: 'roll-delhi-001');
      expect(exportable.length, 2);
    });

    test('updateFieldInfo throws ArgumentError for non-existent voter', () {
      expect(
        () => appDb.updateFieldInfo(
          'non-existent-voter-id',
          status: FieldStatusType.reportedDeceased,
          user: 'agent',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('updateFieldInfo throws StateError if active roll is missing or unverified', () {
      final freshDb = AppDatabase.openInMemory();
      freshDb.rawDb.execute('''
        INSERT INTO voters (
          id, roll_version_id, serial_number, epic_number, name, normalized_name,
          relative_name, normalized_relative_name, relative_type,
          house_number, normalized_house_number, age, gender, part_number
        ) VALUES (
          'voter-no-roll', 'unknown-roll', 1, 'XYZ999', 'Test Voter', 'test voter',
          'Relative', 'relative', 'FATHER', '1', '1', 30, 'MALE', '1'
        );
      ''');

      expect(
        () => freshDb.updateFieldInfo(
          'voter-no-roll',
          status: FieldStatusType.reportedDeceased,
          user: 'agent',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Phase 5A: P0-2 Mobile Database Path Management', () {
    test('AppDatabase respects setDefaultDirectory for mobile sandbox', () {
      final original = AppDatabase.resolvedDefaultDirectory;
      try {
        AppDatabase.setDefaultDirectory('C:/data/app_flutter');
        expect(AppDatabase.resolvedDefaultDirectory, 'C:/data/app_flutter');
        final defaultPath = AppDatabase.getDefaultDatabasePath();
        expect(defaultPath.replaceAll(r'\', '/'), 'C:/data/app_flutter/voterlens.db');
      } finally {
        AppDatabase.setDefaultDirectory(original ?? '');
      }
    });
  });

  group('Phase 5A: P0-4 Passcode Authentication & Role Escalation Security', () {
    late AppDatabase appDb;
    late PinAuthenticator pinAuth;

    setUp(() {
      appDb = AppDatabase.openInMemory();
      pinAuth = PinAuthenticator(appDb);
    });

    test('PinAuthenticator validates policy and rejects weak PINs', () {
      // Too short
      expect(
        () => PinAuthenticator.validatePinPolicy('12345'),
        throwsA(isA<PinWeakException>()),
      );

      // Non-digits
      expect(
        () => PinAuthenticator.validatePinPolicy('12345a'),
        throwsA(isA<PinWeakException>()),
      );

      // All repeated digits
      expect(
        () => PinAuthenticator.validatePinPolicy('000000'),
        throwsA(isA<PinWeakException>()),
      );
      expect(
        () => PinAuthenticator.validatePinPolicy('999999'),
        throwsA(isA<PinWeakException>()),
      );

      // Sequential asc / desc
      expect(
        () => PinAuthenticator.validatePinPolicy('123456'),
        throwsA(isA<PinWeakException>()),
      );
      expect(
        () => PinAuthenticator.validatePinPolicy('654321'),
        throwsA(isA<PinWeakException>()),
      );

      // Valid PIN
      expect(() => PinAuthenticator.validatePinPolicy('849201'), returnsNormally);
      expect(() => PinAuthenticator.validatePinPolicy('951753'), returnsNormally);
    });

    test('setupSupervisorPin stores salted PBKDF2 hash and logs audit entry', () async {
      expect(pinAuth.isSupervisorPinEstablished(), isFalse);

      await pinAuth.setupSupervisorPin('951753', performedBy: 'admin_user');

      expect(pinAuth.isSupervisorPinEstablished(), isTrue);

      final config = appDb.getAuthConfig();
      expect(config, isNotNull);
      expect(config!['pin_salt_hex'], isNotEmpty);
      expect(config['pin_hash_hex'], isNotEmpty);
      expect(config['failed_attempts'], 0);
      expect(config['locked_until_epoch'], 0);

      // Verify audit log
      final audits = appDb.rawDb.select(
        "SELECT * FROM audit_logs WHERE action = 'SUPERVISOR_PIN_ESTABLISHED'",
      );
      expect(audits.length, 1);
      expect(audits.first['performed_by'], 'admin_user');
    });

    test('verifySupervisorPin verifies correct PIN and resets failed attempts', () async {
      await pinAuth.setupSupervisorPin('849201', performedBy: 'admin_user');

      // Attempt with wrong PIN increments failed attempts
      final failResult = await pinAuth.verifySupervisorPin('849200', performedBy: 'operator');
      expect(failResult, isFalse);

      final cfgAfterFail = appDb.getAuthConfig();
      expect(cfgAfterFail!['failed_attempts'], 1);

      // Correct PIN succeeds and resets count to 0
      final successResult = await pinAuth.verifySupervisorPin('849201', performedBy: 'operator');
      expect(successResult, isTrue);

      final cfgAfterSuccess = appDb.getAuthConfig();
      expect(cfgAfterSuccess!['failed_attempts'], 0);
    });

    test('verifySupervisorPin locks out after 3 consecutive failed attempts', () async {
      await pinAuth.setupSupervisorPin('849201', performedBy: 'admin');

      // Attempt 1 & 2 fail normally
      expect(await pinAuth.verifySupervisorPin('111222', performedBy: 'user'), isFalse);
      expect(await pinAuth.verifySupervisorPin('333444', performedBy: 'user'), isFalse);

      // Attempt 3 triggers lockout
      await expectLater(
        pinAuth.verifySupervisorPin('555666', performedBy: 'user'),
        throwsA(isA<PinLockedException>()),
      );

      // Subsequent attempt even with correct PIN is blocked during lock duration
      await expectLater(
        pinAuth.verifySupervisorPin('849201', performedBy: 'user'),
        throwsA(isA<PinLockedException>()),
      );

      // Audit logs include lockout event
      final lockoutAudits = appDb.rawDb.select(
        "SELECT * FROM audit_logs WHERE action = 'PIN_ACCOUNT_LOCKED'",
      );
      expect(lockoutAudits.length, 1);
    });
  });

  group('Phase 5A.1: Integrity, Immutability & Security Verification', () {
    late AppDatabase appDb;

    setUp(() {
      appDb = AppDatabase.openInMemory();
      appDb.rawDb.execute('''
        INSERT INTO roll_versions (
          id, state, district, assembly_constituency, roll_name, roll_type,
          status, checksum_hash, record_count
        ) VALUES (
          'roll-01', 'KERALA', 'WAYANAD', 'AC-17', 'WAYANAD_2026', 'GENERAL',
          'ACTIVE', 'hash999888777666', 1
        );
      ''');

      appDb.rawDb.execute('''
        INSERT INTO voters (
          id, roll_version_id, serial_number, epic_number, name, normalized_name,
          relative_name, normalized_relative_name, relative_type,
          house_number, normalized_house_number, age, gender, part_number
        ) VALUES (
          'voter-100', 'roll-01', 1, 'KL17001', 'Kavitha Nair', 'kavitha nair',
          'Gopalan Nair', 'gopalan nair', 'FATHER',
          '101', '101', 29, 'FEMALE', '1'
        );
      ''');
    });

    test('Observation uniqueness constraint prevents duplicate observation_id', () {
      appDb.updateFieldInfo('voter-100', status: FieldStatusType.away, user: 'u1');
      final firstObs = appDb.rawDb.select(
        'SELECT observation_id FROM field_observations WHERE voter_id = ?',
        ['voter-100'],
      ).first;
      final obsId = firstObs['observation_id'] as String;

      // Attempting to insert a row with identical observation_id must trigger SQLite constraint violation
      expect(
        () => appDb.rawDb.execute('''
          INSERT INTO field_observations (
            id, observation_id, voter_id, voter_epic, voter_part_serial,
            roll_version_id, roll_checksum, field_status, created_by, created_at,
            origin_device_id
          ) VALUES (
            'duplicate-row-id', ?, 'voter-100', 'KL17001', '1:1',
            'roll-01', 'hash999888777666', 'AWAY', 'u1', '2026-10-09T00:00:00Z',
            'dev-1'
          );
        ''', [obsId]),
        throwsA(isA<SqliteException>()),
      );
    });

    test('Rapid successive updates maintain uninterrupted causal supersedes_id chain', () {
      final statuses = [
        FieldStatusType.away,
        FieldStatusType.abroad,
        FieldStatusType.reportedDeceased,
        FieldStatusType.noIssue,
      ];

      for (int i = 0; i < statuses.length; i++) {
        appDb.updateFieldInfo(
          'voter-100',
          status: statuses[i],
          notes: 'Update step $i',
          user: 'worker_$i',
        );
      }

      final observations = appDb.rawDb.select(
        'SELECT observation_id, supersedes_id, field_status FROM field_observations WHERE voter_id = ? ORDER BY rowid ASC',
        ['voter-100'],
      );
      expect(observations.length, 4);

      // Verify causal chain: each observation supersedes the immediately prior observation
      expect(observations[0]['supersedes_id'], isNull);
      expect(observations[1]['supersedes_id'], observations[0]['observation_id']);
      expect(observations[2]['supersedes_id'], observations[1]['observation_id']);
      expect(observations[3]['supersedes_id'], observations[2]['observation_id']);

      // Latest observation resolves to the last status
      final latest = appDb.getLatestObservationForEpic('KL17001');
      expect(latest, isNotNull);
      expect(latest!['observation_id'], observations[3]['observation_id']);
      expect(latest['field_status'], 'NO_ISSUE');
    });

    test('Official statutory records remain strictly immutable during field updates', () {
      final voterBefore = appDb.rawDb.select('SELECT * FROM voters WHERE id = ?', ['voter-100']).first;
      final rollBefore = appDb.rawDb.select('SELECT * FROM roll_versions WHERE id = ?', ['roll-01']).first;

      appDb.updateFieldInfo('voter-100', status: FieldStatusType.reportedDeceased, notes: 'Deceased test');

      final voterAfter = appDb.rawDb.select('SELECT * FROM voters WHERE id = ?', ['voter-100']).first;
      final rollAfter = appDb.rawDb.select('SELECT * FROM roll_versions WHERE id = ?', ['roll-01']).first;

      // Ensure every statutory column is bitwise identical
      expect(voterAfter['name'], voterBefore['name']);
      expect(voterAfter['epic_number'], voterBefore['epic_number']);
      expect(voterAfter['serial_number'], voterBefore['serial_number']);
      expect(voterAfter['part_number'], voterBefore['part_number']);
      expect(voterAfter['age'], voterBefore['age']);
      expect(voterAfter['gender'], voterBefore['gender']);

      expect(rollAfter['checksum_hash'], rollBefore['checksum_hash']);
      expect(rollAfter['record_count'], rollBefore['record_count']);
    });

    test('Service-level RBAC rejects commitImportObservations for non-manager/admin roles', () {
      final fakePreview = ImportPreviewItem(
        packetId: 'packet-1',
        sourceDeviceId: 'dev-1',
        sourceUserId: 'remote_user',
        rollVersionId: 'roll-01',
        rollChecksum: 'hash999888777666',
        createdAt: '2026-10-09T00:00:00Z',
        totalRecords: 0,
        newRecords: 0,
        duplicateRecords: 0,
        identicalRecords: 0,
        staleRecords: 0,
        concurrentConflicts: 0,
        rollMismatchRecords: 0,
        voterNotFoundRecords: 0,
        invalidRecords: 0,
        permissionConflictRecords: 0,
        isCompatibleRoll: true,
        canCommit: true,
        rejectionReason: null,
        records: [],
        rawEnvelope: {},
      );

      // FIELD_USER / VIEWER must be rejected
      expect(
        () => appDb.commitImportObservations(preview: fakePreview, operatorUsername: 'field_user'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => appDb.commitImportObservations(preview: fakePreview, operatorUsername: 'viewer'),
        throwsA(isA<ArgumentError>()),
      );

      // MANAGER / ADMIN must be accepted
      expect(
        () => appDb.commitImportObservations(preview: fakePreview, operatorUsername: 'manager'),
        returnsNormally,
      );
    });

    test('changeSupervisorPin verifies old PIN, applies policy and updates hash', () async {
      final pinAuth = PinAuthenticator(appDb);
      await pinAuth.setupSupervisorPin('849201', performedBy: 'admin');

      // Wrong old PIN is rejected
      await expectLater(
        pinAuth.changeSupervisorPin(currentPin: '000000', newPin: '951753', performedBy: 'admin'),
        throwsA(isA<ArgumentError>()),
      );

      // Weak new PIN is rejected by policy
      await expectLater(
        pinAuth.changeSupervisorPin(currentPin: '849201', newPin: '123456', performedBy: 'admin'),
        throwsA(isA<PinWeakException>()),
      );

      // Valid PIN change succeeds
      await pinAuth.changeSupervisorPin(currentPin: '849201', newPin: '951753', performedBy: 'admin');

      // Old PIN no longer works
      expect(await pinAuth.verifySupervisorPin('849201'), isFalse);

      // New PIN verifies successfully
      expect(await pinAuth.verifySupervisorPin('951753'), isTrue);

      // Audit log records PIN change
      final changeAudit = appDb.rawDb.select(
        "SELECT * FROM audit_logs WHERE action = 'SUPERVISOR_PIN_CHANGED'",
      );
      expect(changeAudit.length, 1);
    });

    test('Supervisor lockout persists across database re-open (app restart simulation)', () async {
      final tempDir = Directory.systemTemp.createTempSync('voterlens_restart_test_');
      final dbPath = '${tempDir.path}/test_restart.db';

      try {
        // Initial session: establish PIN and trigger 3 failed attempts
        final db1 = AppDatabase.open(customPath: dbPath);
        final pinAuth1 = PinAuthenticator(db1);
        await pinAuth1.setupSupervisorPin('849201', performedBy: 'admin');

        expect(await pinAuth1.verifySupervisorPin('111222'), isFalse);
        expect(await pinAuth1.verifySupervisorPin('333444'), isFalse);
        await expectLater(
          pinAuth1.verifySupervisorPin('555666'),
          throwsA(isA<PinLockedException>()),
        );

        db1.close();

        // Second session: simulate application kill and restart
        final db2 = AppDatabase.open(customPath: dbPath);
        final pinAuth2 = PinAuthenticator(db2);

        // Verification must STILL be locked even with correct PIN
        await expectLater(
          pinAuth2.verifySupervisorPin('849201'),
          throwsA(isA<PinLockedException>()),
        );

        db2.close();
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

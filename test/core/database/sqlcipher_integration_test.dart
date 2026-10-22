import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/core/security/database_key_manager.dart';
import 'package:voterlens/data/repositories/roll_repository_impl.dart';
import 'package:voterlens/data/repositories/voter_repository_impl.dart';
import 'package:voterlens/domain/entities/filter_criteria.dart';

/// Test in-memory implementation of [SecureKeyStorage] for isolated testing.
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<bool> containsKey({required String key}) async => _store.containsKey(key);

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _store[key] = value;

  @override
  Future<void> delete({required String key}) async => _store.remove(key);
}

void main() {
  group('SQLCipher Integration & Safe Database Lifecycle Tests', () {
    late Directory tempDir;
    late InMemorySecureKeyStorage fakeStorage;
    late SecureStorageDatabaseKeyManager keyManager;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_sqlcipher_test_');
      fakeStorage = InMemorySecureKeyStorage();
      keyManager = SecureStorageDatabaseKeyManager(storage: fakeStorage);
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('1. Creation of new encrypted database through openSecure()', () async {
      final dbPath = '${tempDir.path}/test_new_encrypted.db';
      expect(File(dbPath).existsSync(), isFalse);

      final db = await AppDatabase.openSecure(
        customPath: dbPath,
        keyManager: keyManager,
        bypassCipherCheck: true,
      );

      expect(db, isNotNull);
      expect(File(dbPath).existsSync(), isTrue);
      expect(await keyManager.hasKey(), isTrue);

      final key = await keyManager.getKey();
      expect(keyManager.validateKeyFormat(key), isTrue);

      db.close();
    });

    test('2. Reopening the encrypted database with the correct key', () async {
      final dbPath = '${tempDir.path}/test_reopen_encrypted.db';

      // Phase 1: Initialize and seed
      final db1 = await AppDatabase.openSecure(
        customPath: dbPath,
        keyManager: keyManager,
        bypassCipherCheck: true,
      );
      final key = await keyManager.getKey();
      db1.rawDb.execute(
        "INSERT INTO device_configs (id, device_id, device_name) VALUES ('cfg-1', 'dev-001', 'Test Device');",
      );
      final isNative = db1.isSqlCipherActive;
      db1.close();

      // Phase 2: Reopen with the exact key
      if (isNative) {
        final db2 = AppDatabase.open(
          customPath: dbPath,
          encryptionKey: key,
        );
        final rows = db2.rawDb.select('SELECT device_name FROM device_configs WHERE device_id = ?', ['dev-001']);
        expect(rows.length, equals(1));
        expect(rows.first['device_name'], equals('Test Device'));
        db2.close();
      } else {
        // On desktop test runner where native SQLCipher is absent, SQLite wrote standard SQLite header.
        // Confirming Requirement 1 & 3: Reopening without explicit allowPlaintext: true MUST fail!
        expect(
          () => AppDatabase.open(
            customPath: dbPath,
            encryptionKey: key,
            bypassCipherCheck: true,
          ),
          throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
        );

        // When explicitly authorized for testing with allowPlaintext: true, data is verified:
        final db2 = AppDatabase.open(
          customPath: dbPath,
          encryptionKey: key,
          allowPlaintext: true,
          bypassCipherCheck: true,
        );
        final rows = db2.rawDb.select('SELECT device_name FROM device_configs WHERE device_id = ?', ['dev-001']);
        expect(rows.length, equals(1));
        expect(rows.first['device_name'], equals('Test Device'));
        db2.close();
      }
    });

    test('3. Rejection of an incorrect key on encrypted database', () async {
      final dbPath = '${tempDir.path}/test_wrong_key.db';

      // Create synthetic encrypted database (starts with non-plaintext header bytes)
      final dummyCipherBytes = List<int>.generate(4096, (i) => (i * 37 + 13) % 256);
      File(dbPath).writeAsBytesSync(dummyCipherBytes);

      // Verify file is recognized as encrypted
      expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.encrypted));

      // Attempt to open with incorrect key
      const wrongKey = '0000000000000000000000000000000000000000000000000000000000000001';
      expect(
        () => AppDatabase.open(
          customPath: dbPath,
          encryptionKey: wrongKey,
          bypassCipherCheck: true,
        ),
        throwsA(isA<DatabaseDecryptionException>()),
      );

      // Verify original file was preserved intact
      expect(File(dbPath).existsSync(), isTrue);
      expect(File(dbPath).lengthSync(), equals(4096));
    });

    test('4. Missing-key handling without database modification', () async {
      final dbPath = '${tempDir.path}/test_missing_key.db';

      // Create synthetic encrypted database
      final dummyCipherBytes = List<int>.generate(4096, (i) => (i * 53 + 7) % 256);
      final file = File(dbPath);
      file.writeAsBytesSync(dummyCipherBytes);

      // Attempt open without encryptionKey
      expect(
        () => AppDatabase.open(customPath: dbPath),
        throwsA(isA<DatabaseKeyNotFoundException>()),
      );

      // Attempt openSecure when keyManager does not have a key
      expect(
        () => AppDatabase.openSecure(
          customPath: dbPath,
          keyManager: keyManager,
          bypassCipherCheck: true,
        ),
        throwsA(isA<DatabaseKeyNotFoundException>()),
      );

      // Verify file was never modified or deleted
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(4096));
    });

    test('5. Corrupted-key handling without database modification', () async {
      final dbPath = '${tempDir.path}/test_corrupt_key.db';
      final dummyCipherBytes = List<int>.generate(4096, (i) => (i * 19 + 3) % 256);
      final file = File(dbPath);
      file.writeAsBytesSync(dummyCipherBytes);

      // Corrupt key (too short)
      const corruptShortKey = 'abcdef123456';
      expect(
        () => AppDatabase.open(
          customPath: dbPath,
          encryptionKey: corruptShortKey,
          bypassCipherCheck: true,
        ),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );

      // Corrupt key (non-hex)
      const corruptNonHexKey = 'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
      expect(
        () => AppDatabase.open(
          customPath: dbPath,
          encryptionKey: corruptNonHexKey,
          bypassCipherCheck: true,
        ),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );

      // Verify file is preserved
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(4096));
    });

    test('6. Persistence of database contents across close and reopen', () async {
      final dbPath = '${tempDir.path}/test_persistence.db';
      final key = await keyManager.initializeKey();

      final db1 = AppDatabase.open(
        customPath: dbPath,
        encryptionKey: key,
        allowPlaintext: true,
        bypassCipherCheck: true,
      );

      db1.rawDb.execute('''
        INSERT INTO roll_versions (id, state, district, assembly_constituency, roll_name, status, checksum_hash)
        VALUES ('roll-test-01', 'Kerala', 'Pathanamthitta', 'Thiruvalla', 'Persistence Roll', 'ACTIVE', 'hash_test_123');
      ''');
      db1.close();

      final db2 = AppDatabase.open(
        customPath: dbPath,
        encryptionKey: key,
        allowPlaintext: true,
        bypassCipherCheck: true,
      );

      final roll = db2.getActiveRoll();
      expect(roll, isNotNull);
      expect(roll!.id, equals('roll-test-01'));
      expect(roll.rollName, equals('Persistence Roll'));
      db2.close();
    });

    test('7. Foreign-key enforcement in opened database', () {
      final db = AppDatabase.openInMemory();
      final res = db.rawDb.select('PRAGMA foreign_keys;');
      expect(res.first['foreign_keys'], equals(1));
      db.close();
    });

    test('8. In-memory database compatibility without key lifecycle overhead', () {
      final db = AppDatabase.openInMemory();
      expect(db.path, equals(':memory:'));

      // Check schema tables exist
      final tables = db.rawDb
          .select("SELECT name FROM sqlite_master WHERE type = 'table';")
          .map((r) => r['name'] as String)
          .toList();

      expect(tables, contains('roll_versions'));
      expect(tables, contains('voters'));
      expect(tables, contains('field_status'));
      expect(tables, contains('audit_logs'));
      db.close();
    });

    test('9. No plaintext fallback on SQLCipher initialization failure', () async {
      final dbPath = '${tempDir.path}/test_no_plaintext_fallback.db';
      const validKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      final db = AppDatabase.openInMemory();
      final hasCipher = db.isSqlCipherActive;
      db.close();

      if (!hasCipher) {
        expect(
          () => AppDatabase.open(
            customPath: dbPath,
            encryptionKey: validKey,
            bypassCipherCheck: false,
          ),
          throwsA(isA<SqlCipherUnavailableException>()),
        );

        if (File(dbPath).existsSync()) {
          expect(AppDatabase.detectDatabaseState(dbPath), isNot(equals(DatabaseFileState.plaintext)));
        }
      }
    });

    test('10. No accidental key replacement during subsequent opens', () async {
      final dbPath = '${tempDir.path}/test_no_key_replace.db';
      // Create synthetic encrypted database (starts with non-plaintext header bytes)
      final dummyCipherBytes = List<int>.generate(4096, (i) => (i * 41 + 17) % 256);
      File(dbPath).writeAsBytesSync(dummyCipherBytes);

      // Pre-populate key storage with existing key
      final originalKey = await keyManager.initializeKey();

      expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.encrypted));

      // Attempt openSecure on existing encrypted file
      try {
        await AppDatabase.openSecure(
          customPath: dbPath,
          keyManager: keyManager,
          bypassCipherCheck: true,
        );
      } catch (e) {
        expect(e, isA<DatabaseDecryptionException>());
      }

      // Assert that key was not replaced
      final currentKey = await keyManager.getKey();
      expect(currentKey, equals(originalKey));
      expect(File(dbPath).existsSync(), isTrue);
      expect(File(dbPath).lengthSync(), equals(4096));
    });

    test('11. Safe error handling: no keys or voter PII in exceptions', () {
      const sensitiveKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

      const keyNotFound = DatabaseKeyNotFoundException();
      expect(keyNotFound.toString().contains(sensitiveKey), isFalse);

      const keyCorrupt = DatabaseKeyCorruptedException();
      expect(keyCorrupt.toString().contains(sensitiveKey), isFalse);

      const decryptEx = DatabaseDecryptionException();
      expect(decryptEx.toString().contains(sensitiveKey), isFalse);

      const cipherEx = SqlCipherUnavailableException();
      expect(cipherEx.toString().contains(sensitiveKey), isFalse);

      const dbCorrupt = DatabaseCorruptedException();
      expect(dbCorrupt.toString().contains(sensitiveKey), isFalse);

      const migrationReq = PlaintextDatabaseMigrationRequiredException('/path/to/db');
      expect(migrationReq.toString().contains(sensitiveKey), isFalse);
    });

    test('12. Regression compatibility with existing repositories', () async {
      final db = AppDatabase.openInMemory();
      final rollRepo = RollRepositoryImpl(db);
      final voterRepo = VoterRepositoryImpl(db);

      // Seed roll
      db.rawDb.execute('''
        INSERT INTO roll_versions (id, state, district, assembly_constituency, roll_name, status)
        VALUES ('roll-101', 'Kerala', 'Pathanamthitta', 'Thiruvalla', 'Regression Roll', 'ACTIVE');
      ''');

      // Seed voter
      db.rawDb.execute('''
        INSERT INTO voters (id, roll_version_id, serial_number, epic_number, name, normalized_name, relative_name, normalized_relative_name, house_number, normalized_house_number, age, gender, part_number)
        VALUES ('v-1', 'roll-101', 1, 'KL/01/001', 'Test Voter', 'TEST VOTER', 'Relative', 'RELATIVE', '12', '12', 30, 'M', '1');
      ''');

      final activeRoll = rollRepo.getActiveRoll();
      expect(activeRoll, isNotNull);
      expect(activeRoll!.id, equals('roll-101'));

      final count = voterRepo.countVoters('roll-101', const FilterCriteria());
      expect(count, equals(1));

      final results = voterRepo.getVoters('roll-101', const FilterCriteria(epic: 'KL/01/001'));
      expect(results.length, equals(1));
      expect(results.first.name, equals('Test Voter'));

      db.close();
    });

    test('13. Plaintext database detection throws PlaintextDatabaseMigrationRequiredException', () {
      final dbPath = '${tempDir.path}/test_plaintext_detect.db';

      // Create a plaintext SQLite database
      final plaintextDb = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      plaintextDb.rawDb.execute('CREATE TABLE sample (id INT);');
      plaintextDb.close();

      expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.plaintext));

      // Opening without allowPlaintext: true must report migration is required
      expect(
        () => AppDatabase.open(customPath: dbPath, allowPlaintext: false),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );

      // openSecure must also refuse plaintext and report migration is required
      expect(
        () => AppDatabase.openSecure(customPath: dbPath, keyManager: keyManager),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );

      // Verify original plaintext file is preserved intact
      expect(File(dbPath).existsSync(), isTrue);
    });

    test('14. Corrupted/truncated file throws DatabaseCorruptedException safely', () {
      final dbPath = '${tempDir.path}/test_truncated.db';
      File(dbPath).writeAsBytesSync([1, 2, 3, 4, 5]); // Only 5 bytes

      expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.corruptedOrUncertain));

      expect(
        () => AppDatabase.open(customPath: dbPath),
        throwsA(isA<DatabaseCorruptedException>()),
      );

      // Verify file was not deleted
      expect(File(dbPath).existsSync(), isTrue);
    });
  });

  group('detectDatabaseState File Classification Tests (Step 3)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_detect_test_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('1. Nonexistent file is classified as absent', () {
      final nonExistentPath = '${tempDir.path}/absent_file.db';
      expect(File(nonExistentPath).existsSync(), isFalse);
      expect(AppDatabase.detectDatabaseState(nonExistentPath), equals(DatabaseFileState.absent));
    });

    test('2. Valid plaintext SQLite file is classified as plaintext', () {
      final plaintextPath = '${tempDir.path}/valid_plaintext.db';
      final db = AppDatabase.open(customPath: plaintextPath, allowPlaintext: true);
      db.rawDb.execute('CREATE TABLE test_tab (id INT PRIMARY KEY);');
      db.close();

      expect(File(plaintextPath).existsSync(), isTrue);
      expect(AppDatabase.detectDatabaseState(plaintextPath), equals(DatabaseFileState.plaintext));
    });

    test('3. Zero-byte file is classified as corruptedOrUncertain', () {
      final zeroBytePath = '${tempDir.path}/zero_byte.db';
      File(zeroBytePath).writeAsBytesSync([]);

      expect(File(zeroBytePath).existsSync(), isTrue);
      expect(File(zeroBytePath).lengthSync(), equals(0));
      expect(AppDatabase.detectDatabaseState(zeroBytePath), equals(DatabaseFileState.corruptedOrUncertain));
    });

    test('4. Truncated file (< 16 bytes) is classified as corruptedOrUncertain', () {
      final truncatedPath = '${tempDir.path}/truncated.db';
      File(truncatedPath).writeAsBytesSync([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65]); // 6 bytes

      expect(File(truncatedPath).existsSync(), isTrue);
      expect(File(truncatedPath).lengthSync(), equals(6));
      expect(AppDatabase.detectDatabaseState(truncatedPath), equals(DatabaseFileState.corruptedOrUncertain));
    });

    test('5. Arbitrary binary file is classified as encrypted (unrecognized header)', () {
      final arbitraryPath = '${tempDir.path}/arbitrary_binary.db';
      final bytes = List<int>.generate(128, (i) => (i * 43 + 19) % 256);
      File(arbitraryPath).writeAsBytesSync(bytes);

      expect(File(arbitraryPath).existsSync(), isTrue);
      expect(AppDatabase.detectDatabaseState(arbitraryPath), equals(DatabaseFileState.encrypted));
    });

    test('6. Valid encrypted database classification (using SQLCipher where available)', () async {
      final dbPath = '${tempDir.path}/encrypted_classification.db';
      final inMem = AppDatabase.openInMemory();
      final isNative = inMem.isSqlCipherActive;
      inMem.close();

      if (isNative) {
        final keyManager = SecureStorageDatabaseKeyManager(storage: InMemorySecureKeyStorage());
        final db = await AppDatabase.openSecure(customPath: dbPath, keyManager: keyManager);
        db.rawDb.execute('CREATE TABLE enc_test (id INT);');
        db.close();

        expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.encrypted));
      } else {
        // In desktop test environment without native SQLCipher, an encrypted representation has non-plaintext header
        final syntheticEncrypted = List<int>.generate(1024, (i) => (i * 31 + 17) % 256);
        File(dbPath).writeAsBytesSync(syntheticEncrypted);
        expect(AppDatabase.detectDatabaseState(dbPath), equals(DatabaseFileState.encrypted));
      }
    });
  });

  group('Plaintext Access Authorization & Rejection Security Tests (Step 1 & Step 4)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('voterlens_sec_test_');
    });

    tearDown(() {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('1. AppDatabase.open() does not implicitly allow plaintext', () {
      final dbPath = '${tempDir.path}/implicit_check.db';
      final db = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      db.rawDb.execute('CREATE TABLE sample (id INT);');
      db.close();

      // Open without allowPlaintext must NOT default to true
      expect(
        () => AppDatabase.open(customPath: dbPath),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );
    });

    test('2. Missing encryption key does not authorize plaintext access', () {
      final dbPath = '${tempDir.path}/missing_key_plaintext.db';
      final db = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      db.rawDb.execute('CREATE TABLE sample (id INT);');
      db.close();

      expect(
        () => AppDatabase.open(customPath: dbPath, encryptionKey: null),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );
    });

    test('3. bypassCipherCheck does not authorize plaintext access by itself', () {
      final dbPath = '${tempDir.path}/bypass_check_plaintext.db';
      final db = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      db.rawDb.execute('CREATE TABLE sample (id INT);');
      db.close();

      // bypassCipherCheck: true MUST NOT grant plaintext access
      expect(
        () => AppDatabase.open(customPath: dbPath, bypassCipherCheck: true),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );
    });

    test('4. Existing plaintext database is preserved and rejected by openSecure()', () async {
      final dbPath = '${tempDir.path}/preserved_plaintext.db';
      final db = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      db.rawDb.execute('CREATE TABLE original_data (content TEXT);');
      db.rawDb.execute("INSERT INTO original_data VALUES ('secret_electoral_record');");
      db.close();

      final file = File(dbPath);
      final sizeBefore = file.lengthSync();
      final keyManager = SecureStorageDatabaseKeyManager(storage: InMemorySecureKeyStorage());

      expect(
        () => AppDatabase.openSecure(customPath: dbPath, keyManager: keyManager),
        throwsA(isA<PlaintextDatabaseMigrationRequiredException>()),
      );

      // Verify file was NOT modified, overwritten, or deleted
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(sizeBefore));

      // Verify data is completely intact when accessed via authorized diagnostic path
      final diagDb = AppDatabase.open(customPath: dbPath, allowPlaintext: true);
      final rows = diagDb.rawDb.select('SELECT content FROM original_data;');
      expect(rows.first['content'], equals('secret_electoral_record'));
      diagDb.close();
    });

    test('5. Zero-byte database file is rejected and never overwritten', () async {
      final dbPath = '${tempDir.path}/zero_byte_reject.db';
      final file = File(dbPath);
      file.writeAsBytesSync([]);
      expect(file.lengthSync(), equals(0));

      final keyManager = SecureStorageDatabaseKeyManager(storage: InMemorySecureKeyStorage());

      // openSecure must reject it as corrupted/uncertain
      expect(
        () => AppDatabase.openSecure(customPath: dbPath, keyManager: keyManager, allowCreate: true),
        throwsA(isA<DatabaseCorruptedException>()),
      );

      // File was not overwritten with a new database
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), equals(0));
    });

    test('6. Existing encrypted database is not overwritten when keys are missing or incorrect', () async {
      final dbPath = '${tempDir.path}/existing_encrypted.db';
      final dummyCipherBytes = List<int>.generate(2048, (i) => (i * 71 + 23) % 256);
      final file = File(dbPath);
      file.writeAsBytesSync(dummyCipherBytes);

      final keyManager = SecureStorageDatabaseKeyManager(storage: InMemorySecureKeyStorage());

      // Missing key
      expect(
        () => AppDatabase.openSecure(customPath: dbPath, keyManager: keyManager),
        throwsA(isA<DatabaseKeyNotFoundException>()),
      );

      expect(file.lengthSync(), equals(2048));
      expect(file.readAsBytesSync(), equals(dummyCipherBytes));

      // Wrong key
      expect(
        () => AppDatabase.open(
          customPath: dbPath,
          encryptionKey: '1111111111111111111111111111111111111111111111111111111111111111',
          bypassCipherCheck: true,
        ),
        throwsA(isA<DatabaseDecryptionException>()),
      );

      expect(file.lengthSync(), equals(2048));
      expect(file.readAsBytesSync(), equals(dummyCipherBytes));
    });
  });
}

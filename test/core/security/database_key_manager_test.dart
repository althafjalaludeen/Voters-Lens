import 'package:flutter_test/flutter_test.dart';
import 'package:voterlens/core/security/database_key_manager.dart';

/// In-memory fake implementation of [SecureKeyStorage] for deterministic testing.
class FakeSecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _data = {};
  bool shouldThrowOnRead = false;
  bool shouldThrowOnWrite = false;
  bool shouldThrowOnContains = false;
  bool shouldThrowOnDelete = false;

  @override
  Future<bool> containsKey({required String key}) async {
    if (shouldThrowOnContains) {
      throw Exception('Hardware Keystore unavailable');
    }
    return _data.containsKey(key);
  }

  @override
  Future<String?> read({required String key}) async {
    if (shouldThrowOnRead) {
      throw Exception('Keystore authentication failure');
    }
    return _data[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (shouldThrowOnWrite) {
      throw Exception('Keystore write I/O error');
    }
    _data[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (shouldThrowOnDelete) {
      throw Exception('Keystore delete error');
    }
    _data.remove(key);
  }

  void dumpDataDirectly(String key, String value) {
    _data[key] = value;
  }

  String? inspectRaw(String key) => _data[key];
}

void main() {
  group('DatabaseKeyManager & SecureStorageDatabaseKeyManager Tests', () {
    late FakeSecureKeyStorage fakeStorage;
    late SecureStorageDatabaseKeyManager keyManager;

    setUp(() {
      fakeStorage = FakeSecureKeyStorage();
      keyManager = SecureStorageDatabaseKeyManager(storage: fakeStorage);
    });

    test('1. Generates a valid 256-bit (64-character hex) key', () async {
      final key = await keyManager.initializeKey();
      expect(key, isNotEmpty);
      expect(key.length, equals(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);
      expect(keyManager.validateKeyFormat(key), isTrue);
    });

    test('2. Persists the key successfully in secure storage', () async {
      final key = await keyManager.initializeKey();
      final storedRaw = fakeStorage.inspectRaw(SecureStorageDatabaseKeyManager.defaultKeyAlias);
      expect(storedRaw, equals(key));
    });

    test('3. Reads back and validates the persisted key', () async {
      final key = await keyManager.initializeKey();
      final retrieved = await keyManager.getKey();
      expect(retrieved, equals(key));
      expect(await keyManager.hasKey(), isTrue);
    });

    test('4. Returns the existing key on repeated initialization without re-generating', () async {
      final firstKey = await keyManager.initializeKey();
      final secondKey = await keyManager.initializeKey();
      expect(secondKey, equals(firstKey));
    });

    test('5. Does not overwrite an existing key when initialization is called again', () async {
      final initialKey = await keyManager.initializeKey();
      expect(fakeStorage.inspectRaw(SecureStorageDatabaseKeyManager.defaultKeyAlias), equals(initialKey));

      // Attempt another initialization
      final returnedKey = await keyManager.initializeKey();
      expect(returnedKey, equals(initialKey));
      expect(fakeStorage.inspectRaw(SecureStorageDatabaseKeyManager.defaultKeyAlias), equals(initialKey));
    });

    test('6. Throws DatabaseKeyNotFoundException when a required key is missing', () async {
      expect(await keyManager.hasKey(), isFalse);
      expect(
        () => keyManager.getKey(),
        throwsA(isA<DatabaseKeyNotFoundException>()),
      );
    });

    test('7. Throws DatabaseKeyCorruptedException when stored key material is malformed', () async {
      // Too short
      fakeStorage.dumpDataDirectly(SecureStorageDatabaseKeyManager.defaultKeyAlias, '1234abcd');
      expect(
        () => keyManager.getKey(),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );

      // Non-hex characters
      fakeStorage.dumpDataDirectly(
        SecureStorageDatabaseKeyManager.defaultKeyAlias,
        'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz',
      );
      expect(
        () => keyManager.getKey(),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );

      // Too long (65 chars)
      fakeStorage.dumpDataDirectly(
        SecureStorageDatabaseKeyManager.defaultKeyAlias,
        '00000000000000000000000000000000000000000000000000000000000000001',
      );
      expect(
        () => keyManager.getKey(),
        throwsA(isA<DatabaseKeyCorruptedException>()),
      );
    });

    test('8. Does not replace malformed key material when getKey() fails', () async {
      const corruptData = 'invalid_corrupt_key_data';
      fakeStorage.dumpDataDirectly(SecureStorageDatabaseKeyManager.defaultKeyAlias, corruptData);

      try {
        await keyManager.getKey();
        fail('Expected DatabaseKeyCorruptedException');
      } catch (e) {
        expect(e, isA<DatabaseKeyCorruptedException>());
      }

      // Verify the corrupt data was NOT silently overwritten or deleted
      expect(fakeStorage.inspectRaw(SecureStorageDatabaseKeyManager.defaultKeyAlias), equals(corruptData));
    });

    test('9. Does not generate a replacement after secure-storage failures', () async {
      fakeStorage.shouldThrowOnRead = true;

      expect(
        () => keyManager.getKey(),
        throwsA(isA<DatabaseKeyStorageException>()),
      );

      // Verify storage was not modified
      expect(fakeStorage.inspectRaw(SecureStorageDatabaseKeyManager.defaultKeyAlias), isNull);
    });

    test('10. Propagates sanitized errors when secure storage is unavailable on write or read', () async {
      fakeStorage.shouldThrowOnWrite = true;

      expect(
        () => keyManager.initializeKey(),
        throwsA(isA<DatabaseKeyStorageException>()),
      );
    });

    test('11. Does not expose key material or sensitive data in exception messages', () async {
      const sensitivePattern = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      fakeStorage.dumpDataDirectly(
        SecureStorageDatabaseKeyManager.defaultKeyAlias,
        '${sensitivePattern}_corrupted!',
      );

      try {
        await keyManager.getKey();
        fail('Should throw');
      } catch (e) {
        expect(e.toString().contains(sensitivePattern), isFalse);
        expect(e.toString().contains('_corrupted!'), isFalse);
      }

      const notFoundEx = DatabaseKeyNotFoundException();
      expect(notFoundEx.toString(), isNot(contains(sensitivePattern)));

      const corruptEx = DatabaseKeyCorruptedException();
      expect(corruptEx.toString(), isNot(contains(sensitivePattern)));

      const decryptEx = DatabaseDecryptionException();
      expect(decryptEx.toString(), isNot(contains(sensitivePattern)));
    });

    test('12. Supports explicit deleteKey() and subsequent getKey() fails safely', () async {
      final key = await keyManager.initializeKey();
      expect(key, isNotEmpty);
      expect(await keyManager.hasKey(), isTrue);

      await keyManager.deleteKey();
      expect(await keyManager.hasKey(), isFalse);
      expect(() => keyManager.getKey(), throwsA(isA<DatabaseKeyNotFoundException>()));
    });

    test('13. Key generation produces distinct cryptographic keys on distinct managers', () async {
      final manager1 = SecureStorageDatabaseKeyManager(
        storage: FakeSecureKeyStorage(),
        storageKey: 'key_1',
      );
      final manager2 = SecureStorageDatabaseKeyManager(
        storage: FakeSecureKeyStorage(),
        storageKey: 'key_2',
      );

      final key1 = await manager1.initializeKey();
      final key2 = await manager2.initializeKey();

      expect(key1, isNot(equals(key2)));
      expect(manager1.validateKeyFormat(key1), isTrue);
      expect(manager2.validateKeyFormat(key2), isTrue);
    });
  });
}

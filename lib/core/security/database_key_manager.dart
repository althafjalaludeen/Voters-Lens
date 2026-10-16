import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Exception thrown when a database encryption key is required but not found in secure storage.
class DatabaseKeyNotFoundException implements Exception {
  final String message;

  const DatabaseKeyNotFoundException([
    this.message = 'Database encryption key not found in secure storage.',
  ]);

  @override
  String toString() => 'DatabaseKeyNotFoundException: $message';
}

/// Exception thrown when the stored database encryption key is malformed or corrupted.
class DatabaseKeyCorruptedException implements Exception {
  final String message;

  const DatabaseKeyCorruptedException([
    this.message = 'Database encryption key in secure storage is corrupted or malformed.',
  ]);

  @override
  String toString() => 'DatabaseKeyCorruptedException: $message';
}

/// Exception thrown when an encrypted database cannot be opened or decrypted.
/// (Reserved for database-opening verification in subsequent phases).
class DatabaseDecryptionException implements Exception {
  final String message;

  const DatabaseDecryptionException([
    this.message = 'Failed to decrypt database. Key may be invalid or database file corrupted.',
  ]);

  @override
  String toString() => 'DatabaseDecryptionException: $message';
}

/// Exception thrown when the underlying secure storage mechanism is unavailable or reports an error.
class DatabaseKeyStorageException implements Exception {
  final String message;

  const DatabaseKeyStorageException([
    this.message = 'Secure storage access failure.',
  ]);

  @override
  String toString() => 'DatabaseKeyStorageException: $message';
}

/// Abstract contract for managing local SQLCipher database encryption keys.
abstract class DatabaseKeyManager {
  /// Retrieves an existing encryption key from secure storage.
  ///
  /// Throws [DatabaseKeyNotFoundException] if no key exists.
  /// Throws [DatabaseKeyCorruptedException] if the retrieved key is malformed.
  /// Throws [DatabaseKeyStorageException] if secure storage is unavailable.
  Future<String> getKey();

  /// Creates and persists an initial encryption key if none exists,
  /// or returns the existing key if already initialized.
  ///
  /// Never overwrites or replaces an existing valid key.
  /// Throws [DatabaseKeyCorruptedException] if an existing key is corrupted.
  /// Throws [DatabaseKeyStorageException] if secure storage access fails.
  Future<String> initializeKey();

  /// Checks whether an encryption key is already stored in secure storage.
  ///
  /// Throws [DatabaseKeyStorageException] if secure storage access fails.
  Future<bool> hasKey();

  /// Validates that [key] is a valid 64-character lowercase hexadecimal string
  /// representing 256 bits (32 bytes) of cryptographic key material.
  bool validateKeyFormat(String key);

  /// Explicitly deletes the database key from secure storage.
  ///
  /// This is a high-privilege destructive operation and must only be invoked
  /// through explicitly authorized device wipe workflows.
  Future<void> deleteKey();
}

/// Minimal key-value storage contract to enable clean dependency injection and testing.
abstract class SecureKeyStorage {
  Future<String?> read({required String key});
  Future<void> write({required String key, required String value});
  Future<bool> containsKey({required String key});
  Future<void> delete({required String key});
}

/// Default adapter delegating to [FlutterSecureStorage].
class FlutterSecureStorageAdapter implements SecureKeyStorage {
  final FlutterSecureStorage _storage;

  const FlutterSecureStorageAdapter([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<bool> containsKey({required String key}) =>
      _storage.containsKey(key: key);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}

/// Production implementation of [DatabaseKeyManager] backed by Android Keystore / iOS Keychain
/// via [FlutterSecureStorage].
class SecureStorageDatabaseKeyManager implements DatabaseKeyManager {
  static const String defaultKeyAlias = 'voterlens_database_encryption_key_v1';
  static const int expectedKeyHexLength = 64; // 32 bytes = 256 bits = 64 hex chars
  static final RegExp _hexRegex = RegExp(r'^[0-9a-fA-F]{64}$');

  final SecureKeyStorage _storage;
  final String storageKey;
  final Random _secureRandom;

  SecureStorageDatabaseKeyManager({
    SecureKeyStorage? storage,
    this.storageKey = defaultKeyAlias,
    Random? secureRandom,
  })  : _storage = storage ?? const FlutterSecureStorageAdapter(),
        _secureRandom = secureRandom ?? Random.secure();

  @override
  bool validateKeyFormat(String key) {
    if (key.length != expectedKeyHexLength) {
      return false;
    }
    return _hexRegex.hasMatch(key);
  }

  @override
  Future<bool> hasKey() async {
    try {
      return await _storage.containsKey(key: storageKey);
    } catch (e) {
      throw DatabaseKeyStorageException(
        'Unable to check key existence in secure storage: ${e.runtimeType}',
      );
    }
  }

  @override
  Future<String> getKey() async {
    final String? rawKey;
    try {
      rawKey = await _storage.read(key: storageKey);
    } catch (e) {
      throw DatabaseKeyStorageException(
        'Unable to read encryption key from secure storage: ${e.runtimeType}',
      );
    }

    if (rawKey == null || rawKey.isEmpty) {
      throw const DatabaseKeyNotFoundException();
    }

    final trimmed = rawKey.trim().toLowerCase();
    if (!validateKeyFormat(trimmed)) {
      throw const DatabaseKeyCorruptedException();
    }

    return trimmed;
  }

  @override
  Future<String> initializeKey() async {
    // Check if key already exists. If so, return existing key without replacing it.
    final bool exists = await hasKey();
    if (exists) {
      return await getKey();
    }

    // Generate 256 bits (32 bytes) using CSPRNG
    final keyBytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    final generatedHex = keyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toLowerCase();

    if (!validateKeyFormat(generatedHex)) {
      throw const DatabaseKeyCorruptedException(
        'Generated key failed internal format validation.',
      );
    }

    try {
      await _storage.write(key: storageKey, value: generatedHex);
    } catch (e) {
      throw DatabaseKeyStorageException(
        'Failed to persist newly generated encryption key: ${e.runtimeType}',
      );
    }

    // Verify key by reading it back from storage
    final verifiedKey = await getKey();
    if (verifiedKey != generatedHex) {
      throw const DatabaseKeyCorruptedException(
        'Secure storage verification mismatch after key generation.',
      );
    }

    return verifiedKey;
  }

  @override
  Future<void> deleteKey() async {
    try {
      await _storage.delete(key: storageKey);
    } catch (e) {
      throw DatabaseKeyStorageException(
        'Failed to delete encryption key from secure storage: ${e.runtimeType}',
      );
    }
  }
}

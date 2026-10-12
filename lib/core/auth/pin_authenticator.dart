import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

import '../database/app_database.dart';

class PinLockedException implements Exception {
  final int remainingSeconds;
  PinLockedException(this.remainingSeconds);

  @override
  String toString() =>
      'Passcode entry locked due to multiple failed attempts. Try again in $remainingSeconds seconds.';
}

class PinWeakException implements Exception {
  final String reason;
  PinWeakException(this.reason);

  @override
  String toString() => reason;
}

/// Manages secure verification, PBKDF2 hashing, and rate-limiting for supervisor role elevation.
class PinAuthenticator {
  final AppDatabase _db;

  PinAuthenticator(this._db);

  static const int minPinLength = 6;
  static const int maxPinLength = 12;

  /// Check whether a supervisor/admin PIN has been configured.
  bool isSupervisorPinEstablished() {
    return _db.isSupervisorPinEstablished();
  }

  /// Hashes a PIN using PBKDF2-HMAC-SHA256 with 100,000 iterations.
  static Future<String> hashPin(String pin, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );
    final secretKey = SecretKey(utf8.encode(pin));
    final keyBytes = await pbkdf2.deriveKey(
      secretKey: secretKey,
      nonce: salt,
    );
    final bytes = await keyBytes.extractBytes();
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Validates passcode strength policy.
  static void validatePinPolicy(String pin) {
    final trimmed = pin.trim();
    if (trimmed.length < minPinLength) {
      throw PinWeakException('Passcode must be at least $minPinLength digits.');
    }
    if (trimmed.length > maxPinLength) {
      throw PinWeakException('Passcode cannot exceed $maxPinLength digits.');
    }
    if (!RegExp(r'^\d+$').hasMatch(trimmed)) {
      throw PinWeakException('Passcode must contain numeric digits only.');
    }
    // Reject repeated digits: 000000, 111111, etc.
    final firstChar = trimmed[0];
    if (trimmed.split('').every((c) => c == firstChar)) {
      throw PinWeakException('Passcode cannot consist of identical digits.');
    }
    // Reject sequential ascending/descending digits
    const trivialSeq = ['123456', '234567', '345678', '456789', '654321', '987654', '012345'];
    if (trivialSeq.any((s) => trimmed.contains(s))) {
      throw PinWeakException('Passcode cannot be a simple sequential sequence.');
    }
  }

  /// Sets up the supervisor PIN for the first time.
  Future<void> setupSupervisorPin(String pin, {String performedBy = 'operator'}) async {
    validatePinPolicy(pin);
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final hashHex = await hashPin(pin.trim(), salt);
    final saltHex = salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    _db.saveSupervisorPin(saltHex: saltHex, hashHex: hashHex, performedBy: performedBy);
  }

  /// Changes the supervisor PIN after validating current PIN.
  Future<void> changeSupervisorPin({
    required String currentPin,
    required String newPin,
    String performedBy = 'operator',
  }) async {
    final verified = await verifySupervisorPin(currentPin, performedBy: performedBy);
    if (!verified) {
      throw ArgumentError('Current passcode verification failed.');
    }
    validatePinPolicy(newPin);
    final rng = Random.secure();
    final salt = List<int>.generate(16, (_) => rng.nextInt(256));
    final hashHex = await hashPin(newPin.trim(), salt);
    final saltHex = salt.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    _db.saveSupervisorPin(saltHex: saltHex, hashHex: hashHex, performedBy: performedBy);
    _db.logAudit(
      action: 'SUPERVISOR_PIN_CHANGED',
      entityType: 'AuthConfig',
      entityId: 'SUPERVISOR_PIN',
      performedBy: performedBy,
      details: 'Supervisor passcode changed successfully',
    );
  }

  /// Verifies supervisor PIN with rate limiting and escalating lockout.
  Future<bool> verifySupervisorPin(String pin, {String performedBy = 'operator'}) async {
    final authConfig = _db.getAuthConfig();
    if (authConfig == null) {
      throw StateError('No supervisor passcode has been configured on this device.');
    }

    final nowEpoch = DateTime.now().millisecondsSinceEpoch;
    final lockedUntil = authConfig['locked_until_epoch'] as int? ?? 0;
    if (nowEpoch < lockedUntil) {
      final remaining = ((lockedUntil - nowEpoch) / 1000).ceil();
      _db.logAudit(
        action: 'ROLE_ELEVATION_BLOCKED_LOCKED',
        entityType: 'UserRole',
        entityId: 'AUTH',
        performedBy: performedBy,
        details: 'Attempted during lockout ($remaining seconds remaining)',
      );
      throw PinLockedException(remaining);
    }

    final saltHex = authConfig['pin_salt_hex'] as String;
    final expectedHashHex = authConfig['pin_hash_hex'] as String;
    final salt = _hexToBytes(saltHex);

    final computedHash = await hashPin(pin.trim(), salt);
    if (computedHash == expectedHashHex) {
      _db.resetPinFailedAttempts();
      _db.logAudit(
        action: 'ROLE_ELEVATION_SUCCESS',
        entityType: 'UserRole',
        entityId: 'AUTH',
        performedBy: performedBy,
        details: 'Passcode verified successfully',
      );
      return true;
    } else {
      final currentFailed = (authConfig['failed_attempts'] as int? ?? 0) + 1;
      int lockoutDurationMs = 0;
      if (currentFailed >= 5) {
        lockoutDurationMs = 300000; // 5 minutes
      } else if (currentFailed == 4) {
        lockoutDurationMs = 60000; // 1 minute
      } else if (currentFailed == 3) {
        lockoutDurationMs = 30000; // 30 seconds
      }

      final newLockoutEpoch = lockoutDurationMs > 0 ? nowEpoch + lockoutDurationMs : 0;
      _db.recordPinFailedAttempt(
        failedAttempts: currentFailed,
        lockedUntilEpoch: newLockoutEpoch,
      );

      _db.logAudit(
        action: 'ROLE_ELEVATION_FAILED',
        entityType: 'UserRole',
        entityId: 'AUTH',
        performedBy: performedBy,
        details: 'Failed attempt #$currentFailed${lockoutDurationMs > 0 ? " (locked for ${lockoutDurationMs ~/ 1000}s)" : ""}',
      );

      if (lockoutDurationMs > 0) {
        _db.logAudit(
          action: 'PIN_ACCOUNT_LOCKED',
          entityType: 'UserRole',
          entityId: 'AUTH',
          performedBy: performedBy,
          details: 'Account locked for ${lockoutDurationMs ~/ 1000}s after $currentFailed failed attempts',
        );
        throw PinLockedException(lockoutDurationMs ~/ 1000);
      }
      return false;
    }
  }

  static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }
}

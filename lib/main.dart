import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'core/database/app_database.dart';
import 'core/security/database_key_manager.dart';
import 'presentation/providers/database_provider.dart';
import 'presentation/screens/database_error_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize SQLCipher native platform bindings
  try {
    await AppDatabase.initializeSqlCipherPlatform();
  } catch (_) {
    // Non-fatal fallback for platforms where SQLCipher dynamic override is not required
  }

  // 2. Resolve default mobile database directory
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    AppDatabase.setDefaultDirectory(docsDir.path);
  } catch (_) {
    // Non-fatal fallback for CLI or unsupported platform environments
  }

  // 3. Asynchronously open or initialize database through secure lifecycle
  AppDatabase? database;
  DatabaseStartupError? startupError;

  try {
    database = await AppDatabase.openSecure();
  } on PlaintextDatabaseMigrationRequiredException {
    startupError = const DatabaseStartupError(
      type: DatabaseStartupErrorType.migrationRequired,
      title: 'Database Migration Required',
      message:
          'An unencrypted database was detected. Secure SQLCipher encryption must be configured before accessing roll data.',
      recoveryHint:
          'Plaintext-to-encrypted database migration will be performed in Step 4.',
    );
  } on DatabaseKeyNotFoundException {
    startupError = const DatabaseStartupError(
      type: DatabaseStartupErrorType.keyNotFound,
      title: 'Security Key Inaccessible',
      message:
          'An encrypted database was detected, but the encryption key is missing from secure hardware storage.',
      recoveryHint:
          'Ensure the device hardware keystore is accessible and authorized.',
    );
  } on DatabaseDecryptionException {
    startupError = const DatabaseStartupError(
      type: DatabaseStartupErrorType.decryptionFailed,
      title: 'Decryption Failed',
      message:
          'Unable to decrypt the database. The security key may be invalid or the database file may be damaged.',
    );
  } on DatabaseCorruptedException {
    startupError = const DatabaseStartupError(
      type: DatabaseStartupErrorType.corrupted,
      title: 'Database Damaged',
      message:
          'The database file is corrupted, truncated, or unreadable. Automatic recovery is not possible without intervention.',
    );
  } catch (e) {
    startupError = const DatabaseStartupError(
      type: DatabaseStartupErrorType.other,
      title: 'Database Initialization Error',
      message:
          'A secure database connection could not be established. Normal operations are suspended.',
    );
  }

  runApp(
    ProviderScope(
      overrides: [
        if (database != null) databaseProvider.overrideWithValue(database),
      ],
      child: startupError != null
          ? DatabaseStartupErrorApp(error: startupError)
          : const VoterLensApp(),
    ),
  );
}

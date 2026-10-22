import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voterlens/app/app.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/presentation/providers/database_provider.dart';
import 'package:voterlens/presentation/screens/database_error_screen.dart';

void main() {
  group('Secure Startup Lifecycle & Provider Security Tests', () {
    test('1. databaseProvider throws StateError when accessed uninitialized', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        () => container.read(databaseProvider),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('databaseProvider was accessed without being initialized'),
          ),
        ),
      );
    });

    test('2. databaseProvider delivers secure database instance when overridden', () {
      final secureDb = AppDatabase.openInMemory();
      addTearDown(secureDb.close);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(secureDb),
        ],
      );
      addTearDown(container.dispose);

      final resolvedDb = container.read(databaseProvider);
      expect(identical(resolvedDb, secureDb), isTrue);
    });

    testWidgets('3. MigrationRequired error screen renders safe UI without sensitive leakage', (tester) async {
      const error = DatabaseStartupError(
        type: DatabaseStartupErrorType.migrationRequired,
        title: 'Database Migration Required',
        message: 'An unencrypted database was detected. Secure SQLCipher encryption must be configured before accessing roll data.',
        recoveryHint: 'Plaintext-to-encrypted database migration will be performed in Step 4.',
      );

      await tester.pumpWidget(
        const ProviderScope(
          child: DatabaseStartupErrorApp(error: error),
        ),
      );
      await tester.pumpAndSettle();

      // Verify safe UI elements are present
      expect(find.text('Security & Storage Guard'), findsOneWidget);
      expect(find.text('Database Migration Required'), findsOneWidget);
      expect(find.textContaining('An unencrypted database was detected'), findsOneWidget);
      expect(find.textContaining('Step 4'), findsOneWidget);

      // Verify normal database-dependent screens are NOT rendered
      expect(find.byType(VoterLensApp), findsNothing);
      expect(find.text('Voters'), findsNothing);
      expect(find.text('Households'), findsNothing);
      expect(find.text('Settings'), findsNothing);
      expect(find.byType(BottomNavigationBar), findsNothing);

      // Verify no sensitive keys or internal file paths leaked
      expect(find.textContaining('SQLite format 3'), findsNothing);
      expect(find.textContaining('key'), findsNothing);
      expect(find.textContaining('/data/'), findsNothing);
    });

    testWidgets('4. KeyNotFound error screen renders safe UI and prevents normal route access', (tester) async {
      const error = DatabaseStartupError(
        type: DatabaseStartupErrorType.keyNotFound,
        title: 'Security Key Inaccessible',
        message: 'An encrypted database was detected, but the encryption key is missing from secure hardware storage.',
        recoveryHint: 'Ensure the device hardware keystore is accessible and authorized.',
      );

      await tester.pumpWidget(
        const ProviderScope(
          child: DatabaseStartupErrorApp(error: error),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Security Key Inaccessible'), findsOneWidget);
      expect(find.textContaining('hardware storage'), findsOneWidget);
      expect(find.byType(VoterLensApp), findsNothing);
      expect(find.text('Voters'), findsNothing);
    });

    testWidgets('5. Corrupted database error screen prevents normal operations', (tester) async {
      const error = DatabaseStartupError(
        type: DatabaseStartupErrorType.corrupted,
        title: 'Database Damaged',
        message: 'The database file is corrupted, truncated, or unreadable. Automatic recovery is not possible without intervention.',
      );

      await tester.pumpWidget(
        const ProviderScope(
          child: DatabaseStartupErrorApp(error: error),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Database Damaged'), findsOneWidget);
      expect(find.byType(VoterLensApp), findsNothing);
      expect(find.text('Voters'), findsNothing);
    });
  });
}

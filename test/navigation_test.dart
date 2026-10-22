import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voterlens/app/app.dart';
import 'package:voterlens/core/constants/field_status.dart';
import 'package:voterlens/presentation/providers/user_role_provider.dart';

import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/presentation/providers/database_provider.dart';

void main() {
  group('MainNavigationShell Tests', () {
    late AppDatabase inMemoryDb;

    setUp(() {
      inMemoryDb = AppDatabase.openInMemory();
    });

    tearDown(() {
      inMemoryDb.close();
    });

    testWidgets('renders all bottom navigation items', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(inMemoryDb),
          ],
          child: const VoterLensApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Voters'), findsOneWidget);
      expect(find.text('Households'), findsOneWidget);
      expect(find.text('Review Queue'), findsOneWidget);
      expect(find.text('Part Stats'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('switches tabs smoothly when tapping bottom navigation bar', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(inMemoryDb),
          ],
          child: const VoterLensApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Tap Settings tab
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Settings & Configuration'), findsOneWidget);
      expect(find.text('Active Electoral Roll'), findsOneWidget);
      expect(find.text('Local Database Diagnostics'), findsOneWidget);
      expect(find.text('Active Operator Role (RBAC)', skipOffstage: false), findsOneWidget);

      // Tap Households tab
      await tester.tap(find.text('Households'));
      await tester.pumpAndSettle();

      expect(find.text('Household Grouping'), findsOneWidget);
      expect(
        find.text('Grouped by normalized house number — organizational convenience only.'),
        findsOneWidget,
      );

      // Tap Part Stats tab
      await tester.tap(find.text('Part Stats'));
      await tester.pumpAndSettle();

      expect(find.text('Part & Booth Analytics'), findsOneWidget);

      // Tap Voters tab
      await tester.tap(find.text('Voters'));
      await tester.pumpAndSettle();

      expect(find.text('VoterLens'), findsOneWidget);
    });
  });

  group('Role-Based Access Control in Settings', () {
    testWidgets('switching roles updates userRoleProvider state', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(userRoleProvider), UserRole.admin);

      container.read(userRoleProvider.notifier).state = UserRole.fieldUser;
      expect(container.read(userRoleProvider), UserRole.fieldUser);
      expect(container.read(userRoleProvider).canUpdateFieldStatus, isTrue);
      expect(container.read(userRoleProvider).canReviewRecords, isFalse);

      container.read(userRoleProvider.notifier).state = UserRole.viewer;
      expect(container.read(userRoleProvider), UserRole.viewer);
      expect(container.read(userRoleProvider).canUpdateFieldStatus, isFalse);
      expect(container.read(userRoleProvider).canReviewRecords, isFalse);
    });
  });
}

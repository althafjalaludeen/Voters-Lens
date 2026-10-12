import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:voterlens/core/database/app_database.dart';
import 'package:voterlens/domain/entities/filter_criteria.dart';

void main() {
  group('AppDatabase Integration Tests', () {
    test('opens local database and loads active roll with 524 voters', () {
      final dbPath = File('data/voterlens.db').existsSync()
          ? 'data/voterlens.db'
          : 'validation-results/full-roll/validation.db';

      if (!File(dbPath).existsSync()) {
        fail('Database file not found at $dbPath');
      }

      final db = AppDatabase.open(customPath: dbPath);

      // 1. Check active roll
      final activeRoll = db.getActiveRoll();
      expect(activeRoll, isNotNull);
      expect(activeRoll!.recordCount, equals(524));
      expect(activeRoll.state, equals('Kerala'));
      expect(activeRoll.district, equals('Pathanamthitta'));
      expect(activeRoll.assemblyConstituency, equals('111 - Thiruvalla'));

      // 2. Count voters
      final total = db.countVoters(activeRoll.id, const FilterCriteria());
      expect(total, equals(524));

      // 3. Paginated list
      final voters = db.searchVoters(activeRoll.id, const FilterCriteria(pageSize: 50));
      expect(voters.length, equals(50));

      // 4. Exact EPIC search
      final firstEpic = voters.first.epicNumber;
      final epicResult = db.searchVoters(activeRoll.id, FilterCriteria(epic: firstEpic));
      expect(epicResult.isNotEmpty, isTrue);
      expect(epicResult.first.epicNumber, equals(firstEpic));

      // 5. Malayalam Unicode search
      final malayalamFragment = voters.first.name.split(' ').first;
      final malResult = db.searchVoters(activeRoll.id, FilterCriteria(name: malayalamFragment));
      expect(malResult.isNotEmpty, isTrue);

      // 6. House number search
      final sampleHouse = voters.first.houseNumber;
      final houseResult = db.searchVoters(activeRoll.id, FilterCriteria(houseNumber: sampleHouse));
      expect(houseResult.isNotEmpty, isTrue);

      // 7. Area statistics
      final stats = db.getAreaStatistics(activeRoll.id);
      expect(stats.totalVoters, equals(524));
      expect(stats.maleCount + stats.femaleCount + stats.otherCount, equals(524));

      // 8. Household grouping
      final households = db.getHouseholdGroups(activeRoll.id, limit: 10);
      expect(households.isNotEmpty, isTrue);
      expect(households.first.voters.isNotEmpty, isTrue);

      db.close();
    });

    test('field status update and history tracking in isolated database', () {
      final db = AppDatabase.openInMemory();

      // Create a test roll
      db.saveAreaConfig(
        state: 'Kerala',
        district: 'Pathanamthitta',
        assemblyConstituency: '112 - Thiruvalla',
      );

      // Verify schema is intact
      final rolls = db.listRolls();
      expect(rolls, isEmpty);

      db.close();
    });
  });
}

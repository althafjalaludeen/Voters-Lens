import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:voterlens/core/constants/field_status.dart';
import 'package:voterlens/domain/entities/field_status_record.dart';
import 'package:voterlens/domain/entities/voter.dart';
import 'package:voterlens/presentation/widgets/search_bar_widget.dart';
import 'package:voterlens/presentation/widgets/status_badge.dart';
import 'package:voterlens/presentation/widgets/voter_card.dart';
import 'package:voterlens/presentation/widgets/voter_photo_widget.dart';

void main() {
  group('StatusBadge Widget Tests', () {
    testWidgets('renders correct status label for no issue', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusBadge(status: FieldStatusType.noIssue),
          ),
        ),
      );

      expect(find.text('No issue reported'), findsOneWidget);
    });

    testWidgets('renders correct status label for away', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusBadge(status: FieldStatusType.away),
          ),
        ),
      );

      expect(find.text('Away'), findsOneWidget);
    });

    testWidgets('renders correct status label for reported deceased', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusBadge(status: FieldStatusType.reportedDeceased),
          ),
        ),
      );

      expect(find.text('Reported deceased'), findsOneWidget);
    });

    testWidgets('renders compact mode without crashing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StatusBadge(status: FieldStatusType.abroad, compact: true),
          ),
        ),
      );

      expect(find.byType(Container), findsWidgets);
      expect(find.text('ABROAD'), findsOneWidget);
    });

    testWidgets('renders ReviewBadge for needsReview', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ReviewBadge(reviewStatus: ReviewStatusType.needsReview),
          ),
        ),
      );

      expect(find.text('NEEDS REVIEW'), findsOneWidget);
    });
  });

  group('VoterPhotoWidget Widget Tests', () {
    testWidgets('renders clean neutral silhouette placeholder when photo is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VoterPhotoWidget(photoPath: null, size: 48),
          ),
        ),
      );

      // Clean neutral placeholder, zero photo fabrication
      expect(find.byIcon(CupertinoIcons.person_fill), findsOneWidget);
    });

    testWidgets('renders clean placeholder when photo file does not exist', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: VoterPhotoWidget(photoPath: 'non_existent_file.jpg', size: 48),
          ),
        ),
      );

      expect(find.byIcon(CupertinoIcons.person_fill), findsOneWidget);
    });
  });

  group('VoterCard Widget Tests', () {
    const testVoter = Voter(
      id: 'voter-1',
      rollVersionId: 'roll-1',
      serialNumber: 12,
      epicNumber: 'KL/14/098/123456',
      name: 'രാഹുൽ കുമാർ',
      normalizedName: 'rahul kumar',
      relativeName: 'സുരേഷ് കുമാർ',
      normalizedRelativeName: 'suresh kumar',
      relativeType: 'FTHR',
      houseNumber: '14/235',
      normalizedHouseNumber: '14/235',
      age: 34,
      gender: 'M',
      partNumber: '1',
      sectionNumber: '1',
      sectionName: 'Main Road',
      pollingStationName: 'Govt Higher Secondary School',
      pollingStationAddress: 'Thiruvalla',
      fieldStatus: FieldStatusRecord(
        status: FieldStatusType.away,
        reviewStatus: ReviewStatusType.needsReview,
      ),
    );

    testWidgets('renders EPIC, name, house, age, and status badges', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoterCard(
              voter: testVoter,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('KL/14/098/123456'), findsOneWidget);
      expect(find.text('രാഹുൽ കുമാർ'), findsOneWidget);
      expect(find.text('#12'), findsOneWidget);
      expect(find.text('•  House: 14/235'), findsOneWidget);
      expect(find.text('Age 34 • M'), findsOneWidget);
      expect(find.text('AWAY'), findsOneWidget);
      expect(find.text('NEEDS REVIEW'), findsOneWidget);
    });
  });

  group('SearchBarWidget Widget Tests', () {
    testWidgets('displays placeholder, handles input, and shows filter badge', (tester) async {
      String? enteredQuery;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchBarWidget(
              initialValue: 'Anil',
              activeFilterCount: 2,
              onChanged: (val) {
                enteredQuery = val;
              },
              onFilterTap: () {},
              onSortTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Anil'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // 2 active filters
      expect(find.byIcon(CupertinoIcons.slider_horizontal_3), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.arrow_up_arrow_down), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Suresh');
      await tester.pump(const Duration(milliseconds: 300));
      expect(enteredQuery, 'Suresh');
    });
  });
}

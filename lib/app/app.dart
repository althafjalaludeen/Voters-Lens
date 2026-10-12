import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_colors.dart';
import '../core/theme/app_theme.dart';
import '../presentation/providers/sync_provider.dart';
import '../presentation/providers/user_role_provider.dart';
import '../presentation/providers/voter_providers.dart';
import '../presentation/screens/household_view_screen.dart';
import '../presentation/screens/part_view_screen.dart';
import '../presentation/screens/review_queue_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/sync_screen.dart';
import '../presentation/screens/voter_list_screen.dart';

class VoterLensApp extends ConsumerWidget {
  const VoterLensApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'VoterLens',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      debugShowCheckedModeBanner: false,
      home: const MainNavigationShell(),
    );
  }
}

class MainNavigationShell extends ConsumerStatefulWidget {
  const MainNavigationShell({super.key});

  @override
  ConsumerState<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends ConsumerState<MainNavigationShell> {
  int _selectedIndex = 0;

  static const List<Widget> _screens = [
    VoterListScreen(),
    HouseholdViewScreen(),
    ReviewQueueScreen(),
    PartViewScreen(),
    SyncScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reviewQueue = ref.watch(reviewQueueProvider);
    final reviewCount = reviewQueue.length;
    final pendingConflicts = ref.watch(pendingConflictsProvider);
    final conflictCount = pendingConflicts.length;

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: isDark ? AppColors.borderDark : AppColors.borderLight,
              width: 0.5,
            ),
          ),
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) {
            setState(() {
              _selectedIndex = index;
            });
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
          selectedItemColor: AppColors.primary,
          unselectedItemColor: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
          selectedFontSize: 11,
          unselectedFontSize: 11,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.person_2),
              activeIcon: Icon(CupertinoIcons.person_2_fill),
              label: 'Voters',
            ),
            const BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.house),
              activeIcon: Icon(CupertinoIcons.house_fill),
              label: 'Households',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: reviewCount > 0,
                label: Text(
                  '$reviewCount',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
                backgroundColor: AppColors.reviewNeedsReview,
                child: const Icon(CupertinoIcons.exclamationmark_shield),
              ),
              activeIcon: Badge(
                isLabelVisible: reviewCount > 0,
                label: Text(
                  '$reviewCount',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
                backgroundColor: AppColors.reviewNeedsReview,
                child: const Icon(CupertinoIcons.exclamationmark_shield_fill),
              ),
              label: 'Review Queue',
            ),
            const BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.chart_bar),
              activeIcon: Icon(CupertinoIcons.chart_bar_fill),
              label: 'Part Stats',
            ),
            BottomNavigationBarItem(
              icon: Badge(
                isLabelVisible: conflictCount > 0,
                label: Text(
                  '$conflictCount',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
                backgroundColor: AppColors.reviewNeedsReview,
                child: const Icon(CupertinoIcons.arrow_2_squarepath),
              ),
              activeIcon: Badge(
                isLabelVisible: conflictCount > 0,
                label: Text(
                  '$conflictCount',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
                backgroundColor: AppColors.reviewNeedsReview,
                child: const Icon(CupertinoIcons.arrow_2_squarepath),
              ),
              label: 'Sync',
            ),
            const BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.gear_alt),
              activeIcon: Icon(CupertinoIcons.gear_alt_fill),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';
import '../../domain/entities/filter_criteria.dart';
import '../providers/filter_provider.dart';
import '../providers/roll_providers.dart';
import '../providers/voter_providers.dart';
import '../widgets/filter_bottom_sheet.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/sort_action_sheet.dart';
import '../widgets/voter_card.dart';
import 'sync_screen.dart';
import 'voter_profile_screen.dart';

class VoterListScreen extends ConsumerWidget {
  const VoterListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeRoll = ref.watch(activeRollProvider);
    final criteria = ref.watch(filterCriteriaProvider);
    final voters = ref.watch(voterListProvider);
    final totalCount = ref.watch(voterTotalCountProvider);
    final availableParts = ref.watch(partsListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('VoterLens', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
            const SizedBox(height: 1),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: AppColors.statusNoIssue,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    activeRoll != null
                        ? '${activeRoll.assemblyConstituency} • ${activeRoll.rollName}'
                        : 'Offline Local Database',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
            ),
            child: Row(
              children: [
                Icon(CupertinoIcons.circle_filled, size: 8, color: AppColors.primary),
                const SizedBox(width: 5),
                Text(
                  '$totalCount voters',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Search Bar & Controls
          SearchBarWidget(
            initialValue: criteria.query,
            activeFilterCount: criteria.activeFilterCount,
            onChanged: (val) {
              ref.read(filterCriteriaProvider.notifier).setQuery(val.trim().isNotEmpty ? val.trim() : null);
            },
            onFilterTap: () {
              FilterBottomSheet.show(
                context,
                criteria: criteria,
                availableParts: availableParts,
                onApply: (updated) {
                  ref.read(filterCriteriaProvider.notifier).setCriteria(updated);
                },
              );
            },
            onSortTap: () {
              SortActionSheet.show(
                context,
                currentSortBy: criteria.sortBy,
                currentOrder: criteria.sortOrder,
                onSelected: (by, order) {
                  ref.read(filterCriteriaProvider.notifier).setSort(by, order);
                },
              );
            },
          ),

          // 2. Quick Filter Chips Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                _buildQuickChip(
                  context,
                  label: 'All ($totalCount)',
                  selected: criteria.fieldStatus == null && criteria.reviewStatus == null,
                  onTap: () {
                    ref.read(filterCriteriaProvider.notifier).clearFilters();
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  context,
                  label: '🟡 Away',
                  selected: criteria.fieldStatus == FieldStatusType.away,
                  activeColor: AppColors.statusAway,
                  onTap: () {
                    final curr = criteria.fieldStatus == FieldStatusType.away;
                    ref.read(filterCriteriaProvider.notifier).setFieldStatus(curr ? null : FieldStatusType.away);
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  context,
                  label: '🔵 Abroad',
                  selected: criteria.fieldStatus == FieldStatusType.abroad,
                  activeColor: AppColors.statusAbroad,
                  onTap: () {
                    final curr = criteria.fieldStatus == FieldStatusType.abroad;
                    ref.read(filterCriteriaProvider.notifier).setFieldStatus(curr ? null : FieldStatusType.abroad);
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  context,
                  label: '🔴 Deceased',
                  selected: criteria.fieldStatus == FieldStatusType.reportedDeceased,
                  activeColor: AppColors.statusDeceased,
                  onTap: () {
                    final curr = criteria.fieldStatus == FieldStatusType.reportedDeceased;
                    ref.read(filterCriteriaProvider.notifier).setFieldStatus(curr ? null : FieldStatusType.reportedDeceased);
                  },
                ),
                const SizedBox(width: 6),
                _buildQuickChip(
                  context,
                  label: '⚠ Needs Review',
                  selected: criteria.reviewStatus == ReviewStatusType.needsReview,
                  activeColor: AppColors.reviewNeedsReview,
                  onTap: () {
                    final curr = criteria.reviewStatus == ReviewStatusType.needsReview;
                    ref.read(filterCriteriaProvider.notifier).setReviewStatus(curr ? null : ReviewStatusType.needsReview);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // 3. Virtualized Lazy-Loaded Voter List
          Expanded(
            child: voters.isEmpty
                ? _buildEmptyState(context, isDark, criteria, activeRoll != null)
                : ListView.builder(
                    itemCount: voters.length,
                    padding: const EdgeInsets.only(bottom: 24),
                    itemBuilder: (context, index) {
                      final voter = voters[index];
                      return VoterCard(
                        voter: voter,
                        onTap: () {
                          ref.read(selectedVoterIdProvider.notifier).state = voter.id;
                          Navigator.push(
                            context,
                            CupertinoPageRoute(
                              builder: (_) => VoterProfileScreen(voterId: voter.id),
                            ),
                          ).then((_) {
                            // Refresh list if status was updated
                            ref.invalidate(voterListProvider);
                            ref.invalidate(voterTotalCountProvider);
                          });
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = activeColor ?? AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.14)
              : (isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? color : (isDark ? AppColors.borderDark : AppColors.borderLight),
            width: selected ? 1.0 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? color : (isDark ? AppColors.textPrimaryDark : AppColors.textSecondaryLight),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark, FilterCriteria criteria, bool hasActiveRoll) {
    if (!hasActiveRoll) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                CupertinoIcons.doc_text_search,
                size: 54,
                color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
              ),
              const SizedBox(height: 14),
              Text(
                'No Electoral Roll Loaded',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'No active electoral roll is loaded in this local database. Please seed or import an official roll to view and search voters.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => const SyncScreen(),
                    ),
                  );
                },
                icon: const Icon(CupertinoIcons.arrow_down_doc_fill, size: 16),
                label: const Text('Bootstrap from Gazette Snapshot'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.search,
              size: 48,
              color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
            ),
            const SizedBox(height: 12),
            Text(
              'No Voters Found',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              criteria.query != null && criteria.query!.isNotEmpty
                  ? 'No voter matches "${criteria.query}". Try a different spelling or check your active filters.'
                  : 'No voter matches the active filter criteria.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

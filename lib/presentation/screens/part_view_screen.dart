import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_colors.dart';
import '../providers/filter_provider.dart';
import '../providers/roll_providers.dart';
import '../providers/voter_providers.dart';

class PartViewScreen extends ConsumerWidget {
  const PartViewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeRoll = ref.watch(activeRollProvider);
    final stats = ref.watch(areaStatsProvider);
    final parts = ref.watch(partsListProvider);
    final criteria = ref.watch(filterCriteriaProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Part & Booth Analytics', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // Constituency Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activeRoll?.assemblyConstituency ?? 'Assembly Constituency',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${activeRoll?.state ?? "Kerala"} • ${activeRoll?.district ?? "District"}',
                  style: TextStyle(fontSize: 12, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                ),
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),

                // Part selector chips
                const Text('Filter by Polling Part:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: const Text('All Parts', style: TextStyle(fontSize: 11)),
                      selected: criteria.partNumber == null,
                      onSelected: (_) => ref.read(filterCriteriaProvider.notifier).setPartNumber(null),
                    ),
                    ...parts.map((p) => ChoiceChip(
                          label: Text('Part $p', style: const TextStyle(fontSize: 11)),
                          selected: criteria.partNumber == p,
                          onSelected: (sel) => ref.read(filterCriteriaProvider.notifier).setPartNumber(sel ? p : null),
                        )),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (stats != null) ...[
            // Total Voters Card
            _buildStatCard(
              isDark: isDark,
              icon: CupertinoIcons.person_3_fill,
              iconColor: AppColors.primary,
              title: 'Total Registered Voters',
              value: '${stats.totalVoters}',
              subtitle: 'Statutory verified electoral roll count',
            ),
            const SizedBox(height: 12),

            // Gender Distribution
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Gender Breakdown', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMetricTile(
                          isDark: isDark,
                          label: 'Male',
                          count: stats.maleCount,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          isDark: isDark,
                          label: 'Female',
                          count: stats.femaleCount,
                          color: const Color(0xFFEC4899),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildMetricTile(
                          isDark: isDark,
                          label: 'Other',
                          count: stats.otherCount,
                          color: const Color(0xFF8B5CF6),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Field Verification Breakdown
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Field Observations Status', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  _buildStatusProgressRow('🟢 No Issue Reported', stats.noIssueCount, stats.totalVoters, AppColors.statusNoIssue),
                  const SizedBox(height: 8),
                  _buildStatusProgressRow('🟡 Away', stats.awayCount, stats.totalVoters, AppColors.statusAway),
                  const SizedBox(height: 8),
                  _buildStatusProgressRow('🔵 Abroad', stats.abroadCount, stats.totalVoters, AppColors.statusAbroad),
                  const SizedBox(height: 8),
                  _buildStatusProgressRow('🔴 Reported Deceased', stats.deceasedCount, stats.totalVoters, AppColors.statusDeceased),
                  const SizedBox(height: 8),
                  _buildStatusProgressRow('🟠 Unable to Verify', stats.unableCount, stats.totalVoters, AppColors.statusUnableToVerify),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Review Queue Metrics
            _buildStatCard(
              isDark: isDark,
              icon: CupertinoIcons.exclamationmark_triangle_fill,
              iconColor: AppColors.reviewNeedsReview,
              title: 'Records Requiring Review',
              value: '${stats.needsReviewCount}',
              subtitle: 'Flagged for OCR or extraction anomaly verification',
            ),
            const SizedBox(height: 24),
          ],
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required bool isDark,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 11, color: isDark ? AppColors.textTertiaryDark : AppColors.textSecondaryLight)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricTile({
    required bool isDark,
    required String label,
    required int count,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          const SizedBox(height: 4),
          Text('$count', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }

  Widget _buildStatusProgressRow(String label, int count, int total, Color color) {
    final pct = total > 0 ? (count / total) : 0.0;
    return Row(
      children: [
        SizedBox(
          width: 150,
          child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: color.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 40,
          child: Text(
            '$count',
            textAlign: TextAlign.end,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

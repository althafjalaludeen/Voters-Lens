import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_typography.dart';
import '../providers/roll_providers.dart';
import '../providers/user_role_provider.dart';
import '../providers/voter_providers.dart';
import 'voter_profile_screen.dart';

class ReviewQueueScreen extends ConsumerWidget {
  const ReviewQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeRoll = ref.watch(activeRollProvider);
    final queue = ref.watch(reviewQueueProvider);
    final userRole = ref.watch(userRoleProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review Queue', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.reviewNeedsReview.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.3), width: 0.8),
            ),
            child: Text(
              '${queue.length} Flagged',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.reviewNeedsReview),
            ),
          ),
        ],
      ),
      body: queue.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(CupertinoIcons.checkmark_seal_fill, size: 54, color: AppColors.statusNoIssue),
                    const SizedBox(height: 12),
                    Text(
                      'Review Queue Clean',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'All imported voter cards in "${activeRoll?.rollName ?? "Active Roll"}" have passed verification or have been resolved.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: queue.length,
              itemBuilder: (context, index) {
                final voter = queue[index];
                final reasons = voter.fieldStatus.reviewReasons;

                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              voter.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                fontFamilyFallback: AppTypography.fontFallbacks,
                                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              voter.epicNumber.isNotEmpty ? voter.epicNumber : 'MISSING EPIC',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Serial #${voter.serialNumber} • Part ${voter.partNumber} • House: ${voter.houseNumber.isNotEmpty ? voter.houseNumber : "Missing"}',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Anomaly tags
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: reasons.map((r) {
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.reviewNeedsReview.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.3), width: 0.5),
                            ),
                            child: Text(
                              '⚠ ${r.replaceAll('_', ' ')}',
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.reviewNeedsReview),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 6),

                      // Actions
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            child: const Text('View Record', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              ref.read(selectedVoterIdProvider.notifier).state = voter.id;
                              Navigator.push(
                                context,
                                CupertinoPageRoute(builder: (_) => VoterProfileScreen(voterId: voter.id)),
                              );
                            },
                          ),
                          if (userRole.canReviewRecords) ...[
                            const SizedBox(width: 8),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.reviewReviewed,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                elevation: 0,
                              ),
                              onPressed: () {
                                ref.read(reviewQueueProvider.notifier).markReviewed(
                                      voter.id,
                                      reviewer: userRole.value,
                                      notes: 'Audited and approved by supervisor',
                                    );
                              },
                              child: const Text('Mark Reviewed', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

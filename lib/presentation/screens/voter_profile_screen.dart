import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_typography.dart';
import '../../core/constants/field_status.dart';
import '../providers/database_provider.dart';
import '../providers/user_role_provider.dart';
import '../widgets/field_status_sheet.dart';
import '../widgets/status_badge.dart';
import '../widgets/voter_photo_widget.dart';

class VoterProfileScreen extends ConsumerStatefulWidget {
  final String voterId;

  const VoterProfileScreen({super.key, required this.voterId});

  @override
  ConsumerState<VoterProfileScreen> createState() => _VoterProfileScreenState();
}

class _VoterProfileScreenState extends ConsumerState<VoterProfileScreen> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final repo = ref.watch(voterRepositoryProvider);
    final userRole = ref.watch(userRoleProvider);
    final voter = repo.getVoterById(widget.voterId);

    if (voter == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Voter Profile')),
        body: const Center(child: Text('Voter record not found.')),
      );
    }

    final dateFormat = DateFormat('dd MMM yyyy, hh:mm a');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Voter Profile'),
        actions: [
          if (userRole.canUpdateFieldStatus)
            TextButton.icon(
              icon: const Icon(CupertinoIcons.pencil, size: 16),
              label: const Text('Edit Observation', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              onPressed: () {
                FieldStatusSheet.show(
                  context,
                  voter: voter,
                  onSave: (status, notes, phone) {
                    repo.updateFieldInfo(
                      voter.id,
                      status: status,
                      notes: notes,
                      phoneNumber: phone,
                      user: userRole.value,
                    );
                    setState(() {});
                  },
                );
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        children: [
          // 1. Header Card (Photo + Name + Badges)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VoterPhotoWidget(
                  photoPath: voter.photoPath,
                  size: 80,
                  borderRadius: 14,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        voter.name,
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          fontFamilyFallback: AppTypography.fontFallbacks,
                          color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              voter.epicNumber,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Serial #${voter.serialNumber}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          StatusBadge(status: voter.fieldStatus.status),
                          ReviewBadge(reviewStatus: voter.fieldStatus.reviewStatus),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Review Anomaly Warning Banner (if NEEDS_REVIEW)
          if (voter.fieldStatus.reviewStatus == ReviewStatusType.needsReview) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.reviewNeedsReview.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.reviewNeedsReview.withValues(alpha: 0.3), width: 0.8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(CupertinoIcons.exclamationmark_triangle_fill, color: AppColors.reviewNeedsReview, size: 16),
                      SizedBox(width: 8),
                      Text(
                        'Needs Manual Review',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.reviewNeedsReview),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'This record was flagged during OCR validation. Official values remain preserved and unchanged.',
                    style: TextStyle(fontSize: 12, color: isDark ? AppColors.textSecondaryDark : AppColors.textPrimaryLight),
                  ),
                  if (voter.fieldStatus.reviewReasons.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: voter.fieldStatus.reviewReasons.map((r) {
                        return Chip(
                          label: Text(r.replaceAll('_', ' '), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          backgroundColor: Colors.white.withValues(alpha: 0.6),
                        );
                      }).toList(),
                    ),
                  ],
                  if (userRole.canReviewRecords) ...[
                    const SizedBox(height: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.reviewNeedsReview,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(36),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                      onPressed: () {
                        repo.markAsReviewed(voter.id, reviewer: userRole.value, notes: 'Verified by ${userRole.title}');
                        setState(() {});
                      },
                      child: const Text('Mark as Reviewed', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // 3. Official Statutory Electoral Information (Read-Only)
          _buildCard(
            context,
            isDark: isDark,
            title: 'Official Electoral Information',
            badge: 'STATUTORY • READ ONLY',
            badgeColor: AppColors.textSecondaryLight,
            children: [
              _buildInfoRow('Full Name (Official)', voter.name, isDark),
              _buildInfoRow('Relative Name', '${voter.relativeName} (${voter.relativeType})', isDark),
              _buildInfoRow('House Number', voter.houseNumber.isNotEmpty ? voter.houseNumber : 'Not Specified', isDark),
              _buildInfoRow('Age & Gender', '${voter.age} years • ${voter.gender}', isDark),
              _buildInfoRow('Electoral Part', 'Part ${voter.partNumber}', isDark),
              _buildInfoRow('Section', '${voter.sectionNumber.isNotEmpty ? voter.sectionNumber : "-"} - ${voter.sectionName}', isDark),
              _buildInfoRow('Polling Station', voter.pollingStationName.isNotEmpty ? voter.pollingStationName : 'Not Specified', isDark),
              _buildInfoRow('Station Address', voter.pollingStationAddress.isNotEmpty ? voter.pollingStationAddress : 'Not Specified', isDark),
            ],
          ),
          const SizedBox(height: 16),

          // 4. Local Field Information (Editable & Audited)
          _buildCard(
            context,
            isDark: isDark,
            title: 'Local Field Observations',
            badge: 'LOCAL FIELD DATA',
            badgeColor: AppColors.primary,
            children: [
              _buildInfoRow('Field Status', voter.fieldStatus.status.label, isDark),
              _buildInfoRow(
                'Resident Phone',
                voter.fieldStatus.phoneNumber != null && voter.fieldStatus.phoneNumber!.isNotEmpty
                    ? voter.fieldStatus.phoneNumber!
                    : 'No phone number recorded',
                isDark,
              ),
              _buildInfoRow(
                'Observation Notes',
                voter.fieldStatus.notes != null && voter.fieldStatus.notes!.isNotEmpty
                    ? voter.fieldStatus.notes!
                    : 'No observation notes recorded',
                isDark,
              ),
              _buildInfoRow('Review Status', voter.fieldStatus.reviewStatus.label, isDark),
              if (voter.fieldStatus.reviewedBy != null)
                _buildInfoRow('Reviewed By', '${voter.fieldStatus.reviewedBy} on ${dateFormat.format(voter.fieldStatus.reviewedAt!)}', isDark),
            ],
          ),
          const SizedBox(height: 16),

          // 5. Field Status Audit History
          _buildCard(
            context,
            isDark: isDark,
            title: 'Status Transition History',
            badge: '${voter.fieldStatus.history.length} TRANSITIONS',
            badgeColor: AppColors.primary,
            children: [
              if (voter.fieldStatus.history.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No status transitions recorded yet. Initial state is NO_ISSUE.',
                    style: TextStyle(fontSize: 12, color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight),
                  ),
                )
              else
                ...voter.fieldStatus.history.reversed.map((h) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 3),
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${h.oldStatus}  →  ${h.newStatus}',
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Changed by ${h.changedBy ?? "operator"} • ${dateFormat.format(h.changedAt)}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                                ),
                              ),
                              if (h.notes != null && h.notes!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  '"${h.notes}"',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic,
                                    color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildCard(
    BuildContext context, {
    required bool isDark,
    required String title,
    required String badge,
    required Color badgeColor,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badge,
                  style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: badgeColor, letterSpacing: 0.3),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: AppTypography.fontFallbacks,
                color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

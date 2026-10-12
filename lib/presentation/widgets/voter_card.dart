import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_typography.dart';
import '../../domain/entities/voter.dart';
import 'status_badge.dart';
import 'voter_photo_widget.dart';

class VoterCard extends StatelessWidget {
  final Voter voter;
  final VoidCallback onTap;

  const VoterCard({
    super.key,
    required this.voter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isDark ? AppColors.borderDark : AppColors.borderLight,
                width: 0.8,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Photo / Placeholder
                VoterPhotoWidget(
                  photoPath: voter.photoPath,
                  size: 58,
                  borderRadius: 10,
                ),
                const SizedBox(width: 12),

                // 2. Central Details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name & Serial
                      Row(
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isDark ? AppColors.surfaceElevatedDark : AppColors.surfaceElevatedLight,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '#${voter.serialNumber}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),

                      // EPIC & House
                      Row(
                        children: [
                          Text(
                            voter.epicNumber,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.primary,
                              letterSpacing: 0.4,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '•  House: ${voter.houseNumber.isNotEmpty ? voter.houseNumber : "-"}',
                            style: TextStyle(
                              fontSize: 12,
                              fontFamilyFallback: AppTypography.fontFallbacks,
                              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),

                      // Age • Gender
                      Text(
                        'Age ${voter.age} • ${voter.gender}',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamilyFallback: AppTypography.fontFallbacks,
                          color: isDark ? AppColors.textTertiaryDark : AppColors.textSecondaryLight,
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Status & Badges
                      Row(
                        children: [
                          StatusBadge(status: voter.fieldStatus.status, compact: true),
                          const SizedBox(width: 6),
                          ReviewBadge(reviewStatus: voter.fieldStatus.reviewStatus),
                          if (voter.fieldStatus.phoneNumber != null) ...[
                            const SizedBox(width: 6),
                            Icon(
                              CupertinoIcons.phone_fill,
                              size: 11,
                              color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),

                // Trailing disclosure arrow
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Icon(
                    CupertinoIcons.chevron_forward,
                    size: 14,
                    color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiaryLight,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/field_status.dart';

class StatusBadge extends StatelessWidget {
  final FieldStatusType status;
  final bool compact;

  const StatusBadge({
    super.key,
    required this.status,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    Color bg;
    switch (status) {
      case FieldStatusType.noIssue:
        bg = AppColors.statusNoIssueBg;
        break;
      case FieldStatusType.away:
        bg = AppColors.statusAwayBg;
        break;
      case FieldStatusType.abroad:
        bg = AppColors.statusAbroadBg;
        break;
      case FieldStatusType.reportedDeceased:
        bg = AppColors.statusDeceasedBg;
        break;
      case FieldStatusType.unableToVerify:
        bg = AppColors.statusUnableToVerifyBg;
        break;
    }

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: status.color.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: compact ? 10 : 12, color: status.color),
          const SizedBox(width: 4),
          Text(
            compact ? status.name.toUpperCase() : status.label.split(' ').sublist(1).join(' '),
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: status.color,
            ),
          ),
        ],
      ),
    );
  }
}

class ReviewBadge extends StatelessWidget {
  final ReviewStatusType reviewStatus;

  const ReviewBadge({super.key, required this.reviewStatus});

  @override
  Widget build(BuildContext context) {
    if (reviewStatus != ReviewStatusType.needsReview) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.reviewNeedsReview.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.reviewNeedsReview.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(reviewStatus.icon, size: 10, color: AppColors.reviewNeedsReview),
          const SizedBox(width: 3),
          const Text(
            'NEEDS REVIEW',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              color: AppColors.reviewNeedsReview,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

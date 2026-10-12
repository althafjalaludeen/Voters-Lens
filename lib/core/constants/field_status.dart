import 'package:flutter/cupertino.dart';
import 'app_colors.dart';

enum FieldStatusType {
  noIssue('NO_ISSUE', '🟢 No issue reported', AppColors.statusNoIssue, CupertinoIcons.checkmark_circle_fill),
  away('AWAY', '🟡 Away', AppColors.statusAway, CupertinoIcons.clock_fill),
  abroad('ABROAD', '🔵 Currently abroad', AppColors.statusAbroad, CupertinoIcons.airplane),
  reportedDeceased('REPORTED_DECEASED', '🔴 Reported deceased', AppColors.statusDeceased, CupertinoIcons.xmark_circle_fill),
  unableToVerify('UNABLE_TO_VERIFY', '🟠 Unable to verify', AppColors.statusUnableToVerify, CupertinoIcons.question_circle_fill);

  final String value;
  final String label;
  final Color color;
  final IconData icon;

  const FieldStatusType(this.value, this.label, this.color, this.icon);

  static FieldStatusType fromString(String? val) {
    if (val == null) return FieldStatusType.noIssue;
    for (final s in FieldStatusType.values) {
      if (s.value == val.toUpperCase()) return s;
    }
    return FieldStatusType.noIssue;
  }
}

enum ReviewStatusType {
  notReviewed('NOT_REVIEWED', 'Not Reviewed', AppColors.reviewNotReviewed, CupertinoIcons.circle),
  needsReview('NEEDS_REVIEW', 'Needs Review', AppColors.reviewNeedsReview, CupertinoIcons.exclamationmark_triangle_fill),
  reviewed('REVIEWED', 'Reviewed', AppColors.reviewReviewed, CupertinoIcons.checkmark_seal_fill);

  final String value;
  final String label;
  final Color color;
  final IconData icon;

  const ReviewStatusType(this.value, this.label, this.color, this.icon);

  static ReviewStatusType fromString(String? val) {
    if (val == null) return ReviewStatusType.notReviewed;
    for (final s in ReviewStatusType.values) {
      if (s.value == val.toUpperCase()) return s;
    }
    return ReviewStatusType.notReviewed;
  }
}

enum UserRole {
  admin('ADMIN', 'Administrator', CupertinoIcons.shield_fill),
  manager('MANAGER', 'Supervisor / Manager', CupertinoIcons.person_2_fill),
  fieldUser('FIELD_USER', 'Field Operator', CupertinoIcons.person_badge_plus_fill),
  viewer('VIEWER', 'Read-Only Viewer', CupertinoIcons.eye_fill);

  final String value;
  final String title;
  final IconData icon;

  const UserRole(this.value, this.title, this.icon);

  static UserRole fromString(String? val) {
    if (val == null) return UserRole.viewer;
    for (final r in UserRole.values) {
      if (r.value == val.toUpperCase()) return r;
    }
    return UserRole.viewer;
  }

  bool get canManageRolls => this == UserRole.admin;
  bool get canUpdateFieldStatus => this == UserRole.admin || this == UserRole.manager || this == UserRole.fieldUser;
  bool get canReviewRecords => this == UserRole.admin || this == UserRole.manager;
  bool get canViewAuditLogs => this == UserRole.admin || this == UserRole.manager;
}

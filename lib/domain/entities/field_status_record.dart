import '../../core/constants/field_status.dart';

class FieldStatusHistoryEntry {
  final String id;
  final String voterId;
  final String oldStatus;
  final String newStatus;
  final String? notes;
  final String? changedBy;
  final DateTime changedAt;

  const FieldStatusHistoryEntry({
    required this.id,
    required this.voterId,
    required this.oldStatus,
    required this.newStatus,
    this.notes,
    this.changedBy,
    required this.changedAt,
  });
}

class FieldStatusRecord {
  final FieldStatusType status;
  final String? phoneNumber;
  final String? notes;
  final ReviewStatusType reviewStatus;
  final List<String> reviewReasons;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reportedBy;
  final DateTime? reportedAt;
  final List<FieldStatusHistoryEntry> history;

  const FieldStatusRecord({
    this.status = FieldStatusType.noIssue,
    this.phoneNumber,
    this.notes,
    this.reviewStatus = ReviewStatusType.notReviewed,
    this.reviewReasons = const [],
    this.reviewedBy,
    this.reviewedAt,
    this.reportedBy,
    this.reportedAt,
    this.history = const [],
  });

  const FieldStatusRecord.initial()
      : status = FieldStatusType.noIssue,
        phoneNumber = null,
        notes = null,
        reviewStatus = ReviewStatusType.notReviewed,
        reviewReasons = const [],
        reviewedBy = null,
        reviewedAt = null,
        reportedBy = null,
        reportedAt = null,
        history = const [];

  FieldStatusRecord copyWith({
    FieldStatusType? status,
    String? phoneNumber,
    String? notes,
    ReviewStatusType? reviewStatus,
    List<String>? reviewReasons,
    String? reviewedBy,
    DateTime? reviewedAt,
    String? reportedBy,
    DateTime? reportedAt,
    List<FieldStatusHistoryEntry>? history,
  }) {
    return FieldStatusRecord(
      status: status ?? this.status,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      notes: notes ?? this.notes,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reviewReasons: reviewReasons ?? this.reviewReasons,
      reviewedBy: reviewedBy ?? this.reviewedBy,
      reviewedAt: reviewedAt ?? this.reviewedAt,
      reportedBy: reportedBy ?? this.reportedBy,
      reportedAt: reportedAt ?? this.reportedAt,
      history: history ?? this.history,
    );
  }
}

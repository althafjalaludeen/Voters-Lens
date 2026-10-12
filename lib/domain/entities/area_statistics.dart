class AreaStatistics {
  final int totalVoters;
  final String? partNumber;
  final Map<String, int> genderCounts;
  final Map<String, int> fieldStatusCounts;
  final Map<String, int> reviewStatusCounts;

  const AreaStatistics({
    required this.totalVoters,
    this.partNumber,
    required this.genderCounts,
    required this.fieldStatusCounts,
    required this.reviewStatusCounts,
  });

  int get maleCount => genderCounts['M'] ?? genderCounts['Male'] ?? genderCounts['പുരുഷൻ'] ?? 0;
  int get femaleCount => genderCounts['F'] ?? genderCounts['Female'] ?? genderCounts['സ്ത്രീ'] ?? 0;
  int get otherCount => totalVoters - (maleCount + femaleCount);

  int get noIssueCount => fieldStatusCounts['NO_ISSUE'] ?? 0;
  int get awayCount => fieldStatusCounts['AWAY'] ?? 0;
  int get abroadCount => fieldStatusCounts['ABROAD'] ?? 0;
  int get deceasedCount => fieldStatusCounts['REPORTED_DECEASED'] ?? 0;
  int get unableCount => fieldStatusCounts['UNABLE_TO_VERIFY'] ?? 0;

  int get needsReviewCount => reviewStatusCounts['NEEDS_REVIEW'] ?? 0;
  int get reviewedCount => reviewStatusCounts['REVIEWED'] ?? 0;
}

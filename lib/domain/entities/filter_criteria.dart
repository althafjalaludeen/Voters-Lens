import '../../core/constants/field_status.dart';

enum SortBy {
  serialNumber('serial_number', 'Serial Number'),
  name('name', 'Voter Name'),
  houseNumber('house_number', 'House Number'),
  age('age', 'Age'),
  partNumber('part_number', 'Part Number');

  final String value;
  final String label;
  const SortBy(this.value, this.label);
}

enum SortOrder {
  asc('asc', 'Ascending'),
  desc('desc', 'Descending');

  final String value;
  final String label;
  const SortOrder(this.value, this.label);
}

enum GenderOption {
  all('ALL', 'All Genders'),
  male('M', 'Male (പുരുഷൻ)'),
  female('F', 'Female (സ്ത്രീ)'),
  other('O', 'Other');

  final String value;
  final String label;
  const GenderOption(this.value, this.label);
}

class FilterCriteria {
  final String? query;
  final String? name;
  final String? epic;
  final String? relativeName;
  final String? houseNumber;
  final GenderOption gender;
  final String? partNumber;
  final FieldStatusType? fieldStatus;
  final ReviewStatusType? reviewStatus;
  final SortBy sortBy;
  final SortOrder sortOrder;
  final int page;
  final int pageSize;

  const FilterCriteria({
    this.query,
    this.name,
    this.epic,
    this.relativeName,
    this.houseNumber,
    this.gender = GenderOption.all,
    this.partNumber,
    this.fieldStatus,
    this.reviewStatus,
    this.sortBy = SortBy.serialNumber,
    this.sortOrder = SortOrder.asc,
    this.page = 1,
    this.pageSize = 50,
  });

  int get activeFilterCount {
    int count = 0;
    if (gender != GenderOption.all) count++;
    if (partNumber != null && partNumber!.isNotEmpty) count++;
    if (fieldStatus != null) count++;
    if (reviewStatus != null) count++;
    if (houseNumber != null && houseNumber!.isNotEmpty) count++;
    if (relativeName != null && relativeName!.isNotEmpty) count++;
    return count;
  }

  FilterCriteria copyWith({
    String? query,
    String? name,
    String? epic,
    String? relativeName,
    String? houseNumber,
    GenderOption? gender,
    String? partNumber,
    FieldStatusType? fieldStatus,
    bool clearFieldStatus = false,
    ReviewStatusType? reviewStatus,
    bool clearReviewStatus = false,
    SortBy? sortBy,
    SortOrder? sortOrder,
    int? page,
    int? pageSize,
  }) {
    return FilterCriteria(
      query: query ?? this.query,
      name: name ?? this.name,
      epic: epic ?? this.epic,
      relativeName: relativeName ?? this.relativeName,
      houseNumber: houseNumber ?? this.houseNumber,
      gender: gender ?? this.gender,
      partNumber: partNumber ?? this.partNumber,
      fieldStatus: clearFieldStatus ? null : (fieldStatus ?? this.fieldStatus),
      reviewStatus: clearReviewStatus ? null : (reviewStatus ?? this.reviewStatus),
      sortBy: sortBy ?? this.sortBy,
      sortOrder: sortOrder ?? this.sortOrder,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

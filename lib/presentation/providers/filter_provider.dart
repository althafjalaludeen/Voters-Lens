import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/field_status.dart';
import '../../domain/entities/filter_criteria.dart';

final filterCriteriaProvider = StateNotifierProvider<FilterNotifier, FilterCriteria>((ref) {
  return FilterNotifier();
});

class FilterNotifier extends StateNotifier<FilterCriteria> {
  FilterNotifier() : super(const FilterCriteria());

  void setQuery(String? query) {
    state = state.copyWith(query: query, page: 1);
  }

  void setGender(GenderOption gender) {
    state = state.copyWith(gender: gender, page: 1);
  }

  void setPartNumber(String? part) {
    state = state.copyWith(partNumber: part, page: 1);
  }

  void setFieldStatus(FieldStatusType? status) {
    state = state.copyWith(
      fieldStatus: status,
      clearFieldStatus: status == null,
      page: 1,
    );
  }

  void setReviewStatus(ReviewStatusType? status) {
    state = state.copyWith(
      reviewStatus: status,
      clearReviewStatus: status == null,
      page: 1,
    );
  }

  void setHouseNumber(String? house) {
    state = state.copyWith(houseNumber: house, page: 1);
  }

  void setRelativeName(String? rel) {
    state = state.copyWith(relativeName: rel, page: 1);
  }

  void setSort(SortBy by, SortOrder order) {
    state = state.copyWith(sortBy: by, sortOrder: order, page: 1);
  }

  void setPage(int page) {
    state = state.copyWith(page: page);
  }

  void clearFilters() {
    state = FilterCriteria(
      query: state.query,
      sortBy: state.sortBy,
      sortOrder: state.sortOrder,
    );
  }

  void setCriteria(FilterCriteria criteria) {
    state = criteria;
  }

  void reset() {
    state = const FilterCriteria();
  }
}

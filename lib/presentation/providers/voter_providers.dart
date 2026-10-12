import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/area_statistics.dart';
import '../../domain/entities/household.dart';
import '../../domain/entities/voter.dart';
import 'database_provider.dart';
import 'filter_provider.dart';
import 'roll_providers.dart';

final voterListProvider = Provider<List<Voter>>((ref) {
  final roll = ref.watch(activeRollProvider);
  if (roll == null) return [];
  final criteria = ref.watch(filterCriteriaProvider);
  final repo = ref.watch(voterRepositoryProvider);
  return repo.getVoters(roll.id, criteria);
});

final voterTotalCountProvider = Provider<int>((ref) {
  final roll = ref.watch(activeRollProvider);
  if (roll == null) return 0;
  final criteria = ref.watch(filterCriteriaProvider);
  final repo = ref.watch(voterRepositoryProvider);
  return repo.countVoters(roll.id, criteria);
});

final partsListProvider = Provider<List<String>>((ref) {
  final roll = ref.watch(activeRollProvider);
  if (roll == null) return [];
  final repo = ref.watch(voterRepositoryProvider);
  return repo.getParts(roll.id);
});

final selectedVoterIdProvider = StateProvider<String?>((ref) => null);

final selectedVoterProvider = Provider<Voter?>((ref) {
  final voterId = ref.watch(selectedVoterIdProvider);
  if (voterId == null) return null;
  final repo = ref.watch(voterRepositoryProvider);
  return repo.getVoterById(voterId);
});

final reviewQueueProvider = StateNotifierProvider<ReviewQueueNotifier, List<Voter>>((ref) {
  final roll = ref.watch(activeRollProvider);
  final repo = ref.watch(voterRepositoryProvider);
  return ReviewQueueNotifier(roll?.id, repo);
});

class ReviewQueueNotifier extends StateNotifier<List<Voter>> {
  final String? _rollId;
  final dynamic _repo;

  ReviewQueueNotifier(this._rollId, this._repo) : super([]) {
    refresh();
  }

  void refresh() {
    if (_rollId == null) {
      state = [];
      return;
    }
    state = _repo.getReviewQueue(_rollId);
  }

  void markReviewed(String voterId, {String? reviewer, String? notes}) {
    _repo.markAsReviewed(voterId, reviewer: reviewer, notes: notes);
    refresh();
  }
}

final householdListProvider = Provider<List<Household>>((ref) {
  final roll = ref.watch(activeRollProvider);
  if (roll == null) return [];
  final criteria = ref.watch(filterCriteriaProvider);
  final repo = ref.watch(voterRepositoryProvider);
  return repo.getHouseholdGroups(roll.id, partNumber: criteria.partNumber);
});

final areaStatsProvider = Provider<AreaStatistics?>((ref) {
  final roll = ref.watch(activeRollProvider);
  if (roll == null) return null;
  final criteria = ref.watch(filterCriteriaProvider);
  final repo = ref.watch(voterRepositoryProvider);
  return repo.getAreaStatistics(roll.id, partNumber: criteria.partNumber);
});

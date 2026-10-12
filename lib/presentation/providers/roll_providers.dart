import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/roll_version.dart';
import 'database_provider.dart';

final activeRollProvider = StateNotifierProvider<ActiveRollNotifier, RollVersion?>((ref) {
  final repo = ref.watch(rollRepositoryProvider);
  return ActiveRollNotifier(repo);
});

class ActiveRollNotifier extends StateNotifier<RollVersion?> {
  final dynamic _repo;

  ActiveRollNotifier(this._repo) : super(null) {
    loadActiveRoll();
  }

  void loadActiveRoll() {
    state = _repo.getActiveRoll();
  }

  void setActiveRoll(RollVersion roll) {
    state = roll;
  }
}

final areaConfigProvider = Provider<ElectoralArea?>((ref) {
  final repo = ref.watch(rollRepositoryProvider);
  return repo.getAreaConfig();
});

final rollListProvider = Provider<List<RollVersion>>((ref) {
  final repo = ref.watch(rollRepositoryProvider);
  return repo.listRolls();
});

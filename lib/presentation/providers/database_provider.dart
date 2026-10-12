import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../data/repositories/roll_repository_impl.dart';
import '../../data/repositories/voter_repository_impl.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(() => db.close());
  return db;
});

final voterRepositoryProvider = Provider<VoterRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return VoterRepositoryImpl(db);
});

final rollRepositoryProvider = Provider<RollRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return RollRepositoryImpl(db);
});

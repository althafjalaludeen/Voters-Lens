import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../data/repositories/roll_repository_impl.dart';
import '../../data/repositories/voter_repository_impl.dart';

/// The canonical provider for [AppDatabase].
///
/// In production, this provider must be overridden in [ProviderScope] during
/// application startup with an [AppDatabase] instance initialized via
/// [AppDatabase.openSecure()].
///
/// If accessed without an override, it raises a [StateError] to prevent
/// silent fallback to an unencrypted database.
final databaseProvider = Provider<AppDatabase>((ref) {
  throw StateError(
    'databaseProvider was accessed without being initialized. '
    'Ensure AppDatabase.openSecure() is executed during startup and passed via ProviderScope override.',
  );
});

final voterRepositoryProvider = Provider<VoterRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return VoterRepositoryImpl(db);
});

final rollRepositoryProvider = Provider<RollRepositoryImpl>((ref) {
  final db = ref.watch(databaseProvider);
  return RollRepositoryImpl(db);
});

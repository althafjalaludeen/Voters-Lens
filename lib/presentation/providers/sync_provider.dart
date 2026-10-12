import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/vlsync_transport.dart';
import '../../domain/entities/sync_models.dart';
import 'database_provider.dart';
import 'roll_providers.dart';

// ---------------------------------------------------------------------------
// Core engine provider
// ---------------------------------------------------------------------------

final vlSyncEngineProvider = Provider<VLSyncFileEngine>((ref) {
  final db = ref.watch(databaseProvider);
  return VLSyncFileEngine(db);
});

// ---------------------------------------------------------------------------
// Sync stats (dashboard summary)
// ---------------------------------------------------------------------------

final syncStatsProvider = Provider<Map<String, dynamic>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.getSyncStats();
});

// ---------------------------------------------------------------------------
// Sync packet history
// ---------------------------------------------------------------------------

final syncPacketsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.getSyncPackets();
});

// ---------------------------------------------------------------------------
// Pending conflicts
// ---------------------------------------------------------------------------

final pendingConflictsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.getSyncConflicts(pendingOnly: true);
});

// ---------------------------------------------------------------------------
// Async export state
// ---------------------------------------------------------------------------

enum SyncOpStatus { idle, loading, success, error }

class SyncExportState {
  final SyncOpStatus status;
  final String? exportedFilePath;
  final String? errorMessage;

  const SyncExportState({
    this.status = SyncOpStatus.idle,
    this.exportedFilePath,
    this.errorMessage,
  });

  SyncExportState copyWith({
    SyncOpStatus? status,
    String? exportedFilePath,
    String? errorMessage,
  }) =>
      SyncExportState(
        status: status ?? this.status,
        exportedFilePath: exportedFilePath ?? this.exportedFilePath,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

class SyncExportNotifier extends StateNotifier<SyncExportState> {
  final VLSyncFileEngine _engine;

  SyncExportNotifier(this._engine) : super(const SyncExportState());

  Future<void> export({
    required String passphrase,
    required String operatorUsername,
    String? targetDirectory,
    String? partNumber,
  }) async {
    state = const SyncExportState(status: SyncOpStatus.loading);
    try {
      final dir = targetDirectory ?? 'data/sync_exports';
      final path = await _engine.exportToFile(
        targetDirectory: dir,
        transferPassphrase: passphrase,
        operatorUsername: operatorUsername,
        selectedPartNumber: partNumber,
      );
      state = SyncExportState(status: SyncOpStatus.success, exportedFilePath: path);
    } catch (e) {
      state = SyncExportState(status: SyncOpStatus.error, errorMessage: e.toString());
    }
  }

  void reset() {
    state = const SyncExportState();
  }
}

final syncExportProvider =
    StateNotifierProvider<SyncExportNotifier, SyncExportState>((ref) {
  final engine = ref.watch(vlSyncEngineProvider);
  return SyncExportNotifier(engine);
});

// ---------------------------------------------------------------------------
// Async import state
// ---------------------------------------------------------------------------

class SyncImportState {
  final SyncOpStatus status;
  final dynamic preview; // ImportPreviewItem
  final Map<String, dynamic>? commitResult;
  final String? errorMessage;

  const SyncImportState({
    this.status = SyncOpStatus.idle,
    this.preview,
    this.commitResult,
    this.errorMessage,
  });

  SyncImportState copyWith({
    SyncOpStatus? status,
    dynamic preview,
    Map<String, dynamic>? commitResult,
    String? errorMessage,
  }) =>
      SyncImportState(
        status: status ?? this.status,
        preview: preview ?? this.preview,
        commitResult: commitResult ?? this.commitResult,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

class SyncImportNotifier extends StateNotifier<SyncImportState> {
  final VLSyncFileEngine _engine;

  SyncImportNotifier(this._engine) : super(const SyncImportState());

  Future<void> preview({
    required String filePath,
    required String passphrase,
  }) async {
    state = const SyncImportState(status: SyncOpStatus.loading);
    try {
      final result = await _engine.previewVLSyncFile(
        filePath: filePath,
        transferPassphrase: passphrase,
      );
      state = SyncImportState(status: SyncOpStatus.success, preview: result);
    } catch (e) {
      state = SyncImportState(status: SyncOpStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> commit({
    required String operatorUsername,
  }) async {
    final p = state.preview;
    if (p == null) return;
    state = state.copyWith(status: SyncOpStatus.loading);
    try {
      final result = await _engine.commitImport(
        preview: p,
        operatorUsername: operatorUsername,
      );
      state = state.copyWith(status: SyncOpStatus.success, commitResult: result);
    } catch (e) {
      state = state.copyWith(status: SyncOpStatus.error, errorMessage: e.toString());
    }
  }

  void reset() {
    state = const SyncImportState();
  }
}

final syncImportProvider =
    StateNotifierProvider<SyncImportNotifier, SyncImportState>((ref) {
  final engine = ref.watch(vlSyncEngineProvider);
  return SyncImportNotifier(engine);
});

// ---------------------------------------------------------------------------
// Gazette Snapshot Bootstrap State
// ---------------------------------------------------------------------------

class GazetteBootstrapState {
  final SyncOpStatus status;
  final GazetteSnapshotPreview? preview;
  final Map<String, dynamic>? installResult;
  final String? errorMessage;

  const GazetteBootstrapState({
    this.status = SyncOpStatus.idle,
    this.preview,
    this.installResult,
    this.errorMessage,
  });

  GazetteBootstrapState copyWith({
    SyncOpStatus? status,
    GazetteSnapshotPreview? preview,
    Map<String, dynamic>? installResult,
    String? errorMessage,
  }) =>
      GazetteBootstrapState(
        status: status ?? this.status,
        preview: preview ?? this.preview,
        installResult: installResult ?? this.installResult,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

class GazetteBootstrapNotifier extends StateNotifier<GazetteBootstrapState> {
  final VLSyncFileEngine _engine;
  final Ref _ref;

  GazetteBootstrapNotifier(this._engine, this._ref)
      : super(const GazetteBootstrapState());

  Future<void> preview({
    required String filePath,
    required String passphrase,
  }) async {
    state = const GazetteBootstrapState(status: SyncOpStatus.loading);
    try {
      final result = await _engine.previewGazetteSnapshotFile(
        filePath: filePath,
        transferPassphrase: passphrase,
      );
      state = GazetteBootstrapState(status: SyncOpStatus.success, preview: result);
    } catch (e) {
      state = GazetteBootstrapState(status: SyncOpStatus.error, errorMessage: e.toString());
    }
  }

  Future<void> install({
    required String operatorUsername,
    bool allowReplaceActive = false,
  }) async {
    final p = state.preview;
    if (p == null) return;
    state = state.copyWith(status: SyncOpStatus.loading);
    try {
      final result = await _engine.bootstrapGazetteSnapshot(
        preview: p,
        operatorUsername: operatorUsername,
        allowReplaceActive: allowReplaceActive,
      );
      // Reload active roll provider so all screens immediately refresh
      _ref.read(activeRollProvider.notifier).loadActiveRoll();
      state = state.copyWith(status: SyncOpStatus.success, installResult: result);
    } catch (e) {
      state = state.copyWith(status: SyncOpStatus.error, errorMessage: e.toString());
    }
  }

  void reset() {
    state = const GazetteBootstrapState();
  }
}

final gazetteBootstrapProvider =
    StateNotifierProvider<GazetteBootstrapNotifier, GazetteBootstrapState>((ref) {
  final engine = ref.watch(vlSyncEngineProvider);
  return GazetteBootstrapNotifier(engine, ref);
});


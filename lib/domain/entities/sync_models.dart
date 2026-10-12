import 'package:flutter/foundation.dart';

enum SyncDirection { export, import }

enum SyncStatus { received, validated, previewed, committed, imported, rejected, failed }

enum ConflictType {
  duplicate,
  identical,
  stale,
  concurrent,
  rollMismatch,
  voterNotFound,
  invalidObservation,
  permissionConflict,
}

enum ResolutionStatus { pendingReview, resolvedAcceptedA, resolvedAcceptedB, resolvedMerged, dismissed }

@immutable
class SyncOverviewStats {
  final String deviceId;
  final String deviceName;
  final DateTime? lastSyncAt;
  final int pendingConflictCount;
  final DateTime? lastBackupAt;
  final int totalObservationsCount;

  const SyncOverviewStats({
    required this.deviceId,
    required this.deviceName,
    this.lastSyncAt,
    required this.pendingConflictCount,
    this.lastBackupAt,
    required this.totalObservationsCount,
  });
}

@immutable
class SyncPacketItem {
  final String id;
  final String packetId;
  final String direction;
  final int protocolVersion;
  final String sourceDeviceId;
  final String sourceUserId;
  final String rollVersionId;
  final String rollChecksum;
  final int observationCount;
  final DateTime createdAt;
  final DateTime processedAt;
  final String status;
  final String? statusMessage;

  const SyncPacketItem({
    required this.id,
    required this.packetId,
    required this.direction,
    required this.protocolVersion,
    required this.sourceDeviceId,
    required this.sourceUserId,
    required this.rollVersionId,
    required this.rollChecksum,
    required this.observationCount,
    required this.createdAt,
    required this.processedAt,
    required this.status,
    this.statusMessage,
  });
}

@immutable
class SyncConflictItem {
  final String id;
  final String? voterId;
  final String voterEpic;
  final String? voterName;
  final String? voterPartSerial;
  final String conflictType;
  final String? localObservationId;
  final String incomingObservationId;
  final String? localStatus;
  final String incomingStatus;
  final String? localPhone;
  final String? incomingPhone;
  final String? localNotes;
  final String? incomingNotes;
  final DateTime? localTime;
  final DateTime? incomingTime;
  final String? localDevice;
  final String? incomingDevice;
  final String resolutionStatus;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final String? resolutionChoice;
  final String? resolutionNotes;
  final DateTime createdAt;

  const SyncConflictItem({
    required this.id,
    this.voterId,
    required this.voterEpic,
    this.voterName,
    this.voterPartSerial,
    required this.conflictType,
    this.localObservationId,
    required this.incomingObservationId,
    this.localStatus,
    required this.incomingStatus,
    this.localPhone,
    this.incomingPhone,
    this.localNotes,
    this.incomingNotes,
    this.localTime,
    this.incomingTime,
    this.localDevice,
    this.incomingDevice,
    required this.resolutionStatus,
    this.resolvedBy,
    this.resolvedAt,
    this.resolutionChoice,
    this.resolutionNotes,
    required this.createdAt,
  });
}

@immutable
class PreviewRecordItem {
  final String observationId;
  final String voterEpic;
  final String? voterPartSerial;
  final String? voterName;
  final String incomingStatus;
  final String? localStatus;
  final String classification; // NEW, IDENTICAL, DUPLICATE, STALE, CONCURRENT, ROLL_MISMATCH, VOTER_NOT_FOUND, INVALID
  final String message;
  final bool isSafeToImport;
  final bool requiresReview;
  final bool isRejected;
  final String? phoneNumber;
  final String? notes;
  final String createdAt;
  final String originDeviceId;
  final Map<String, dynamic> rawObservation;

  const PreviewRecordItem({
    required this.observationId,
    required this.voterEpic,
    this.voterPartSerial,
    this.voterName,
    required this.incomingStatus,
    this.localStatus,
    required this.classification,
    required this.message,
    required this.isSafeToImport,
    required this.requiresReview,
    required this.isRejected,
    this.phoneNumber,
    this.notes,
    required this.createdAt,
    required this.originDeviceId,
    this.rawObservation = const {},
  });
}

@immutable
class ImportPreviewItem {
  final String packetId;
  final String sourceDeviceId;
  final String sourceUserId;
  final String rollVersionId;
  final String rollChecksum;
  final String createdAt;
  final int totalRecords;
  final int newRecords;
  final int duplicateRecords;
  final int identicalRecords;
  final int staleRecords;
  final int concurrentConflicts;
  final int rollMismatchRecords;
  final int voterNotFoundRecords;
  final int invalidRecords;
  final int permissionConflictRecords;
  final bool isCompatibleRoll;
  final bool canCommit;
  final String? rejectionReason;
  final List<PreviewRecordItem> records;
  final Map<String, dynamic> rawEnvelope;

  const ImportPreviewItem({
    required this.packetId,
    required this.sourceDeviceId,
    required this.sourceUserId,
    required this.rollVersionId,
    required this.rollChecksum,
    required this.createdAt,
    required this.totalRecords,
    required this.newRecords,
    required this.duplicateRecords,
    required this.identicalRecords,
    required this.staleRecords,
    required this.concurrentConflicts,
    required this.rollMismatchRecords,
    required this.voterNotFoundRecords,
    required this.invalidRecords,
    required this.permissionConflictRecords,
    required this.isCompatibleRoll,
    required this.canCommit,
    this.rejectionReason,
    required this.records,
    this.rawEnvelope = const {},
  });
}

@immutable
class GazetteSnapshotPreview {
  final String packetId;
  final String sourceDeviceId;
  final String sourceUserId;
  final String rollVersionId;
  final String rollChecksum;
  final String rollName;
  final String state;
  final String district;
  final String assemblyConstituency;
  final String rollType;
  final String? publicationDate;
  final int recordCount;
  final int voterRecordsInPayload;
  final bool isSafeToInstall;
  final bool isReplacingExistingRoll;
  final String? existingActiveRollName;
  final String? rejectionReason;
  final Map<String, dynamic> rawEnvelope;
  final Map<String, dynamic> rawPayload;

  const GazetteSnapshotPreview({
    required this.packetId,
    required this.sourceDeviceId,
    required this.sourceUserId,
    required this.rollVersionId,
    required this.rollChecksum,
    required this.rollName,
    required this.state,
    required this.district,
    required this.assemblyConstituency,
    required this.rollType,
    this.publicationDate,
    required this.recordCount,
    required this.voterRecordsInPayload,
    required this.isSafeToInstall,
    this.isReplacingExistingRoll = false,
    this.existingActiveRollName,
    this.rejectionReason,
    this.rawEnvelope = const {},
    this.rawPayload = const {},
  });
}

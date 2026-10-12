class RollVersion {
  final String id;
  final String state;
  final String district;
  final String assemblyConstituency;
  final String rollName;
  final String rollType;
  final String? publicationDate;
  final String? sourceReference;
  final DateTime importedAt;
  final int recordCount;
  final String status;
  final String? checksumHash;

  const RollVersion({
    required this.id,
    required this.state,
    required this.district,
    required this.assemblyConstituency,
    required this.rollName,
    this.rollType = 'GENERAL',
    this.publicationDate,
    this.sourceReference,
    required this.importedAt,
    this.recordCount = 0,
    required this.status,
    this.checksumHash,
  });

  bool get isActive => status.toUpperCase() == 'ACTIVE';
}

class ElectoralArea {
  final String id;
  final String state;
  final String district;
  final String assemblyConstituency;
  final String? selectedPartNumber;
  final String? activeRollId;

  const ElectoralArea({
    required this.id,
    required this.state,
    required this.district,
    required this.assemblyConstituency,
    this.selectedPartNumber,
    this.activeRollId,
  });
}

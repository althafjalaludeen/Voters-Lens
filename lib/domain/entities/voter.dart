import 'field_status_record.dart';

class Voter {
  final String id;
  final String rollVersionId;
  final int serialNumber;
  final String epicNumber;
  final String name;
  final String normalizedName;
  final String relativeName;
  final String normalizedRelativeName;
  final String relativeType;
  final String houseNumber;
  final String normalizedHouseNumber;
  final int age;
  final String gender;
  final String partNumber;
  final String sectionNumber;
  final String sectionName;
  final String pollingStationName;
  final String pollingStationAddress;
  final String? photoPath;
  final double? ocrConfidence;
  final String? rawData;
  final DateTime? createdAt;
  final FieldStatusRecord fieldStatus;

  const Voter({
    required this.id,
    required this.rollVersionId,
    required this.serialNumber,
    required this.epicNumber,
    required this.name,
    required this.normalizedName,
    required this.relativeName,
    required this.normalizedRelativeName,
    required this.relativeType,
    required this.houseNumber,
    required this.normalizedHouseNumber,
    required this.age,
    required this.gender,
    required this.partNumber,
    required this.sectionNumber,
    required this.sectionName,
    required this.pollingStationName,
    required this.pollingStationAddress,
    this.photoPath,
    this.ocrConfidence,
    this.rawData,
    this.createdAt,
    this.fieldStatus = const FieldStatusRecord.initial(),
  });

  bool get hasPhoto => photoPath != null && photoPath!.isNotEmpty;

  Voter copyWith({
    FieldStatusRecord? fieldStatus,
  }) {
    return Voter(
      id: id,
      rollVersionId: rollVersionId,
      serialNumber: serialNumber,
      epicNumber: epicNumber,
      name: name,
      normalizedName: normalizedName,
      relativeName: relativeName,
      normalizedRelativeName: normalizedRelativeName,
      relativeType: relativeType,
      houseNumber: houseNumber,
      normalizedHouseNumber: normalizedHouseNumber,
      age: age,
      gender: gender,
      partNumber: partNumber,
      sectionNumber: sectionNumber,
      sectionName: sectionName,
      pollingStationName: pollingStationName,
      pollingStationAddress: pollingStationAddress,
      photoPath: photoPath,
      ocrConfidence: ocrConfidence,
      rawData: rawData,
      createdAt: createdAt,
      fieldStatus: fieldStatus ?? this.fieldStatus,
    );
  }
}

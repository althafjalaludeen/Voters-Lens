import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../constants/field_status.dart';
import '../../domain/entities/area_statistics.dart';
import '../../domain/entities/field_status_record.dart';
import '../../domain/entities/filter_criteria.dart';
import '../../domain/entities/household.dart';
import '../../domain/entities/roll_version.dart';
import '../../domain/entities/sync_models.dart';
import '../../domain/entities/voter.dart';

class AppDatabase {
  final Database _db;
  final String path;
  final Uuid _uuid = const Uuid();

  static String? _resolvedDefaultDirectory;

  static void setDefaultDirectory(String dir) {
    _resolvedDefaultDirectory = dir;
  }

  static String? get resolvedDefaultDirectory => _resolvedDefaultDirectory;

  static String getDefaultDatabasePath() {
    if (_resolvedDefaultDirectory != null && _resolvedDefaultDirectory!.isNotEmpty) {
      return p.join(_resolvedDefaultDirectory!, 'voterlens.db');
    }
    if (File('data/voterlens.db').existsSync()) {
      return 'data/voterlens.db';
    }
    if (File('validation-results/full-roll/validation.db').existsSync()) {
      return 'validation-results/full-roll/validation.db';
    }
    return 'data/voterlens.db';
  }

  AppDatabase(this._db, {required this.path});

  Database get rawDb => _db;

  static AppDatabase open({String? customPath}) {
    final String dbPath = customPath ?? getDefaultDatabasePath();
    final parentDir = File(dbPath).parent;
    if (!parentDir.existsSync()) {
      try {
        parentDir.createSync(recursive: true);
      } catch (_) {}
    }

    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA synchronous = NORMAL;');

    final appDb = AppDatabase(db, path: dbPath);
    appDb._ensureSchema();
    return appDb;
  }

  static AppDatabase openInMemory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys = ON;');
    final appDb = AppDatabase(db, path: ':memory:');
    appDb._initSchema();
    return appDb;
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS roll_versions (
        id VARCHAR(36) PRIMARY KEY,
        state VARCHAR(100) NOT NULL,
        district VARCHAR(100) NOT NULL,
        assembly_constituency VARCHAR(150) NOT NULL,
        roll_name VARCHAR(200) NOT NULL,
        roll_type VARCHAR(50) DEFAULT 'GENERAL',
        publication_date VARCHAR(50),
        source_reference VARCHAR(255),
        imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        record_count INTEGER DEFAULT 0,
        status VARCHAR(20) NOT NULL,
        checksum_hash VARCHAR(64)
      );

      CREATE TABLE IF NOT EXISTS electoral_area_configs (
        id VARCHAR(36) PRIMARY KEY,
        state VARCHAR(100) NOT NULL,
        district VARCHAR(100) NOT NULL,
        assembly_constituency VARCHAR(150) NOT NULL,
        selected_part_number VARCHAR(50),
        active_roll_id VARCHAR(36),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS voters (
        id VARCHAR(36) PRIMARY KEY,
        roll_version_id VARCHAR(36) NOT NULL,
        serial_number INTEGER NOT NULL,
        epic_number VARCHAR(50) NOT NULL,
        name VARCHAR(255) NOT NULL,
        normalized_name VARCHAR(255) NOT NULL,
        relative_name VARCHAR(255) NOT NULL,
        normalized_relative_name VARCHAR(255) NOT NULL,
        relative_type VARCHAR(50) DEFAULT 'OTHER',
        house_number VARCHAR(100) NOT NULL,
        normalized_house_number VARCHAR(100) NOT NULL,
        age INTEGER NOT NULL,
        gender VARCHAR(20) NOT NULL,
        part_number VARCHAR(50) NOT NULL,
        section_number VARCHAR(50) DEFAULT '',
        section_name VARCHAR(255) DEFAULT '',
        polling_station_name VARCHAR(255) DEFAULT '',
        polling_station_address TEXT DEFAULT '',
        photo_path VARCHAR(500),
        ocr_confidence REAL,
        raw_data TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS field_status (
        id VARCHAR(36) PRIMARY KEY,
        voter_id VARCHAR(36) UNIQUE NOT NULL,
        status VARCHAR(30) NOT NULL DEFAULT 'NO_ISSUE',
        phone_number VARCHAR(50),
        notes TEXT,
        review_status VARCHAR(20) DEFAULT 'NOT_REVIEWED',
        review_reasons TEXT,
        reviewed_by VARCHAR(100),
        reviewed_at TIMESTAMP,
        reported_by VARCHAR(100),
        reported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS field_status_history (
        id VARCHAR(36) PRIMARY KEY,
        voter_id VARCHAR(36) NOT NULL,
        old_status VARCHAR(50) NOT NULL,
        new_status VARCHAR(50) NOT NULL,
        notes TEXT,
        changed_by VARCHAR(100),
        changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS audit_logs (
        id VARCHAR(36) PRIMARY KEY,
        action VARCHAR(100) NOT NULL,
        entity_type VARCHAR(50) NOT NULL,
        entity_id VARCHAR(50),
        performed_by VARCHAR(100),
        details TEXT,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS device_configs (
        id VARCHAR(36) PRIMARY KEY,
        device_id VARCHAR(36) UNIQUE NOT NULL,
        device_name VARCHAR(100) DEFAULT 'VoterLens Field Unit',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS field_observations (
        id VARCHAR(36) PRIMARY KEY,
        observation_id VARCHAR(36) UNIQUE NOT NULL,
        voter_id VARCHAR(36),
        voter_epic VARCHAR(50) NOT NULL,
        voter_part_serial VARCHAR(50),
        roll_version_id VARCHAR(36) NOT NULL,
        roll_checksum VARCHAR(64) NOT NULL,
        field_status VARCHAR(30) NOT NULL,
        phone_number VARCHAR(50),
        notes TEXT,
        created_by VARCHAR(100) NOT NULL,
        created_at TIMESTAMP NOT NULL,
        origin_device_id VARCHAR(36) NOT NULL,
        received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        supersedes_id VARCHAR(36),
        is_revoked INTEGER DEFAULT 0 NOT NULL,
        revocation_reason TEXT
      );

      CREATE TABLE IF NOT EXISTS sync_packets (
        id VARCHAR(36) PRIMARY KEY,
        packet_id VARCHAR(36) NOT NULL,
        direction VARCHAR(20) NOT NULL,
        protocol_version INTEGER DEFAULT 1 NOT NULL,
        source_device_id VARCHAR(36) NOT NULL,
        source_user_id VARCHAR(100) NOT NULL,
        roll_version_id VARCHAR(36) NOT NULL,
        roll_checksum VARCHAR(64) NOT NULL,
        observation_count INTEGER DEFAULT 0 NOT NULL,
        created_at TIMESTAMP NOT NULL,
        processed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        status VARCHAR(20) NOT NULL,
        status_message TEXT,
        UNIQUE(packet_id, direction)
      );

      CREATE TABLE IF NOT EXISTS sync_conflicts (
        id VARCHAR(36) PRIMARY KEY,
        voter_id VARCHAR(36),
        voter_epic VARCHAR(50) NOT NULL,
        conflict_type VARCHAR(50) NOT NULL,
        local_observation_id VARCHAR(36),
        incoming_observation_id VARCHAR(36) NOT NULL,
        resolution_status VARCHAR(50) DEFAULT 'PENDING_REVIEW' NOT NULL,
        resolved_by VARCHAR(100),
        resolved_at TIMESTAMP,
        resolution_choice VARCHAR(50),
        resolution_notes TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS trusted_devices (
        id VARCHAR(36) PRIMARY KEY,
        device_id VARCHAR(36) UNIQUE NOT NULL,
        device_name VARCHAR(100) NOT NULL,
        operator_name VARCHAR(100),
        is_trusted INTEGER DEFAULT 1 NOT NULL,
        first_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        last_synced_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE TABLE IF NOT EXISTS auth_configs (
        id VARCHAR(36) PRIMARY KEY,
        pin_salt_hex VARCHAR(64) NOT NULL,
        pin_hash_hex VARCHAR(64) NOT NULL,
        failed_attempts INTEGER DEFAULT 0 NOT NULL,
        locked_until_epoch INTEGER DEFAULT 0 NOT NULL,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );

      CREATE UNIQUE INDEX IF NOT EXISTS uq_active_roll_version ON roll_versions(status) WHERE status = 'ACTIVE';
      CREATE UNIQUE INDEX IF NOT EXISTS uq_voter_roll_epic ON voters(roll_version_id, epic_number);
    ''');
  }

  void _ensureSchema() {
    _initSchema();
    // Non-destructive migrations for existing SQLite files
    try {
      final rollCols = _db.select('PRAGMA table_info(roll_versions)').map((r) => r['name'] as String).toList();
      if (!rollCols.contains('checksum_hash')) {
        _db.execute('ALTER TABLE roll_versions ADD COLUMN checksum_hash VARCHAR(64)');
      }
    } catch (_) {}

    try {
      final fsCols = _db.select('PRAGMA table_info(field_status)').map((r) => r['name'] as String).toList();
      if (!fsCols.contains('phone_number')) {
        _db.execute('ALTER TABLE field_status ADD COLUMN phone_number VARCHAR(50)');
      }
      if (!fsCols.contains('review_status')) {
        _db.execute("ALTER TABLE field_status ADD COLUMN review_status VARCHAR(20) DEFAULT 'NOT_REVIEWED'");
      }
      if (!fsCols.contains('review_reasons')) {
        _db.execute('ALTER TABLE field_status ADD COLUMN review_reasons TEXT');
      }
      if (!fsCols.contains('reviewed_by')) {
        _db.execute('ALTER TABLE field_status ADD COLUMN reviewed_by VARCHAR(100)');
      }
      if (!fsCols.contains('reviewed_at')) {
        _db.execute('ALTER TABLE field_status ADD COLUMN reviewed_at TIMESTAMP');
      }
    } catch (_) {}

    try {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS auth_configs (
          id VARCHAR(36) PRIMARY KEY,
          pin_salt_hex VARCHAR(64) NOT NULL,
          pin_hash_hex VARCHAR(64) NOT NULL,
          failed_attempts INTEGER DEFAULT 0 NOT NULL,
          locked_until_epoch INTEGER DEFAULT 0 NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
      ''');
    } catch (_) {}

    try {
      _db.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_active_roll_version ON roll_versions(status) WHERE status = 'ACTIVE'");
    } catch (_) {}
    try {
      _db.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_voter_roll_epic ON voters(roll_version_id, epic_number)");
    } catch (_) {}
    try {
      _db.execute("CREATE UNIQUE INDEX IF NOT EXISTS uq_voter_roll_part_serial ON voters(roll_version_id, part_number, serial_number)");
    } catch (_) {}
  }

  RollVersion? getActiveRoll() {
    final rows = _db.select("SELECT * FROM roll_versions WHERE status = 'ACTIVE' ORDER BY imported_at DESC LIMIT 1");
    if (rows.isEmpty) {
      final fallback = _db.select('SELECT * FROM roll_versions ORDER BY imported_at DESC LIMIT 1');
      if (fallback.isEmpty) return null;
      return _mapRollVersion(fallback.first);
    }
    return _mapRollVersion(rows.first);
  }

  List<RollVersion> listRolls() {
    final rows = _db.select('SELECT * FROM roll_versions ORDER BY imported_at DESC');
    return rows.map(_mapRollVersion).toList();
  }

  ElectoralArea? getAreaConfig() {
    final rows = _db.select('SELECT * FROM electoral_area_configs ORDER BY created_at DESC LIMIT 1');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ElectoralArea(
      id: r['id'] as String,
      state: r['state'] as String,
      district: r['district'] as String,
      assemblyConstituency: r['assembly_constituency'] as String,
      selectedPartNumber: r['selected_part_number'] as String?,
      activeRollId: r['active_roll_id'] as String?,
    );
  }

  void saveAreaConfig({
    required String state,
    required String district,
    required String assemblyConstituency,
    String? selectedPartNumber,
    String? activeRollId,
  }) {
    final existing = getAreaConfig();
    final now = DateTime.now().toIso8601String();
    if (existing != null) {
      _db.execute(
        '''
        UPDATE electoral_area_configs 
        SET state = ?, district = ?, assembly_constituency = ?, selected_part_number = ?, active_roll_id = ?, updated_at = ?
        WHERE id = ?
      ''',
        [state, district, assemblyConstituency, selectedPartNumber, activeRollId ?? existing.activeRollId, now, existing.id],
      );
    } else {
      _db.execute(
        '''
        INSERT INTO electoral_area_configs (id, state, district, assembly_constituency, selected_part_number, active_roll_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [_uuid.v4(), state, district, assemblyConstituency, selectedPartNumber, activeRollId, now, now],
      );
    }
  }

  List<String> getParts(String rollVersionId) {
    final rows = _db.select(
      'SELECT DISTINCT part_number FROM voters WHERE roll_version_id = ? ORDER BY CAST(part_number AS INTEGER), part_number',
      [rollVersionId],
    );
    return rows.map((r) => r['part_number'].toString()).toList();
  }

  List<Voter> searchVoters(String rollVersionId, FilterCriteria criteria) {
    final StringBuffer whereClause = StringBuffer('WHERE v.roll_version_id = ?');
    final List<Object?> params = [rollVersionId];

    if (criteria.query != null && criteria.query!.trim().isNotEmpty) {
      final q = '%${criteria.query!.trim()}%';
      whereClause.write('''
        AND (
          v.name LIKE ? OR 
          v.normalized_name LIKE ? OR 
          v.epic_number LIKE ? OR 
          v.relative_name LIKE ? OR 
          v.house_number LIKE ?
        )
      ''');
      params.addAll([q, q, q, q, q]);
    }

    if (criteria.name != null && criteria.name!.trim().isNotEmpty) {
      final n = '%${criteria.name!.trim()}%';
      whereClause.write(' AND (v.name LIKE ? OR v.normalized_name LIKE ?)');
      params.addAll([n, n]);
    }

    if (criteria.epic != null && criteria.epic!.trim().isNotEmpty) {
      whereClause.write(' AND v.epic_number LIKE ?');
      params.add('%${criteria.epic!.trim()}%');
    }

    if (criteria.relativeName != null && criteria.relativeName!.trim().isNotEmpty) {
      final r = '%${criteria.relativeName!.trim()}%';
      whereClause.write(' AND (v.relative_name LIKE ? OR v.normalized_relative_name LIKE ?)');
      params.addAll([r, r]);
    }

    if (criteria.houseNumber != null && criteria.houseNumber!.trim().isNotEmpty) {
      final h = '%${criteria.houseNumber!.trim()}%';
      whereClause.write(' AND (v.house_number LIKE ? OR v.normalized_house_number LIKE ?)');
      params.addAll([h, h]);
    }

    if (criteria.partNumber != null && criteria.partNumber!.trim().isNotEmpty) {
      whereClause.write(' AND v.part_number = ?');
      params.add(criteria.partNumber!.trim());
    }

    if (criteria.gender != GenderOption.all) {
      if (criteria.gender == GenderOption.male) {
        whereClause.write(" AND v.gender IN ('M', 'Male', 'പുരുഷൻ')");
      } else if (criteria.gender == GenderOption.female) {
        whereClause.write(" AND v.gender IN ('F', 'Female', 'സ്ത്രീ')");
      } else {
        whereClause.write(" AND v.gender NOT IN ('M', 'Male', 'പുരുഷൻ', 'F', 'Female', 'സ്ത്രീ')");
      }
    }

    if (criteria.fieldStatus != null) {
      if (criteria.fieldStatus == FieldStatusType.noIssue) {
        whereClause.write(" AND (fs.status = 'NO_ISSUE' OR fs.status IS NULL)");
      } else {
        whereClause.write(' AND fs.status = ?');
        params.add(criteria.fieldStatus!.value);
      }
    }

    if (criteria.reviewStatus != null) {
      if (criteria.reviewStatus == ReviewStatusType.notReviewed) {
        whereClause.write(" AND (fs.review_status = 'NOT_REVIEWED' OR fs.review_status IS NULL)");
      } else {
        whereClause.write(' AND fs.review_status = ?');
        params.add(criteria.reviewStatus!.value);
      }
    }

    String orderByCol = 'v.serial_number';
    switch (criteria.sortBy) {
      case SortBy.name:
        orderByCol = 'v.name';
        break;
      case SortBy.houseNumber:
        orderByCol = 'v.normalized_house_number';
        break;
      case SortBy.age:
        orderByCol = 'v.age';
        break;
      case SortBy.partNumber:
        orderByCol = 'v.part_number, v.serial_number';
        break;
      case SortBy.serialNumber:
        orderByCol = 'v.serial_number';
        break;
    }

    final dir = criteria.sortOrder == SortOrder.desc ? 'DESC' : 'ASC';
    final offset = (criteria.page - 1) * criteria.pageSize;

    final sql = '''
      SELECT 
        v.*,
        fs.status AS fs_status,
        fs.phone_number AS fs_phone,
        fs.notes AS fs_notes,
        fs.review_status AS fs_review_status,
        fs.review_reasons AS fs_review_reasons,
        fs.reviewed_by AS fs_reviewed_by,
        fs.reviewed_at AS fs_reviewed_at,
        fs.reported_by AS fs_reported_by,
        fs.reported_at AS fs_reported_at
      FROM voters v
      LEFT JOIN field_status fs ON v.id = fs.voter_id
      $whereClause
      ORDER BY $orderByCol $dir
      LIMIT ? OFFSET ?
    ''';

    params.addAll([criteria.pageSize, offset]);
    final rows = _db.select(sql, params);
    return rows.map(_mapVoter).toList();
  }

  int countVoters(String rollVersionId, FilterCriteria criteria) {
    final StringBuffer whereClause = StringBuffer('WHERE v.roll_version_id = ?');
    final List<Object?> params = [rollVersionId];

    if (criteria.query != null && criteria.query!.trim().isNotEmpty) {
      final q = '%${criteria.query!.trim()}%';
      whereClause.write('''
        AND (
          v.name LIKE ? OR 
          v.normalized_name LIKE ? OR 
          v.epic_number LIKE ? OR 
          v.relative_name LIKE ? OR 
          v.house_number LIKE ?
        )
      ''');
      params.addAll([q, q, q, q, q]);
    }

    if (criteria.name != null && criteria.name!.trim().isNotEmpty) {
      final n = '%${criteria.name!.trim()}%';
      whereClause.write(' AND (v.name LIKE ? OR v.normalized_name LIKE ?)');
      params.addAll([n, n]);
    }

    if (criteria.epic != null && criteria.epic!.trim().isNotEmpty) {
      whereClause.write(' AND v.epic_number LIKE ?');
      params.add('%${criteria.epic!.trim()}%');
    }

    if (criteria.relativeName != null && criteria.relativeName!.trim().isNotEmpty) {
      final r = '%${criteria.relativeName!.trim()}%';
      whereClause.write(' AND (v.relative_name LIKE ? OR v.normalized_relative_name LIKE ?)');
      params.addAll([r, r]);
    }

    if (criteria.houseNumber != null && criteria.houseNumber!.trim().isNotEmpty) {
      final h = '%${criteria.houseNumber!.trim()}%';
      whereClause.write(' AND (v.house_number LIKE ? OR v.normalized_house_number LIKE ?)');
      params.addAll([h, h]);
    }

    if (criteria.partNumber != null && criteria.partNumber!.trim().isNotEmpty) {
      whereClause.write(' AND v.part_number = ?');
      params.add(criteria.partNumber!.trim());
    }

    if (criteria.gender != GenderOption.all) {
      if (criteria.gender == GenderOption.male) {
        whereClause.write(" AND v.gender IN ('M', 'Male', 'പുരുഷൻ')");
      } else if (criteria.gender == GenderOption.female) {
        whereClause.write(" AND v.gender IN ('F', 'Female', 'സ്ത്രീ')");
      } else {
        whereClause.write(" AND v.gender NOT IN ('M', 'Male', 'പുരുഷൻ', 'F', 'Female', 'സ്ത്രീ')");
      }
    }

    if (criteria.fieldStatus != null) {
      if (criteria.fieldStatus == FieldStatusType.noIssue) {
        whereClause.write(" AND (fs.status = 'NO_ISSUE' OR fs.status IS NULL)");
      } else {
        whereClause.write(' AND fs.status = ?');
        params.add(criteria.fieldStatus!.value);
      }
    }

    if (criteria.reviewStatus != null) {
      if (criteria.reviewStatus == ReviewStatusType.notReviewed) {
        whereClause.write(" AND (fs.review_status = 'NOT_REVIEWED' OR fs.review_status IS NULL)");
      } else {
        whereClause.write(' AND fs.review_status = ?');
        params.add(criteria.reviewStatus!.value);
      }
    }

    final sql = '''
      SELECT COUNT(v.id) AS cnt
      FROM voters v
      LEFT JOIN field_status fs ON v.id = fs.voter_id
      $whereClause
    ''';

    final res = _db.select(sql, params);
    return res.first['cnt'] as int;
  }

  Voter? getVoterById(String voterId) {
    final rows = _db.select('''
      SELECT 
        v.*,
        fs.status AS fs_status,
        fs.phone_number AS fs_phone,
        fs.notes AS fs_notes,
        fs.review_status AS fs_review_status,
        fs.review_reasons AS fs_review_reasons,
        fs.reviewed_by AS fs_reviewed_by,
        fs.reviewed_at AS fs_reviewed_at,
        fs.reported_by AS fs_reported_by,
        fs.reported_at AS fs_reported_at
      FROM voters v
      LEFT JOIN field_status fs ON v.id = fs.voter_id
      WHERE v.id = ?
    ''', [voterId]);

    if (rows.isEmpty) return null;
    final voter = _mapVoter(rows.first);

    // Fetch history
    final historyRows = _db.select(
      'SELECT * FROM field_status_history WHERE voter_id = ? ORDER BY changed_at ASC',
      [voterId],
    );

    final history = historyRows.map((h) {
      return FieldStatusHistoryEntry(
        id: h['id'] as String,
        voterId: h['voter_id'] as String,
        oldStatus: h['old_status'] as String,
        newStatus: h['new_status'] as String,
        notes: h['notes'] as String?,
        changedBy: h['changed_by'] as String?,
        changedAt: DateTime.tryParse(h['changed_at'].toString()) ?? DateTime.now(),
      );
    }).toList();

    return voter.copyWith(
      fieldStatus: voter.fieldStatus.copyWith(history: history),
    );
  }

  void setFieldStatus(String voterId, FieldStatusType newStatus, {String? notes, String? changedBy}) {
    updateFieldInfo(voterId, status: newStatus, notes: notes, user: changedBy);
  }

  String updateFieldInfo(
    String voterId, {
    String? phoneNumber,
    String? notes,
    FieldStatusType? status,
    ReviewStatusType? reviewStatus,
    String? user,
  }) {
    final voter = getVoterById(voterId);
    if (voter == null) {
      throw ArgumentError('Voter not found with id $voterId');
    }

    final activeRoll = getActiveRoll();
    if (activeRoll == null || activeRoll.checksumHash == null || activeRoll.checksumHash!.isEmpty) {
      throw StateError('Cannot record field observation: no active electoral roll version with verified checksum.');
    }

    final deviceId = getDeviceId();
    final observationId = _uuid.v4();
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final operator = user ?? 'local_user';

    final effectiveStatus = status ?? voter.fieldStatus.status;
    final effectiveReview = reviewStatus ?? voter.fieldStatus.reviewStatus;
    final effectivePhone = phoneNumber ?? voter.fieldStatus.phoneNumber;
    final effectiveNotes = notes ?? voter.fieldStatus.notes;

    final voterEpic = voter.epicNumber;
    final voterPartSerial = '${voter.partNumber}:${voter.serialNumber}';

    final latestObs = getLatestObservationForEpic(voterEpic);
    final supersedesId = latestObs != null ? latestObs['observation_id'] as String? : null;

    _db.execute('BEGIN TRANSACTION');
    try {
      // 1. Record immutable append-only field observation
      _db.execute(
        '''
        INSERT INTO field_observations (
          id, observation_id, voter_id, voter_epic, voter_part_serial,
          roll_version_id, roll_checksum, field_status, phone_number, notes,
          created_by, created_at, origin_device_id, received_at, supersedes_id,
          is_revoked, revocation_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)
        ''',
        [
          _uuid.v4(), observationId, voterId, voterEpic, voterPartSerial,
          activeRoll.id, activeRoll.checksumHash!, effectiveStatus.value,
          effectivePhone, effectiveNotes, operator, nowIso, deviceId, nowIso, supersedesId,
        ],
      );

      // 2. Update materialized current field status
      _db.execute(
        '''
        INSERT INTO field_status (
          id, voter_id, status, phone_number, notes, review_status, reported_by, reported_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(voter_id) DO UPDATE SET
          status = excluded.status,
          phone_number = excluded.phone_number,
          notes = excluded.notes,
          review_status = excluded.review_status,
          reported_by = excluded.reported_by,
          updated_at = excluded.updated_at
        ''',
        [
          _uuid.v4(), voterId, effectiveStatus.value, effectivePhone, effectiveNotes,
          effectiveReview.value, operator, nowIso, nowIso,
        ],
      );

      // 3. Append history if status changed
      if (status != null && status != voter.fieldStatus.status) {
        _db.execute(
          '''
          INSERT INTO field_status_history (
            id, voter_id, old_status, new_status, notes, changed_by, changed_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            _uuid.v4(), voterId, voter.fieldStatus.status.value, status.value,
            effectiveNotes, operator, nowIso,
          ],
        );
      }

      // 4. Record audit event
      logAudit(
        action: 'FIELD_OBSERVATION_RECORDED',
        entityType: 'FieldObservation',
        entityId: observationId,
        performedBy: operator,
        details: 'EPIC: $voterEpic, Status: ${effectiveStatus.value}',
      );

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    return observationId;
  }

  List<Voter> getReviewQueue(String rollVersionId, {ReviewStatusType reviewStatus = ReviewStatusType.needsReview}) {
    final rows = _db.select(
      '''
      SELECT 
        v.*,
        fs.status AS fs_status,
        fs.phone_number AS fs_phone,
        fs.notes AS fs_notes,
        fs.review_status AS fs_review_status,
        fs.review_reasons AS fs_review_reasons,
        fs.reviewed_by AS fs_reviewed_by,
        fs.reviewed_at AS fs_reviewed_at,
        fs.reported_by AS fs_reported_by,
        fs.reported_at AS fs_reported_at
      FROM voters v
      INNER JOIN field_status fs ON v.id = fs.voter_id
      WHERE v.roll_version_id = ? AND fs.review_status = ?
      ORDER BY v.serial_number ASC
    ''',
      [rollVersionId, reviewStatus.value],
    );
    return rows.map(_mapVoter).toList();
  }

  void markAsReviewed(String voterId, {String? reviewer, String? notes}) {
    final now = DateTime.now().toIso8601String();
    final user = reviewer ?? 'supervisor';

    _db.execute(
      '''
      UPDATE field_status 
      SET review_status = 'REVIEWED', reviewed_by = ?, reviewed_at = ?, notes = COALESCE(?, notes), updated_at = ?
      WHERE voter_id = ?
    ''',
      [user, now, notes, now, voterId],
    );

    _db.execute(
      '''
      INSERT INTO audit_logs (id, action, entity_type, entity_id, performed_by, details, timestamp)
      VALUES (?, 'VOTER_REVIEWED', 'VOTER_FIELD', ?, ?, ?, ?)
    ''',
      [_uuid.v4(), voterId, user, '{"notes": "${notes ?? ""}"}', now],
    );
  }

  List<Household> getHouseholdGroups(String rollVersionId, {String? partNumber, int limit = 50, int offset = 0}) {
    final StringBuffer where = StringBuffer("WHERE roll_version_id = ? AND normalized_house_number != ''");
    final List<Object?> params = [rollVersionId];

    if (partNumber != null && partNumber.trim().isNotEmpty) {
      where.write(' AND part_number = ?');
      params.add(partNumber.trim());
    }

    final houseSql = '''
      SELECT 
        normalized_house_number,
        MIN(house_number) AS orig_house,
        COUNT(id) AS cnt
      FROM voters
      $where
      GROUP BY normalized_house_number
      ORDER BY MIN(serial_number) ASC
      LIMIT ? OFFSET ?
    ''';

    params.addAll([limit, offset]);
    final houseRows = _db.select(houseSql, params);

    final List<Household> households = [];
    for (final hr in houseRows) {
      final normH = hr['normalized_house_number'] as String;
      final origH = hr['orig_house'] as String;
      final count = hr['cnt'] as int;

      final vRows = _db.select('''
        SELECT 
          v.*,
          fs.status AS fs_status,
          fs.phone_number AS fs_phone,
          fs.notes AS fs_notes,
          fs.review_status AS fs_review_status,
          fs.review_reasons AS fs_review_reasons,
          fs.reviewed_by AS fs_reviewed_by,
          fs.reviewed_at AS fs_reviewed_at,
          fs.reported_by AS fs_reported_by,
          fs.reported_at AS fs_reported_at
        FROM voters v
        LEFT JOIN field_status fs ON v.id = fs.voter_id
        WHERE v.roll_version_id = ? AND v.normalized_house_number = ?
        ORDER BY v.serial_number ASC
      ''', [rollVersionId, normH]);

      households.add(
        Household(
          houseNumber: origH,
          normalizedHouseNumber: normH,
          voterCount: count,
          voters: vRows.map(_mapVoter).toList(),
        ),
      );
    }

    return households;
  }

  AreaStatistics getAreaStatistics(String rollVersionId, {String? partNumber}) {
    final StringBuffer where = StringBuffer('WHERE v.roll_version_id = ?');
    final List<Object?> params = [rollVersionId];

    if (partNumber != null && partNumber.trim().isNotEmpty) {
      where.write(' AND v.part_number = ?');
      params.add(partNumber.trim());
    }

    final totalRows = _db.select('SELECT COUNT(v.id) AS cnt FROM voters v $where', params);
    final total = totalRows.first['cnt'] as int;

    // Gender counts
    final genderRows = _db.select('SELECT v.gender, COUNT(v.id) AS cnt FROM voters v $where GROUP BY v.gender', params);
    final Map<String, int> genderMap = {};
    for (final r in genderRows) {
      genderMap[r['gender'].toString()] = r['cnt'] as int;
    }

    // Field status counts
    final fsRows = _db.select('''
      SELECT COALESCE(fs.status, 'NO_ISSUE') AS st, COUNT(v.id) AS cnt 
      FROM voters v 
      LEFT JOIN field_status fs ON v.id = fs.voter_id 
      $where 
      GROUP BY st
    ''', params);
    final Map<String, int> fsMap = {};
    for (final r in fsRows) {
      fsMap[r['st'].toString()] = r['cnt'] as int;
    }

    // Review counts
    final revRows = _db.select('''
      SELECT COALESCE(fs.review_status, 'NOT_REVIEWED') AS rst, COUNT(v.id) AS cnt 
      FROM voters v 
      LEFT JOIN field_status fs ON v.id = fs.voter_id 
      $where 
      GROUP BY rst
    ''', params);
    final Map<String, int> revMap = {};
    for (final r in revRows) {
      revMap[r['rst'].toString()] = r['cnt'] as int;
    }

    return AreaStatistics(
      totalVoters: total,
      partNumber: partNumber,
      genderCounts: genderMap,
      fieldStatusCounts: fsMap,
      reviewStatusCounts: revMap,
    );
  }

  RollVersion _mapRollVersion(Row r) {
    return RollVersion(
      id: r['id'] as String,
      state: r['state'] as String,
      district: r['district'] as String,
      assemblyConstituency: r['assembly_constituency'] as String,
      rollName: r['roll_name'] as String,
      rollType: r['roll_type'] as String? ?? 'GENERAL',
      publicationDate: r['publication_date'] as String?,
      sourceReference: r['source_reference'] as String?,
      importedAt: DateTime.tryParse(r['imported_at'].toString()) ?? DateTime.now(),
      recordCount: r['record_count'] as int? ?? 0,
      status: r['status'] as String,
      checksumHash: r['checksum_hash'] as String?,
    );
  }

  Voter _mapVoter(Row r) {
    final statusStr = r['fs_status'] as String? ?? 'NO_ISSUE';
    final reviewStr = r['fs_review_status'] as String? ?? 'NOT_REVIEWED';
    final reasonsStr = r['fs_review_reasons'] as String?;
    final reasons = reasonsStr != null
        ? reasonsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()
        : <String>[];

    final fieldRecord = FieldStatusRecord(
      status: FieldStatusType.fromString(statusStr),
      phoneNumber: r['fs_phone'] as String?,
      notes: r['fs_notes'] as String?,
      reviewStatus: ReviewStatusType.fromString(reviewStr),
      reviewReasons: reasons,
      reviewedBy: r['fs_reviewed_by'] as String?,
      reviewedAt: r['fs_reviewed_at'] != null ? DateTime.tryParse(r['fs_reviewed_at'].toString()) : null,
      reportedBy: r['fs_reported_by'] as String?,
      reportedAt: r['fs_reported_at'] != null ? DateTime.tryParse(r['fs_reported_at'].toString()) : null,
    );

    return Voter(
      id: r['id'] as String,
      rollVersionId: r['roll_version_id'] as String,
      serialNumber: r['serial_number'] as int,
      epicNumber: r['epic_number'] as String,
      name: r['name'] as String,
      normalizedName: r['normalized_name'] as String? ?? r['name'] as String,
      relativeName: r['relative_name'] as String? ?? '',
      normalizedRelativeName: r['normalized_relative_name'] as String? ?? '',
      relativeType: r['relative_type'] as String? ?? 'OTHER',
      houseNumber: r['house_number'] as String? ?? '',
      normalizedHouseNumber: r['normalized_house_number'] as String? ?? '',
      age: r['age'] as int? ?? 0,
      gender: r['gender'] as String? ?? '',
      partNumber: r['part_number'] as String? ?? '',
      sectionNumber: r['section_number'] as String? ?? '',
      sectionName: r['section_name'] as String? ?? '',
      pollingStationName: r['polling_station_name'] as String? ?? '',
      pollingStationAddress: r['polling_station_address'] as String? ?? '',
      photoPath: r['photo_path'] as String?,
      ocrConfidence: (r['ocr_confidence'] as num?)?.toDouble(),
      rawData: r['raw_data'] as String?,
      createdAt: r['created_at'] != null ? DateTime.tryParse(r['created_at'].toString()) : null,
      fieldStatus: fieldRecord,
    );
  }

  // ---------------------------------------------------------------------------
  // SYNC METHODS — Phase 4B
  // ---------------------------------------------------------------------------

  /// Returns or initialises the device identity UUID.
  String getDeviceId() {
    final rows = _db.select('SELECT device_id FROM device_configs LIMIT 1');
    if (rows.isNotEmpty) return rows.first['device_id'] as String;
    final newId = _uuid.v4();
    _db.execute(
      'INSERT INTO device_configs (id, device_id, device_name) VALUES (?, ?, ?)',
      [_uuid.v4(), newId, 'VoterLens Field Unit'],
    );
    return newId;
  }

  /// Returns all field observations for a roll version that are eligible for export.
  List<Map<String, dynamic>> getAllEligibleObservations({
    required String rollVersionId,
    String? partNumber,
  }) {
    final StringBuffer where = StringBuffer('WHERE fo.roll_version_id = ? AND fo.is_revoked = 0');
    final List<Object?> params = [rollVersionId];

    if (partNumber != null && partNumber.isNotEmpty) {
      where.write('''
        AND fo.voter_epic IN (
          SELECT v.epic_number FROM voters v
          WHERE v.roll_version_id = ? AND v.part_number = ?
        )
      ''');
      params.addAll([rollVersionId, partNumber]);
    }

    final rows = _db.select('''
      SELECT fo.observation_id, fo.voter_epic, fo.voter_part_serial,
             fo.roll_version_id, fo.roll_checksum, fo.field_status,
             fo.phone_number, fo.notes, fo.created_by, fo.created_at,
             fo.origin_device_id, fo.supersedes_id, fo.is_revoked, fo.revocation_reason
      FROM field_observations fo
      $where
      ORDER BY fo.created_at ASC
    ''', params);

    return rows.map((r) => {
      'observation_id': r['observation_id'],
      'voter_epic': r['voter_epic'],
      'voter_part_serial': r['voter_part_serial'],
      'roll_version_id': r['roll_version_id'],
      'roll_checksum': r['roll_checksum'],
      'field_status': r['field_status'],
      'phone_number': r['phone_number'],
      'notes': r['notes'],
      'created_by': r['created_by'],
      'created_at': r['created_at'],
      'origin_device_id': r['origin_device_id'],
      'supersedes_id': r['supersedes_id'],
      'is_revoked': r['is_revoked'],
      'revocation_reason': r['revocation_reason'],
    }).toList();
  }

  /// Resolves a canonical voter by EPIC number (and optionally part:serial).
  Voter? resolveCanonicalVoter({
    required String rollVersionId,
    required String epicNumber,
    String? partSerial,
  }) {
    final rows = _db.select('''
      SELECT 
        v.*,
        fs.status AS fs_status,
        fs.phone_number AS fs_phone,
        fs.notes AS fs_notes,
        fs.review_status AS fs_review_status,
        fs.review_reasons AS fs_review_reasons,
        fs.reviewed_by AS fs_reviewed_by,
        fs.reviewed_at AS fs_reviewed_at,
        fs.reported_by AS fs_reported_by,
        fs.reported_at AS fs_reported_at
      FROM voters v
      LEFT JOIN field_status fs ON v.id = fs.voter_id
      WHERE v.roll_version_id = ? AND v.epic_number = ?
      LIMIT 1
    ''', [rollVersionId, epicNumber]);
    if (rows.isEmpty) return null;
    return _mapVoter(rows.first);
  }

  /// Returns the most recent field observation for an EPIC number.
  Map<String, dynamic>? getLatestObservationForEpic(String epicNumber) {
    final rows = _db.select('''
      SELECT * FROM field_observations
      WHERE voter_epic = ? AND is_revoked = 0
      ORDER BY created_at DESC, rowid DESC
      LIMIT 1
    ''', [epicNumber]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'observation_id': r['observation_id'],
      'voter_epic': r['voter_epic'],
      'field_status': r['field_status'],
      'phone_number': r['phone_number'],
      'notes': r['notes'],
      'created_at': r['created_at'],
      'origin_device_id': r['origin_device_id'],
    };
  }

  /// Returns true if an observation with the given ID already exists locally.
  bool isObservationIdExists(String observationId) {
    final rows = _db.select(
      'SELECT 1 FROM field_observations WHERE observation_id = ? LIMIT 1',
      [observationId],
    );
    return rows.isNotEmpty;
  }

  /// Returns true if a sync packet with the given ID has already been imported.
  bool isPacketImported(String packetId) {
    final rows = _db.select(
      "SELECT 1 FROM sync_packets WHERE packet_id = ? AND direction = 'IMPORT' LIMIT 1",
      [packetId],
    );
    return rows.isNotEmpty;
  }

  /// Records a sync packet in the audit table.
  void recordSyncPacket({
    required String packetId,
    required String direction,
    required int protocolVersion,
    required String sourceDeviceId,
    required String sourceUserId,
    required String rollVersionId,
    required String rollChecksum,
    required int observationCount,
    required String status,
    String? statusMessage,
  }) {
    final now = DateTime.now().toIso8601String();
    _db.execute(
      '''
      INSERT OR IGNORE INTO sync_packets 
        (id, packet_id, direction, protocol_version, source_device_id, source_user_id,
         roll_version_id, roll_checksum, observation_count, created_at, processed_at, status, status_message)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        _uuid.v4(), packetId, direction, protocolVersion, sourceDeviceId, sourceUserId,
        rollVersionId, rollChecksum, observationCount, now, now, status, statusMessage,
      ],
    );
  }

  /// Appends an entry to the audit log.
  void logAudit({
    required String action,
    required String entityType,
    required String entityId,
    required String performedBy,
    String? details,
  }) {
    final now = DateTime.now().toIso8601String();
    _db.execute(
      '''
      INSERT INTO audit_logs (id, action, entity_type, entity_id, performed_by, details, timestamp)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ''',
      [_uuid.v4(), action, entityType, entityId, performedBy, details, now],
    );
  }

  /// Commits previewed import observations atomically into the local database.
  Map<String, dynamic> commitImportObservations({
    required dynamic preview,  // ImportPreviewItem
    required String operatorUsername,
  }) {
    final role = operatorUsername.trim().toUpperCase();
    if (role != 'ADMIN' && role != 'MANAGER') {
      throw ArgumentError('Unauthorized: commitImportObservations requires Manager or Admin privileges (got: $operatorUsername)');
    }

    final now = DateTime.now().toIso8601String();
    int importedCount = 0;
    int conflictCount = 0;
    int skippedCount = 0;

    _db.execute('BEGIN TRANSACTION');
    try {
      for (final record in preview.records as List) {
        final classification = record.classification as String;
        final obs = record.rawObservation as Map<String, dynamic>;
        final obsId = record.observationId as String;
        final epic = record.voterEpic as String;
        final status = record.incomingStatus as String;
        final phone = record.phoneNumber as String?;
        final notes = record.notes as String?;
        final createdAt = record.createdAt as String;
        final originDev = record.originDeviceId as String;

        if (classification == 'NEW' || classification == 'STALE') {
          // Resolve voter id
          final vRows = _db.select(
            'SELECT id FROM voters WHERE roll_version_id = ? AND epic_number = ? LIMIT 1',
            [preview.rollVersionId as String, epic],
          );
          final voterId = vRows.isNotEmpty ? vRows.first['id'] as String : null;

          // Insert observation record
          _db.execute(
            '''
            INSERT OR IGNORE INTO field_observations
              (id, observation_id, voter_id, voter_epic, voter_part_serial,
               roll_version_id, roll_checksum, field_status, phone_number, notes,
               created_by, created_at, origin_device_id, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              _uuid.v4(), obsId, voterId, epic, obs['voter_part_serial'],
              preview.rollVersionId, preview.rollChecksum, status, phone, notes,
              obs['created_by'] ?? operatorUsername, createdAt, originDev, now,
            ],
          );

          if (classification == 'NEW' && voterId != null) {
            // Upsert materialized field status
            _db.execute(
              '''
              INSERT INTO field_status (id, voter_id, status, phone_number, notes, reported_by, reported_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(voter_id) DO UPDATE SET
                status = excluded.status,
                phone_number = excluded.phone_number,
                notes = excluded.notes,
                reported_by = excluded.reported_by,
                updated_at = excluded.updated_at
              ''',
              [_uuid.v4(), voterId, status, phone, notes, operatorUsername, createdAt, now],
            );
          }

          importedCount++;
        } else if (classification == 'CONCURRENT') {
          // Insert observation
          final vRows = _db.select(
            'SELECT id FROM voters WHERE roll_version_id = ? AND epic_number = ? LIMIT 1',
            [preview.rollVersionId as String, epic],
          );
          final voterId = vRows.isNotEmpty ? vRows.first['id'] as String : null;
          _db.execute(
            '''
            INSERT OR IGNORE INTO field_observations
              (id, observation_id, voter_id, voter_epic, voter_part_serial,
               roll_version_id, roll_checksum, field_status, phone_number, notes,
               created_by, created_at, origin_device_id, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''',
            [
              _uuid.v4(), obsId, voterId, epic, obs['voter_part_serial'],
              preview.rollVersionId, preview.rollChecksum, status, phone, notes,
              obs['created_by'] ?? operatorUsername, createdAt, originDev, now,
            ],
          );

          // Local observation id
          final localObsRows = _db.select(
            'SELECT observation_id FROM field_observations WHERE voter_epic = ? AND observation_id != ? ORDER BY created_at DESC LIMIT 1',
            [epic, obsId],
          );
          final localObsId = localObsRows.isNotEmpty ? localObsRows.first['observation_id'] as String : '';

          // Insert conflict record
          _db.execute(
            '''
            INSERT INTO sync_conflicts
              (id, voter_id, voter_epic, conflict_type, local_observation_id, incoming_observation_id, resolution_status, created_at)
            VALUES (?, ?, ?, 'CONCURRENT', ?, ?, 'PENDING_REVIEW', ?)
            ''',
            [_uuid.v4(), voterId, epic, localObsId, obsId, now],
          );
          conflictCount++;
        } else {
          skippedCount++;
        }
      }

      // Record packet as imported
      recordSyncPacket(
        packetId: preview.packetId as String,
        direction: 'IMPORT',
        protocolVersion: preview.records is List ? 1 : 1,
        sourceDeviceId: preview.sourceDeviceId as String,
        sourceUserId: operatorUsername,
        rollVersionId: preview.rollVersionId as String,
        rollChecksum: preview.rollChecksum as String,
        observationCount: importedCount,
        status: 'COMMITTED',
        statusMessage: 'Imported $importedCount observations, $conflictCount conflicts',
      );

      logAudit(
        action: 'SYNC_IMPORT_COMMITTED',
        entityType: 'SyncPacket',
        entityId: preview.packetId as String,
        performedBy: operatorUsername,
        details: 'Imported: $importedCount, Conflicts: $conflictCount, Skipped: $skippedCount',
      );

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    return {
      'status': 'SUCCESS',
      'imported_count': importedCount,
      'conflict_count': conflictCount,
      'skipped_count': skippedCount,
    };
  }

  /// Inspects and validates a decrypted Gazette Snapshot against local database rules without mutating state.
  GazetteSnapshotPreview previewGazetteSnapshot({
    required Map<String, dynamic> envelope,
    required Map<String, dynamic> payload,
  }) {
    final packetId = envelope['packet_id'] as String? ?? '';
    final sourceDeviceId = envelope['source_device_id'] as String? ?? '';
    final sourceUserId = envelope['source_user_id'] as String? ?? '';
    final envelopeRollVersionId = envelope['roll_version_id'] as String? ?? '';
    final envelopeRollChecksum = envelope['roll_checksum'] as String? ?? '';
    final packetType = envelope['packet_type'] as String? ?? '';

    String? rejectionReason;

    // 1. Packet type & protocol version verification
    if (packetType != 'GAZETTE_SNAPSHOT') {
      rejectionReason = "Expected packet_type 'GAZETTE_SNAPSHOT', got '$packetType'";
    }

    final protoVer = envelope['protocol_version'];
    if (rejectionReason == null && (protoVer == null || protoVer != 1)) {
      rejectionReason = "Unsupported protocol version: $protoVer";
    }

    // 2. Roll metadata validation
    final rollMeta = payload['roll_metadata'];
    if (rejectionReason == null && (rollMeta == null || rollMeta is! Map<String, dynamic>)) {
      rejectionReason = "Snapshot manifest is missing 'roll_metadata'";
    }

    final metaMap = rollMeta is Map<String, dynamic> ? rollMeta : <String, dynamic>{};
    final rollId = metaMap['id'] as String? ?? envelopeRollVersionId;
    final state = metaMap['state'] as String? ?? '';
    final district = metaMap['district'] as String? ?? '';
    final ac = metaMap['assembly_constituency'] as String? ?? '';
    final rollName = metaMap['roll_name'] as String? ?? '';
    final rollType = metaMap['roll_type'] as String? ?? 'GENERAL';
    final pubDate = metaMap['publication_date'] as String?;
    final metaChecksum = metaMap['checksum_hash'] as String? ?? '';
    final recordCount = metaMap['record_count'] as int? ?? -1;

    // Cross-consistency between envelope and metadata/payload
    if (rejectionReason == null && metaMap.containsKey('id') && metaMap['id'] != envelopeRollVersionId) {
      rejectionReason = "Roll version ID mismatch: metadata declared '${metaMap['id']}', envelope declared '$envelopeRollVersionId'";
    }
    if (rejectionReason == null && payload.containsKey('roll_version_id') && payload['roll_version_id'] != envelopeRollVersionId) {
      rejectionReason = "Roll version ID mismatch: payload declared '${payload['roll_version_id']}', envelope declared '$envelopeRollVersionId'";
    }
    if (rejectionReason == null && payload.containsKey('packet_id') && payload['packet_id'] != packetId) {
      rejectionReason = "Packet ID mismatch: payload declared '${payload['packet_id']}', envelope declared '$packetId'";
    }
    if (rejectionReason == null && payload.containsKey('roll_checksum') && payload['roll_checksum'] != envelopeRollChecksum) {
      rejectionReason = "Checksum mismatch: payload declared '${payload['roll_checksum']}', envelope declared '$envelopeRollChecksum'";
    }

    if (rejectionReason == null) {
      for (final req in ['id', 'state', 'district', 'assembly_constituency', 'roll_name', 'checksum_hash']) {
        if (!metaMap.containsKey(req) || metaMap[req] == null) {
          rejectionReason = "Snapshot roll_metadata missing mandatory field '$req'";
          break;
        }
        if (metaMap[req] is! String || (metaMap[req] as String).trim().isEmpty) {
          rejectionReason = "Snapshot roll_metadata mandatory field '$req' must be a non-empty string";
          break;
        }
      }
      if (rejectionReason == null) {
        if (!metaMap.containsKey('record_count') || metaMap['record_count'] == null) {
          rejectionReason = "Snapshot roll_metadata missing mandatory field 'record_count'";
        } else if (metaMap['record_count'] is! int) {
          rejectionReason = "Snapshot roll_metadata field 'record_count' must be an integer";
        } else if ((metaMap['record_count'] as int) < 0) {
          rejectionReason = "Snapshot roll_metadata field 'record_count' cannot be negative (${metaMap['record_count']})";
        } else if ((metaMap['record_count'] as int) > 500000) {
          rejectionReason = "Snapshot roll_metadata record_count exceeds maximum supported limit of 500,000 (${metaMap['record_count']})";
        }
      }
    }

    // 3. Checksum consistency
    if (rejectionReason == null && metaChecksum != envelopeRollChecksum) {
      rejectionReason = "Declared checksum '$metaChecksum' does not match envelope checksum '$envelopeRollChecksum'";
    }

    // 4. Voters list validation
    final rawVoters = payload['voters'];
    if (rejectionReason == null && (rawVoters == null || rawVoters is! List)) {
      rejectionReason = "Snapshot is missing 'voters' list";
    }

    final votersList = rawVoters is List ? rawVoters : [];
    if (rejectionReason == null && votersList.length != recordCount) {
      rejectionReason = "Voter record count mismatch: metadata declared $recordCount, payload contained ${votersList.length}";
    }

    if (rejectionReason == null) {
      final seenIds = <String>{};
      final seenEpics = <String>{};
      final seenPartSerials = <String>{};

      for (int i = 0; i < votersList.length; i++) {
        final v = votersList[i];
        if (v is! Map) {
          rejectionReason = "Malformed voter record at index $i";
          break;
        }
        for (final vf in ['id', 'serial_number', 'epic_number', 'name', 'part_number']) {
          if (!v.containsKey(vf) || v[vf] == null) {
            rejectionReason = "Voter record at index $i missing mandatory field '$vf'";
            break;
          }
        }
        if (rejectionReason != null) break;

        // Type & value validations
        final voterId = v['id'];
        if (voterId is! String || voterId.trim().isEmpty) {
          rejectionReason = "Voter record at index $i has invalid or empty 'id'";
          break;
        }

        final serialNum = v['serial_number'];
        if (serialNum is! int || serialNum <= 0) {
          rejectionReason = "Voter record at index $i has invalid 'serial_number' (must be a positive integer)";
          break;
        }

        final epic = v['epic_number'];
        if (epic is! String || epic.trim().isEmpty) {
          rejectionReason = "Voter record at index $i has invalid or empty 'epic_number'";
          break;
        }

        final vName = v['name'];
        if (vName is! String || vName.trim().isEmpty) {
          rejectionReason = "Voter record at index $i has invalid or empty 'name'";
          break;
        }

        final partStr = v['part_number'].toString().trim();
        if (partStr.isEmpty) {
          rejectionReason = "Voter record at index $i has empty 'part_number'";
          break;
        }

        // Foreign key / relationship consistency
        if (v.containsKey('roll_version_id') && v['roll_version_id'] != null) {
          if (v['roll_version_id'] != rollId) {
            rejectionReason = "Foreign key violation: Voter record at index $i specifies roll_version_id '${v['roll_version_id']}' which does not match snapshot roll_version_id '$rollId'";
            break;
          }
        }

        // Optional field typing
        if (v.containsKey('age') && v['age'] != null) {
          final ageVal = v['age'];
          if (ageVal is! int || ageVal < 0 || ageVal > 150) {
            rejectionReason = "Voter record at index $i has invalid 'age'";
            break;
          }
        }

        // Uniqueness validation within snapshot payload
        if (!seenIds.add(voterId)) {
          rejectionReason = "Duplicate voter ID detected at index $i";
          break;
        }

        final normalizedEpic = epic.trim().toUpperCase();
        if (!seenEpics.add(normalizedEpic)) {
          rejectionReason = "Duplicate EPIC number detected at index $i";
          break;
        }

        final partSerialKey = "$partStr:$serialNum";
        if (!seenPartSerials.add(partSerialKey)) {
          rejectionReason = "Duplicate serial number '$serialNum' in part '$partStr' at index $i";
          break;
        }
      }
    }

    // 5. Existing active roll protection check
    final activeRoll = getActiveRoll();
    bool isReplacingExistingRoll = false;
    String? existingActiveRollName;

    if (activeRoll != null) {
      existingActiveRollName = activeRoll.rollName;
      if (activeRoll.checksumHash == envelopeRollChecksum) {
        rejectionReason = "Roll '${activeRoll.rollName}' with checksum '$envelopeRollChecksum' is already installed and active";
      } else {
        isReplacingExistingRoll = true;
      }
    }

    final isSafe = rejectionReason == null;

    return GazetteSnapshotPreview(
      packetId: packetId,
      sourceDeviceId: sourceDeviceId,
      sourceUserId: sourceUserId,
      rollVersionId: rollId,
      rollChecksum: envelopeRollChecksum,
      rollName: rollName,
      state: state,
      district: district,
      assemblyConstituency: ac,
      rollType: rollType,
      publicationDate: pubDate,
      recordCount: recordCount >= 0 ? recordCount : votersList.length,
      voterRecordsInPayload: votersList.length,
      isSafeToInstall: isSafe,
      isReplacingExistingRoll: isReplacingExistingRoll,
      existingActiveRollName: existingActiveRollName,
      rejectionReason: rejectionReason,
      rawEnvelope: envelope,
      rawPayload: payload,
    );
  }

  /// Safely installs or bootstraps an official statutory roll from a validated Gazette Snapshot.
  Map<String, dynamic> installGazetteSnapshot({
    required GazetteSnapshotPreview preview,
    required String operatorUsername,
    bool allowReplaceActive = false,
  }) {
    // 1. RBAC authorization
    final role = operatorUsername.trim().toUpperCase();
    if (role != 'ADMIN' && role != 'MANAGER') {
      throw ArgumentError('Unauthorized: installGazetteSnapshot requires Manager or Admin privileges (got: $operatorUsername)');
    }

    // 2. Validate preview suitability
    if (!preview.isSafeToInstall || preview.rejectionReason != null) {
      throw StateError(preview.rejectionReason ?? 'Snapshot preview is not safe to install');
    }

    // 3. Existing active roll protection
    final activeRows = _db.select("SELECT * FROM roll_versions WHERE status = 'ACTIVE' LIMIT 1");
    if (activeRows.isNotEmpty) {
      final active = activeRows.first;
      if (active['checksum_hash'] == preview.rollChecksum) {
        throw StateError("Roll '${active['roll_name']}' with checksum '${preview.rollChecksum}' is already installed and active");
      }
      if (!allowReplaceActive) {
        throw StateError(
          "An active roll '${active['roll_name']}' is already installed. Explicit authorization required to replace an active roll.",
        );
      }
    }

    final votersList = preview.rawPayload['voters'] as List<dynamic>? ?? [];
    int votersInstalled = 0;

    // 4. Atomic transaction
    _db.execute('BEGIN TRANSACTION');
    try {
      // If replacing active roll, deactivate previous active roll
      if (activeRows.isNotEmpty && allowReplaceActive) {
        _db.execute("UPDATE roll_versions SET status = 'SUPERSEDED' WHERE status = 'ACTIVE'");
      }

      // Check if target roll version row already exists
      final existingRoll = _db.select('SELECT id FROM roll_versions WHERE id = ?', [preview.rollVersionId]);
      if (existingRoll.isNotEmpty) {
        _db.execute(
          "UPDATE roll_versions SET status = 'ACTIVE', record_count = ?, checksum_hash = ? WHERE id = ?",
          [preview.recordCount, preview.rollChecksum, preview.rollVersionId],
        );
      } else {
        _db.execute(
          '''
          INSERT INTO roll_versions (
            id, state, district, assembly_constituency, roll_name, roll_type,
            publication_date, record_count, status, checksum_hash
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ACTIVE', ?)
          ''',
          [
            preview.rollVersionId,
            preview.state,
            preview.district,
            preview.assemblyConstituency,
            preview.rollName,
            preview.rollType,
            preview.publicationDate,
            preview.recordCount,
            preview.rollChecksum,
          ],
        );
      }

      // Insert voters strictly enforcing constraints
      final voterStmt = _db.prepare(
        '''
        INSERT INTO voters (
          id, roll_version_id, serial_number, epic_number, name, normalized_name,
          relative_name, normalized_relative_name, relative_type,
          house_number, normalized_house_number, age, gender, part_number,
          section_number, section_name, polling_station_name, polling_station_address,
          photo_path, ocr_confidence
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
      );

      try {
        for (final item in votersList) {
          final v = item as Map<String, dynamic>;
          for (final vf in ['id', 'serial_number', 'epic_number', 'name', 'part_number']) {
            if (!v.containsKey(vf) || v[vf] == null) {
              throw FormatException("Voter record missing mandatory field '$vf'");
            }
          }

          final name = v['name'] as String;
          final normName = (v['normalized_name'] as String?) ?? name.toLowerCase();
          final relName = (v['relative_name'] as String?) ?? '';
          final normRelName = (v['normalized_relative_name'] as String?) ?? relName.toLowerCase();
          final house = (v['house_number'] as String?) ?? '';
          final normHouse = (v['normalized_house_number'] as String?) ?? house.toLowerCase();

          voterStmt.execute([
            v['id'] as String,
            preview.rollVersionId,
            v['serial_number'] as int,
            v['epic_number'] as String,
            name,
            normName,
            relName,
            normRelName,
            (v['relative_type'] as String?) ?? 'OTHER',
            house,
            normHouse,
            (v['age'] as int?) ?? 0,
            (v['gender'] as String?) ?? '',
            v['part_number'].toString(),
            v['section_number']?.toString() ?? '',
            (v['section_name'] as String?) ?? '',
            (v['polling_station_name'] as String?) ?? '',
            (v['polling_station_address'] as String?) ?? '',
            v['photo_path'] as String?,
            (v['ocr_confidence'] as num?)?.toDouble() ?? 1.0,
          ]);
          votersInstalled++;
        }
      } finally {
        voterStmt.dispose();
      }

      // Update electoral area config
      saveAreaConfig(
        state: preview.state,
        district: preview.district,
        assemblyConstituency: preview.assemblyConstituency,
        activeRollId: preview.rollVersionId,
      );

      // Record packet in sync_packets
      recordSyncPacket(
        packetId: preview.packetId,
        direction: 'IMPORT',
        protocolVersion: 1,
        sourceDeviceId: preview.sourceDeviceId,
        sourceUserId: operatorUsername,
        rollVersionId: preview.rollVersionId,
        rollChecksum: preview.rollChecksum,
        observationCount: 0,
        status: 'COMMITTED',
        statusMessage: 'Bootstrapped Gazette snapshot with $votersInstalled voters',
      );

      // Log in audit_logs
      logAudit(
        action: 'GAZETTE_SNAPSHOT_RESTORED',
        entityType: 'RollVersion',
        entityId: preview.rollVersionId,
        performedBy: operatorUsername,
        details: 'Bootstrapped roll "${preview.rollName}" ($votersInstalled voters, checksum: ${preview.rollChecksum})',
      );

      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }

    return {
      'status': 'BOOTSTRAP_SUCCESS',
      'packet_id': preview.packetId,
      'roll_version_id': preview.rollVersionId,
      'roll_name': preview.rollName,
      'voters_installed': votersInstalled,
      'roll_checksum': preview.rollChecksum,
    };
  }

  /// Returns aggregate sync statistics for the dashboard.
  Map<String, dynamic> getSyncStats() {
    final obsCount = (_db.select('SELECT COUNT(*) AS cnt FROM field_observations WHERE is_revoked = 0').firstOrNull?['cnt'] as int?) ?? 0;
    final conflictCount = (_db.select("SELECT COUNT(*) AS cnt FROM sync_conflicts WHERE resolution_status = 'PENDING_REVIEW'").firstOrNull?['cnt'] as int?) ?? 0;
    final lastImportRow = _db.select("SELECT processed_at FROM sync_packets WHERE direction = 'IMPORT' AND status = 'COMMITTED' ORDER BY processed_at DESC LIMIT 1");
    final lastExportRow = _db.select("SELECT processed_at FROM sync_packets WHERE direction = 'EXPORT' ORDER BY processed_at DESC LIMIT 1");
    final deviceId = getDeviceId();

    return {
      'device_id': deviceId,
      'device_name': 'VoterLens Field Unit',
      'total_observations': obsCount,
      'pending_conflicts': conflictCount,
      'last_import_at': lastImportRow.isNotEmpty ? lastImportRow.first['processed_at'] : null,
      'last_export_at': lastExportRow.isNotEmpty ? lastExportRow.first['processed_at'] : null,
    };
  }

  /// Returns sync packet history (most recent first).
  List<Map<String, dynamic>> getSyncPackets({int limit = 50}) {
    final rows = _db.select(
      'SELECT * FROM sync_packets ORDER BY processed_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Returns pending sync conflicts.
  List<Map<String, dynamic>> getSyncConflicts({bool pendingOnly = true}) {
    final where = pendingOnly ? "WHERE resolution_status = 'PENDING_REVIEW'" : '';
    final rows = _db.select(
      'SELECT sc.*, v.name AS voter_name FROM sync_conflicts sc LEFT JOIN voters v ON sc.voter_id = v.id $where ORDER BY sc.created_at DESC',
    );
    return rows.map((r) => Map<String, dynamic>.from(r)).toList();
  }

  /// Resolves a conflict with a given choice (ACCEPT_A / ACCEPT_B).
  void resolveConflict({
    required String conflictId,
    required String choice,
    required String resolvedBy,
    String? notes,
  }) {
    final now = DateTime.now().toIso8601String();
    final conflictRows = _db.select('SELECT * FROM sync_conflicts WHERE id = ? LIMIT 1', [conflictId]);
    if (conflictRows.isEmpty) return;
    final conflict = conflictRows.first;

    final resolutionStatus = choice == 'ACCEPT_A' ? 'RESOLVED_ACCEPTED_A'
        : choice == 'ACCEPT_B' ? 'RESOLVED_ACCEPTED_B'
        : 'RESOLVED_MERGED';

    _db.execute(
      '''
      UPDATE sync_conflicts SET
        resolution_status = ?, resolved_by = ?, resolved_at = ?,
        resolution_choice = ?, resolution_notes = ?
      WHERE id = ?
      ''',
      [resolutionStatus, resolvedBy, now, choice, notes, conflictId],
    );

    // If ACCEPT_B, apply incoming observation's status
    if (choice == 'ACCEPT_B') {
      final incomingObsId = conflict['incoming_observation_id'] as String?;
      if (incomingObsId != null && incomingObsId.isNotEmpty) {
        final obsRows = _db.select(
          'SELECT voter_id, field_status, phone_number, notes, created_at FROM field_observations WHERE observation_id = ? LIMIT 1',
          [incomingObsId],
        );
        if (obsRows.isNotEmpty) {
          final obs = obsRows.first;
          final voterId = obs['voter_id'] as String?;
          if (voterId != null) {
            _db.execute(
              '''
              INSERT INTO field_status (id, voter_id, status, phone_number, notes, reported_by, reported_at, updated_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT(voter_id) DO UPDATE SET
                status = excluded.status,
                phone_number = excluded.phone_number,
                notes = excluded.notes,
                reported_by = excluded.reported_by,
                updated_at = excluded.updated_at
              ''',
              [_uuid.v4(), voterId, obs['field_status'], obs['phone_number'], obs['notes'], resolvedBy, obs['created_at'], now],
            );
          }
        }
      }
    }

    logAudit(
      action: 'CONFLICT_RESOLVED',
      entityType: 'SyncConflict',
      entityId: conflictId,
      performedBy: resolvedBy,
      details: 'Choice: $choice${notes != null ? ", Notes: $notes" : ""}',
    );
  }

  /// Checks if a supervisor passcode verifier has been stored.
  bool isSupervisorPinEstablished() {
    try {
      final rows = _db.select('SELECT COUNT(*) AS cnt FROM auth_configs');
      return (rows.first['cnt'] as int? ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  /// Retrieves the stored authentication config.
  Map<String, dynamic>? getAuthConfig() {
    try {
      final rows = _db.select('SELECT * FROM auth_configs LIMIT 1');
      if (rows.isEmpty) return null;
      return Map<String, dynamic>.from(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// Saves or updates the supervisor passcode verifier.
  void saveSupervisorPin({
    required String saltHex,
    required String hashHex,
    required String performedBy,
  }) {
    final now = DateTime.now().toIso8601String();
    _db.execute('DELETE FROM auth_configs');
    _db.execute(
      '''
      INSERT INTO auth_configs (id, pin_salt_hex, pin_hash_hex, failed_attempts, locked_until_epoch, created_at, updated_at)
      VALUES (?, ?, ?, 0, 0, ?, ?)
      ''',
      [_uuid.v4(), saltHex, hashHex, now, now],
    );
    logAudit(
      action: 'SUPERVISOR_PIN_ESTABLISHED',
      entityType: 'AuthConfig',
      entityId: 'SUPERVISOR_PIN',
      performedBy: performedBy,
      details: 'Supervisor passcode configured',
    );
  }

  /// Resets failed attempt counter after successful verification.
  void resetPinFailedAttempts() {
    _db.execute('UPDATE auth_configs SET failed_attempts = 0, locked_until_epoch = 0');
  }

  /// Records a failed passcode attempt and lockout epoch.
  void recordPinFailedAttempt({
    required int failedAttempts,
    required int lockedUntilEpoch,
  }) {
    final now = DateTime.now().toIso8601String();
    _db.execute(
      'UPDATE auth_configs SET failed_attempts = ?, locked_until_epoch = ?, updated_at = ?',
      [failedAttempts, lockedUntilEpoch, now],
    );
  }

  void close() {
    _db.dispose();
  }
}

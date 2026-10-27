import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../services/run_points.dart';
import 'run_database.dart';

/// Result of inserting runs that may already exist.
class UpsertResult {
  const UpsertResult({required this.inserted, required this.updated});

  final int inserted;
  final int updated;

  int get written => inserted + updated;
}

/// Where a historical import stopped, so it can continue after a pause.
class ImportCursor {
  const ImportCursor({
    required this.since,
    required this.pageToken,
    required this.pagingComplete,
    required this.done,
    required this.pagesDone,
    required this.runsStored,
  });

  final DateTime since;
  final String? pageToken;
  final bool pagingComplete;
  final bool done;
  final int pagesDone;
  final int runsStored;

  ImportCursor copyWith({
    DateTime? since,
    String? pageToken,
    bool clearPageToken = false,
    bool? pagingComplete,
    bool? done,
    int? pagesDone,
    int? runsStored,
  }) {
    return ImportCursor(
      since: since ?? this.since,
      pageToken: clearPageToken ? null : (pageToken ?? this.pageToken),
      pagingComplete: pagingComplete ?? this.pagingComplete,
      done: done ?? this.done,
      pagesDone: pagesDone ?? this.pagesDone,
      runsStored: runsStored ?? this.runsStored,
    );
  }

  Map<String, dynamic> toJson() => {
        'since': DateTime(since.year, since.month, since.day).toIso8601String(),
        'pageToken': pageToken,
        'pagingComplete': pagingComplete,
        'done': done,
        'pagesDone': pagesDone,
        'runsStored': runsStored,
      };

  static ImportCursor fromJson(Map<String, dynamic> json) {
    final since = DateTime.tryParse(json['since']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final token = json['pageToken']?.toString();
    return ImportCursor(
      since: since,
      pageToken: (token == null || token.isEmpty) ? null : token,
      pagingComplete: json['pagingComplete'] == true,
      done: json['done'] == true,
      pagesDone: _asInt(json['pagesDone']),
      runsStored: _asInt(json['runsStored']),
    );
  }
}

/// Page token for an incremental sync that has not yet overlapped the
/// previous watermark. Keeps a gap from being skipped if the app stops early.
class IncrementalCheckpoint {
  const IncrementalCheckpoint({
    required this.anchor,
    this.pageToken,
    this.pagingComplete = false,
  });

  final DateTime anchor;
  final String? pageToken;

  /// Pages have overlapped the anchor. Detail fetches for the new runs may
  /// still be outstanding.
  final bool pagingComplete;

  Map<String, dynamic> toJson() => {
        'anchor': anchor.toUtc().toIso8601String(),
        'pageToken': pageToken,
        'pagingComplete': pagingComplete,
      };

  static IncrementalCheckpoint? fromJson(Map<String, dynamic> json) {
    final anchor = DateTime.tryParse(json['anchor']?.toString() ?? '');
    if (anchor == null) return null;
    final token = json['pageToken']?.toString();
    return IncrementalCheckpoint(
      anchor: anchor,
      pageToken: (token == null || token.isEmpty) ? null : token,
      pagingComplete: json['pagingComplete'] == true,
    );
  }
}

/// Detail payload stored for one run.
class RunDetailPayload {
  const RunDetailPayload({
    required this.heartRate,
    required this.distance,
    required this.route,
    required this.splits,
    this.heartRateSource = 'google_health',
  });

  final List<Map<String, dynamic>> heartRate;
  final List<Map<String, dynamic>> distance;
  final List<Map<String, dynamic>> route;
  final List<Map<String, dynamic>> splits;
  final String heartRateSource;
}

class RunRepository {
  RunRepository(this._db);

  final Database _db;

  static RunRepository? _cached;

  /// Opens the on-device database, or returns null when storage is unavailable
  /// (for example widget tests without a path provider).
  static Future<RunRepository?> openIfPossible() async {
    final cached = _cached;
    if (cached != null) return cached;
    // Widget tests have no device directory. Skip the plugin call so the UI
    // keeps using the in-memory exercise cache those tests already seed.
    if (RunDatabase.debugOpen == null && Platform.environment['FLUTTER_TEST'] == 'true') {
      return null;
    }
    try {
      final db = await RunDatabase.open();
      return _cached = RunRepository(db);
    } catch (_) {
      return null;
    }
  }

  static void debugResetCache() {
    _cached = null;
  }

  Future<UpsertResult> upsertRuns(
    List<Map<String, dynamic>> runs, {
    String source = 'google_health',
  }) async {
    var inserted = 0;
    var updated = 0;
    await _db.transaction((txn) async {
      for (final run in runs) {
        if (!isRunningExercise(run)) continue;
        final start = exerciseStart(run);
        final startIso = exerciseStartIso(run);
        if (start == null || startIso == null) continue;
        final id = stableRunId(run);
        final exercise = run['exercise'];
        final exerciseMap = exercise is Map ? exercise : const <String, dynamic>{};
        final now = DateTime.now().toUtc().toIso8601String();
        final row = <String, Object?>{
          'source': source,
          'start_time': startIso,
          'end_time': exerciseEndIso(run),
          'start_ms': start.millisecondsSinceEpoch,
          'end_ms': exerciseEnd(run)?.millisecondsSinceEpoch,
          'exercise_type': exerciseMap['exerciseType']?.toString(),
          'display_name': exerciseMap['displayName']?.toString(),
          'payload_json': jsonEncode(run),
          'updated_at': now,
        };
        final existing = await txn.query(
          'runs',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (existing.isEmpty) {
          row['id'] = id;
          row['details_fetched'] = 0;
          row['detail_attempts'] = 0;
          row['hr_sample_count'] = 0;
          await txn.insert('runs', row);
          inserted++;
        } else {
          await txn.update('runs', row, where: 'id = ?', whereArgs: [id]);
          updated++;
        }
      }
      await _writeWatermark(txn);
    });
    return UpsertResult(inserted: inserted, updated: updated);
  }

  /// Newest first. Each map is the original exercise point.
  Future<List<Map<String, dynamic>>> listRuns() async {
    final rows = await _db.query('runs', orderBy: 'start_ms DESC');
    return rows.map((row) => _decodeMap(row['payload_json'])).toList();
  }

  Future<int> countRuns() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM runs');
    return _asInt(rows.first['c']);
  }

  /// Newest stored start. This is the incremental-sync watermark.
  Future<DateTime?> latestStart() async {
    final stored = await _state('watermark');
    if (stored != null) {
      final parsed = DateTime.tryParse(stored);
      if (parsed != null) return parsed;
    }
    final rows = await _db.query('runs', columns: ['start_time'], orderBy: 'start_ms DESC', limit: 1);
    if (rows.isEmpty) return null;
    return DateTime.tryParse(rows.first['start_time'] as String? ?? '');
  }

  Future<bool> hasDetails(String runId) async {
    final rows = await _db.query(
      'runs',
      columns: ['details_fetched'],
      where: 'id = ?',
      whereArgs: [runId],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    return _asInt(rows.first['details_fetched']) == 1;
  }

  Future<int> detailAttempts(String runId) async {
    final rows = await _db.query(
      'runs',
      columns: ['detail_attempts'],
      where: 'id = ?',
      whereArgs: [runId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return _asInt(rows.first['detail_attempts']);
  }

  Future<void> recordDetailFailure(String runId) async {
    await _db.rawUpdate(
      'UPDATE runs SET detail_attempts = detail_attempts + 1, updated_at = ? WHERE id = ?',
      [DateTime.now().toUtc().toIso8601String(), runId],
    );
  }

  Future<void> markDetailsSkipped(String runId) async {
    await _db.update(
      'runs',
      {
        'details_fetched': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
  }

  Future<List<Map<String, dynamic>>> runsMissingDetails({DateTime? since}) async {
    final sinceMs = since == null ? null : DateTime(since.year, since.month, since.day).millisecondsSinceEpoch;
    final rows = await _db.query(
      'runs',
      columns: ['payload_json'],
      where: sinceMs == null ? 'details_fetched = 0' : 'details_fetched = 0 AND start_ms >= ?',
      whereArgs: sinceMs == null ? null : [sinceMs],
      orderBy: 'start_ms DESC',
    );
    return rows.map((row) => _decodeMap(row['payload_json'])).toList();
  }

  Future<void> saveDetails(String runId, RunDetailPayload details) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await _writeDetail(txn, runId, 'heart_rate', details.heartRate, details.heartRateSource, now);
      await _writeDetail(txn, runId, 'distance', details.distance, 'google_health', now);
      await _writeDetail(txn, runId, 'route', details.route, 'google_health', now);
      await _writeDetail(txn, runId, 'splits', details.splits, 'computed', now);
      await txn.update(
        'runs',
        {
          'details_fetched': 1,
          'hr_sample_count': details.heartRate.length,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [runId],
      );
    });

    final payload = await _payload(runId);
    if (payload == null) return;
    final start = exerciseStartIso(payload);
    final end = exerciseEndIso(payload);
    final name = payload['name']?.toString();
    if (start != null && end != null) {
      await saveBlob('hr|$start|$end', 'heart_rate', details.heartRate, source: details.heartRateSource);
      await saveBlob('distance|$start|$end', 'distance', details.distance, source: 'google_health');
    }
    if (name != null && name.isNotEmpty) {
      await saveBlob('route|$name', 'route', details.route, source: 'google_health');
    }
  }

  /// Google samples, unless a chest-strap series with at least 10 points exists.
  Future<List<Map<String, dynamic>>> heartRateSamples(String runId) async {
    final strap = await readRunDetail(runId, 'heart_rate_runkeeper');
    if (strap != null && strap.length >= 10) return strap;
    return await readRunDetail(runId, 'heart_rate') ?? const [];
  }

  Future<void> saveHeartRate(
    String runId,
    List<Map<String, dynamic>> samples, {
    required String source,
  }) async {
    final kind = source == 'runkeeper' ? 'heart_rate_runkeeper' : 'heart_rate';
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await _writeDetail(txn, runId, kind, samples, source, now);
      if (kind == 'heart_rate') {
        await txn.update(
          'runs',
          {'hr_sample_count': samples.length, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [runId],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>?> readRunDetail(String runId, String kind) async {
    final rows = await _db.query(
      'run_details',
      columns: ['payload_json'],
      where: 'run_id = ? AND kind = ?',
      whereArgs: [runId, kind],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeList(rows.first['payload_json']);
  }

  Future<void> saveBlob(
    String cacheKey,
    String kind,
    List<Map<String, dynamic>> points, {
    String? source,
  }) async {
    await _db.insert(
      'detail_blobs',
      {
        'cache_key': cacheKey,
        'kind': kind,
        'payload_json': jsonEncode(points),
        'source': source,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>?> readBlob(String cacheKey) async {
    final rows = await _db.query(
      'detail_blobs',
      columns: ['payload_json'],
      where: 'cache_key = ?',
      whereArgs: [cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeList(rows.first['payload_json']);
  }

  /// Links a screen cache key (`hr|start|end`, `distance|start|end`, `route|id`)
  /// to the stored run when one matches.
  Future<String?> matchRunId({required String cacheKey, required String kind}) async {
    if (kind == 'route' && cacheKey.startsWith('route|')) {
      final id = cacheKey.substring('route|'.length);
      final rows = await _db.query('runs', columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return null;
      return id;
    }
    if ((kind == 'heart_rate' || kind == 'distance') && cacheKey.contains('|')) {
      final parts = cacheKey.split('|');
      if (parts.length != 3) return null;
      final rows = await _db.query(
        'runs',
        columns: ['id'],
        where: 'start_time = ? AND end_time = ?',
        whereArgs: [parts[1], parts[2]],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return rows.first['id'] as String?;
    }
    return null;
  }

  Future<void> saveRunDetail(
    String runId,
    String kind,
    List<Map<String, dynamic>> points, {
    String? source,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await _writeDetail(txn, runId, kind, points, source, now);
      if (kind == 'heart_rate') {
        await txn.update(
          'runs',
          {'hr_sample_count': points.length, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [runId],
        );
      }
    });
  }

  Future<void> markDetailsFetchedIfComplete(String runId) async {
    final rows = await _db.query(
      'run_details',
      columns: ['kind'],
      where: 'run_id = ?',
      whereArgs: [runId],
    );
    final kinds = rows.map((row) => row['kind']).toSet();
    if (!kinds.contains('heart_rate') || !kinds.contains('distance') || !kinds.contains('route')) {
      return;
    }
    final hr = await readRunDetail(runId, 'heart_rate');
    await _db.update(
      'runs',
      {
        'details_fetched': 1,
        'hr_sample_count': hr?.length ?? 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [runId],
    );
  }

  Future<ImportCursor?> importCursor() async {
    final raw = await _state('import_cursor');
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return ImportCursor.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<void> saveImportCursor(ImportCursor cursor) async {
    await _setState('import_cursor', jsonEncode(cursor.toJson()));
  }

  Future<void> clearImportCursor() async {
    await _db.delete('sync_state', where: 'key = ?', whereArgs: ['import_cursor']);
  }

  Future<IncrementalCheckpoint?> incrementalCheckpoint() async {
    final raw = await _state('incremental_checkpoint');
    if (raw == null) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return IncrementalCheckpoint.fromJson(Map<String, dynamic>.from(decoded));
  }

  Future<void> saveIncrementalCheckpoint(IncrementalCheckpoint checkpoint) async {
    await _setState('incremental_checkpoint', jsonEncode(checkpoint.toJson()));
  }

  Future<void> clearIncrementalCheckpoint() async {
    await _db.delete('sync_state', where: 'key = ?', whereArgs: ['incremental_checkpoint']);
  }

  Future<String?> _state(String key) async {
    final rows = await _db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> _setState(String key, String value) async {
    await _db.insert(
      'sync_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> _payload(String runId) async {
    final rows = await _db.query(
      'runs',
      columns: ['payload_json'],
      where: 'id = ?',
      whereArgs: [runId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _decodeMap(rows.first['payload_json']);
  }

  Future<void> _writeWatermark(DatabaseExecutor txn) async {
    final rows = await txn.query(
      'runs',
      columns: ['start_time'],
      orderBy: 'start_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return;
    final iso = rows.first['start_time'] as String?;
    if (iso == null || iso.isEmpty) return;
    await txn.insert(
      'sync_state',
      {'key': 'watermark', 'value': iso},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _writeDetail(
    DatabaseExecutor txn,
    String runId,
    String kind,
    List<Map<String, dynamic>> points,
    String? source,
    String now,
  ) async {
    await txn.insert(
      'run_details',
      {
        'run_id': runId,
        'kind': kind,
        'payload_json': jsonEncode(points),
        'source': source,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

Map<String, dynamic> _decodeMap(Object? raw) {
  if (raw is! String || raw.isEmpty) return <String, dynamic>{};
  final decoded = jsonDecode(raw);
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _decodeList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  return decoded.map((item) {
    if (item is Map) return Map<String, dynamic>.from(item);
    return <String, dynamic>{};
  }).toList();
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

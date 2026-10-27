import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// On-device SQLite database for runs and their detail payloads.
///
/// Schema version is [schemaVersion]. [onCreate] builds the latest schema.
/// [onUpgrade] migrates older files. Heart-rate samples for one run live in
/// `run_details` with `kind = 'heart_rate'` (Google Health) or
/// `kind = 'heart_rate_runkeeper'` (chest strap). The JSON payload is a list
/// of `{"time": "<ISO-8601>", "bpm": <number>}`. `runs.hr_sample_count` is the
/// number of Google Health samples and is added by the v1 → v2 migration.
class RunDatabase {
  RunDatabase._();

  static const schemaVersion = 2;
  static const fileName = 'runs.db';

  static Database? _db;
  static Future<Database>? _opening;

  /// Test hook. When set, [open] does not touch the device documents directory.
  static Future<Database> Function()? debugOpen;

  static Future<Database> open() {
    final custom = debugOpen;
    if (custom != null) return custom();
    final existing = _db;
    if (existing != null) return Future.value(existing);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  static Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final db = await openDatabase(
      '${dir.path}/$fileName',
      version: schemaVersion,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    );
    _db = db;
    return db;
  }

  static Future<void> debugClose() async {
    final db = _db;
    _db = null;
    _opening = null;
    if (db != null) await db.close();
  }

  static Future<void> onCreate(Database db, int version) async {
    await createV1(db);
    if (version >= 2) {
      await _addHrSampleCount(db);
    }
  }

  static Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _addHrSampleCount(db);
    }
  }

  static Future<void> createV1(Database db) async {
    await db.execute('''
      CREATE TABLE runs (
        id TEXT PRIMARY KEY,
        source TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER,
        exercise_type TEXT,
        display_name TEXT,
        payload_json TEXT NOT NULL,
        details_fetched INTEGER NOT NULL DEFAULT 0,
        detail_attempts INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_runs_start_ms ON runs(start_ms)');
    await db.execute('''
      CREATE TABLE run_details (
        run_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        source TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (run_id, kind)
      )
    ''');
    await db.execute('''
      CREATE TABLE detail_blobs (
        cache_key TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        source TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _addHrSampleCount(Database db) async {
    final columns = await db.rawQuery('PRAGMA table_info(runs)');
    final exists = columns.any((column) => column['name'] == 'hr_sample_count');
    if (exists) return;
    await db.execute(
      'ALTER TABLE runs ADD COLUMN hr_sample_count INTEGER NOT NULL DEFAULT 0',
    );
  }
}

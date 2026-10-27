import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:run_aggregator/db/run_database.dart';
import 'package:run_aggregator/db/run_repository.dart';
import 'package:run_aggregator/services/exercise_page.dart';
import 'package:run_aggregator/services/rate_limit.dart';
import 'package:run_aggregator/services/run_points.dart';
import 'package:run_aggregator/services/run_sync.dart';
import 'package:run_aggregator/services/split_snapshot.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('run point helpers', () {
    test('stable id, running check, german date, and civil filter', () {
      final run = _run(id: 'users/me/dataPoints/1', start: DateTime.utc(2024, 3, 5, 7, 30));
      expect(stableRunId(run), 'users/me/dataPoints/1');
      expect(isRunningExercise(run), isTrue);
      expect(isRunningExercise(_run(id: 'w', start: DateTime.utc(2024, 3, 5), type: 'WALKING', name: 'Spaziergang')), isFalse);
      expect(formatGermanDate(DateTime(2024, 3, 5)), '05.03.2024');
      expect(
        exerciseSinceFilter(DateTime(2024, 3, 5)),
        'exercise.interval.civil_start_time >= "2024-03-05"',
      );
      expect(isOnOrAfterDay(DateTime(2024, 3, 5, 0, 30), DateTime(2024, 3, 5)), isTrue);
      expect(isOnOrAfterDay(DateTime(2024, 3, 4, 23, 30), DateTime(2024, 3, 5)), isFalse);
    });

    test('falls back to source and start when the resource name is missing', () {
      final run = _run(id: '', start: DateTime.utc(2024, 1, 2, 3));
      run.remove('name');
      expect(stableRunId(run), startsWith('google_health|'));
    });

    test('rate limit backoff honors Retry-After and caps the wait', () {
      expect(rateLimitBackoff(0, null), const Duration(seconds: 1));
      expect(rateLimitBackoff(1, null), const Duration(seconds: 2));
      expect(rateLimitBackoff(10, null), const Duration(seconds: 32));
      expect(rateLimitBackoff(0, const Duration(seconds: 5)), const Duration(seconds: 5));
      expect(retryAfterFromHeader('3'), const Duration(seconds: 3));
      expect(retryAfterFromHeader('Wed, 21 Oct 2015 07:28:00 GMT'), isNull);
    });
  });

  group('splits', () {
    test('two exact kilometers become two splits', () {
      final start = DateTime.utc(2024, 4, 1, 8);
      final points = [
        _km(start, 300),
        _km(start.add(const Duration(seconds: 300)), 360),
      ];
      final splits = computeKmSplits(points, 1);
      expect(splits, hasLength(2));
      expect(splits.first['distanceKm'], 1);
      expect(splits.first['durationSec'], 300);
      expect(splits.last['durationSec'], 360);
    });
  });

  group('repository', () {
    late Database db;
    late RunRepository repo;
    late String path;

    setUp(() async {
      path = '${Directory.systemTemp.path}/runs_${DateTime.now().microsecondsSinceEpoch}.db';
      db = await openDatabase(
        path,
        version: RunDatabase.schemaVersion,
        onCreate: RunDatabase.onCreate,
        onUpgrade: RunDatabase.onUpgrade,
      );
      repo = RunRepository(db);
    });

    tearDown(() async {
      await db.close();
      final file = File(path);
      if (await file.exists()) await file.delete();
    });

    test('dedupes by stable id and keeps stored details', () async {
      final start = DateTime.utc(2024, 5, 1, 8);
      await repo.upsertRuns([_run(id: 'run-a', start: start, name: 'Alt')]);
      await repo.saveDetails('run-a', _details());
      final again = await repo.upsertRuns([_run(id: 'run-a', start: start, name: 'Neu')]);

      expect(again.inserted, 0);
      expect(again.updated, 1);
      expect(await repo.countRuns(), 1);
      final stored = await repo.listRuns();
      expect(stored.single['exercise']['displayName'], 'Neu');
      expect(await repo.hasDetails('run-a'), isTrue);
      expect((await repo.heartRateSamples('run-a')).single['bpm'], 140);
      expect(await repo.readRunDetail('run-a', 'splits'), isNotEmpty);
    });

    test('watermark is the newest start and does not move backwards', () async {
      await repo.upsertRuns([
        _run(id: 'old', start: DateTime.utc(2024, 1, 1, 8)),
        _run(id: 'new', start: DateTime.utc(2024, 6, 1, 8)),
      ]);
      expect(await repo.latestStart(), DateTime.utc(2024, 6, 1, 8));
      await repo.upsertRuns([_run(id: 'mid', start: DateTime.utc(2024, 3, 1, 8))]);
      expect(await repo.latestStart(), DateTime.utc(2024, 6, 1, 8));
      expect(await repo.countRuns(), 3);
    });

    test('chest-strap samples win once there are at least ten', () async {
      final start = DateTime.utc(2024, 5, 1, 8);
      await repo.upsertRuns([_run(id: 'run-a', start: start)]);
      await repo.saveHeartRate(
        'run-a',
        List.generate(12, (i) => {'time': start.add(Duration(seconds: i)).toIso8601String(), 'bpm': 160}),
        source: 'runkeeper',
      );
      await repo.saveHeartRate(
        'run-a',
        [
          {'time': start.toIso8601String(), 'bpm': 120},
        ],
        source: 'google_health',
      );
      expect((await repo.heartRateSamples('run-a')).length, 12);
      expect((await repo.heartRateSamples('run-a')).first['bpm'], 160);

      await repo.saveHeartRate(
        'run-a',
        [
          {'time': start.toIso8601String(), 'bpm': 161},
        ],
        source: 'runkeeper',
      );
      expect((await repo.heartRateSamples('run-a')).single['bpm'], 120);
    });

    test('ignores activities that are not runs', () async {
      final result = await repo.upsertRuns([
        _run(id: 'walk', start: DateTime.utc(2024, 1, 1), type: 'WALKING', name: 'Spaziergang'),
      ]);
      expect(result.written, 0);
      expect(await repo.countRuns(), 0);
      expect(await repo.latestStart(), isNull);
    });

    test('v1 database gains hr_sample_count', () async {
      final migrated = '${Directory.systemTemp.path}/runs_v1_${DateTime.now().microsecondsSinceEpoch}.db';
      final opened = await openDatabase(
        migrated,
        version: 1,
        onCreate: (database, version) => RunDatabase.createV1(database),
      );
      await opened.close();
      final upgraded = await openDatabase(
        migrated,
        version: RunDatabase.schemaVersion,
        onUpgrade: RunDatabase.onUpgrade,
      );
      final columns = await upgraded.rawQuery('PRAGMA table_info(runs)');
      expect(columns.map((column) => column['name']), contains('hr_sample_count'));
      await upgraded.close();
      await File(migrated).delete();
    });
  });

  group('sync', () {
    late Database db;
    late RunRepository repo;
    late String path;
    late _FakeSource source;
    late _FakeDetails details;

    setUp(() async {
      path = '${Directory.systemTemp.path}/runs_sync_${DateTime.now().microsecondsSinceEpoch}.db';
      db = await openDatabase(
        path,
        version: RunDatabase.schemaVersion,
        onCreate: RunDatabase.onCreate,
        onUpgrade: RunDatabase.onUpgrade,
      );
      repo = RunRepository(db);
      source = _FakeSource();
      details = _FakeDetails();
    });

    tearDown(() async {
      await db.close();
      final file = File(path);
      if (await file.exists()) await file.delete();
    });

    RunSync sync({int maxDetailAttempts = 3, WaitFor? wait}) {
      return RunSync(
        repository: repo,
        source: source,
        details: details,
        maxDetailAttempts: maxDetailAttempts,
        wait: wait ?? (_) async {},
      );
    }

    test('import since a date stores only later runs and their details', () async {
      source.pages = [
        ExercisePage(
          nextPageToken: '1',
          points: [
            _run(id: 'walk', start: DateTime.utc(2024, 2, 1), type: 'WALKING', name: 'Gehen'),
            _run(id: 'old', start: DateTime.utc(2023, 12, 1, 8)),
            _run(id: 'feb', start: DateTime.utc(2024, 2, 2, 8)),
          ],
        ),
        ExercisePage(
          points: [
            _run(id: 'mar', start: DateTime.utc(2024, 3, 3, 9)),
          ],
        ),
      ];

      final progress = await sync().importSince(DateTime(2024, 1, 15));

      expect(progress.done, isTrue);
      expect(await repo.countRuns(), 2);
      final ids = (await repo.listRuns()).map(stableRunId).toList();
      expect(ids, ['mar', 'feb']);
      expect(details.fetched, ['mar', 'feb']);
      expect(await repo.hasDetails('feb'), isTrue);
      expect(await repo.readRunDetail('feb', 'route'), isNotEmpty);
      expect(await repo.readBlob('route|feb'), isNotEmpty);
      expect(await repo.latestStart(), DateTime.utc(2024, 3, 3, 9));
      expect(source.sinces.every((since) => since == DateTime(2024, 1, 15)), isTrue);
    });

    test('a paused import resumes from the saved page token', () async {
      source.pages = [
        ExercisePage(
          nextPageToken: '1',
          points: [_run(id: 'feb', start: DateTime.utc(2024, 2, 2, 8))],
        ),
        ExercisePage(
          points: [_run(id: 'mar', start: DateTime.utc(2024, 3, 3, 9))],
        ),
      ];
      var checks = 0;
      final paused = await sync().importSince(
        DateTime(2024, 1, 15),
        isCancelled: () {
          checks++;
          return checks > 1;
        },
      );
      expect(paused.paused, isTrue);
      expect(source.tokens, [null]);
      expect((await repo.importCursor())!.pageToken, '1');
      expect(await repo.countRuns(), 1);

      final resumed = await sync().importSince(DateTime(2024, 1, 15), isCancelled: () => false);
      expect(resumed.done, isTrue);
      expect(source.tokens, [null, '1']);
      expect(await repo.countRuns(), 2);
      expect(details.fetched, containsAll(['feb', 'mar']));

      source.tokens.clear();
      final repeat = await sync().importSince(DateTime(2024, 1, 15));
      expect(repeat.done, isTrue);
      expect(source.tokens, isEmpty);
    });

    test('rate limits are retried and then the page is stored', () async {
      final waits = <Duration>[];
      source.rateLimitsLeft = 1;
      source.pages = [
        ExercisePage(points: [_run(id: 'feb', start: DateTime.utc(2024, 2, 2, 8))]),
      ];
      final progress = await sync(wait: (duration) async => waits.add(duration)).importSince(DateTime(2024, 2, 1));
      expect(progress.done, isTrue);
      expect(source.tokens, [null, null]);
      expect(waits, [const Duration(seconds: 2)]);
      expect(await repo.countRuns(), 1);
    });

    test('incremental sync uses the watermark and does not duplicate ids', () async {
      final older = DateTime.utc(2024, 5, 1, 8);
      final newer = DateTime.utc(2024, 5, 2, 9);
      await repo.upsertRuns([_run(id: 'old', start: older, name: 'Bisher')]);
      await repo.saveDetails('old', _details());
      source.pages = [
        ExercisePage(
          points: [
            _run(id: 'old', start: older, name: 'Aktualisiert'),
            _run(id: 'new', start: newer),
          ],
        ),
      ];

      await sync().syncIncremental();

      expect(await repo.countRuns(), 2);
      expect(source.sinces.single, older);
      expect(details.fetched, ['new']);
      final stored = await repo.listRuns();
      expect(stored.map(stableRunId), ['new', 'old']);
      expect(stored.last['exercise']['displayName'], 'Aktualisiert');
      expect(await repo.hasDetails('new'), isTrue);

      source.pages = [
        ExercisePage(points: [_run(id: 'new', start: newer)]),
      ];
      source.sinces.clear();
      details.fetched.clear();
      await sync().syncIncremental();
      expect(await repo.countRuns(), 2);
      expect(source.sinces.single, newer);
      expect(details.fetched, isEmpty);
    });

    test('detail failures stay resumable until the attempt limit', () async {
      source.pages = [
        ExercisePage(points: [_run(id: 'feb', start: DateTime.utc(2024, 2, 2, 8))]),
      ];
      details.fail = true;
      final first = await sync(maxDetailAttempts: 1).importSince(DateTime(2024, 2, 1));
      expect(first.done, isFalse);
      expect(first.paused, isTrue);
      expect(await repo.detailAttempts('feb'), 1);
      expect(await repo.hasDetails('feb'), isFalse);

      final second = await sync(maxDetailAttempts: 1).importSince(DateTime(2024, 2, 1));
      expect(second.done, isTrue);
      expect(await repo.hasDetails('feb'), isTrue);
    });
  });
}

Map<String, dynamic> _run({
  required String id,
  required DateTime start,
  String name = 'Lauf',
  String type = 'RUNNING',
  int minutes = 30,
}) {
  final end = start.add(Duration(minutes: minutes));
  return {
    'name': id,
    'exercise': {
      'exerciseType': type,
      'displayName': name,
      'activeDuration': '${minutes * 60}s',
      'interval': {
        'startTime': start.toUtc().toIso8601String(),
        'endTime': end.toUtc().toIso8601String(),
      },
      'metricsSummary': {
        'distanceMillimeters': 10000000,
        'averageHeartRateBeatsPerMinute': 150,
      },
    },
  };
}

Map<String, dynamic> _km(DateTime start, int seconds) {
  final end = start.add(Duration(seconds: seconds));
  return {
    'distance': {
      'millimeters': 1000000,
      'interval': {
        'startTime': start.toUtc().toIso8601String(),
        'endTime': end.toUtc().toIso8601String(),
      },
    },
  };
}

RunDetailPayload _details() {
  final start = DateTime.utc(2024, 5, 1, 8);
  final distance = [_km(start, 300)];
  return RunDetailPayload(
    heartRate: [
      {'time': start.toIso8601String(), 'bpm': 140},
    ],
    distance: distance,
    route: [
      {'lat': 52.5, 'lon': 13.4},
    ],
    splits: computeKmSplits(distance, 1),
  );
}

class _FakeSource implements ExercisePageSource {
  List<ExercisePage> pages = const [];
  final tokens = <String?>[];
  final sinces = <DateTime?>[];
  int rateLimitsLeft = 0;

  @override
  Future<ExercisePage> fetchPage({String? pageToken, DateTime? since}) async {
    tokens.add(pageToken);
    sinces.add(since);
    if (rateLimitsLeft > 0) {
      rateLimitsLeft--;
      throw const RateLimited(retryAfter: Duration(seconds: 2));
    }
    final index = pageToken == null ? 0 : int.parse(pageToken);
    if (index < 0 || index >= pages.length) {
      return const ExercisePage(points: []);
    }
    return pages[index];
  }
}

class _FakeDetails implements RunDetailFetcher {
  final fetched = <String>[];
  bool fail = false;

  @override
  Future<RunDetailPayload> fetch(Map<String, dynamic> run) async {
    fetched.add(stableRunId(run));
    if (fail) throw Exception('details unavailable');
    return _details();
  }
}

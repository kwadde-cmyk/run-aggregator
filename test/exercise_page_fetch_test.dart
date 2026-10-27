import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:run_aggregator/db/run_database.dart';
import 'package:run_aggregator/db/run_repository.dart';
import 'package:run_aggregator/services/data_cache.dart';
import 'package:run_aggregator/services/google_health_auth.dart';
import 'package:run_aggregator/services/google_health_service.dart';
import 'package:run_aggregator/services/google_health_session.dart';
import 'package:run_aggregator/services/rate_limit.dart';
import 'package:run_aggregator/services/run_points.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    DataCache.clear();
    GoogleHealthService.debugStore = null;
    GoogleHealthAuth.debugSetSession(
      GoogleHealthSession(
        store: _MemoryStore(
          const OAuthTokens(
            accessToken: 'token',
            refreshToken: 'refresh',
            accessTokenExpiry: null,
          ),
        ),
        oauth: _NoOAuth(),
        now: () => DateTime.utc(2026, 1, 1),
      ),
    );
  });

  tearDown(() {
    GoogleHealthAuth.debugSetSession(null);
    GoogleHealthService.debugStore = null;
    GoogleHealthService.httpClient = http.Client();
    DataCache.clear();
  });

  test('exercise pages send the since-filter and surface rate limits', () async {
    GoogleHealthService.httpClient = MockClient((request) async {
      expect(request.url.queryParameters['pageSize'], '25');
      expect(request.url.queryParameters['pageToken'], 'cursor');
      expect(
        request.url.queryParameters['filter'],
        'exercise.interval.civil_start_time >= "2024-01-15"',
      );
      return http.Response('slow down', 429, headers: {'retry-after': '4'});
    });

    await expectLater(
      GoogleHealthService.fetchExercisePage(
        pageToken: 'cursor',
        since: DateTime(2024, 1, 15),
      ),
      throwsA(
        predicate((Object error) {
          return error is RateLimited && error.retryAfter == const Duration(seconds: 4);
        }),
      ),
    );
  });

  test('stored heart-rate samples are used without a network call', () async {
    final path = '${Directory.systemTemp.path}/runs_hr_${DateTime.now().microsecondsSinceEpoch}.db';
    final db = await openDatabase(
      path,
      version: RunDatabase.schemaVersion,
      onCreate: RunDatabase.onCreate,
      onUpgrade: RunDatabase.onUpgrade,
    );
    final repo = RunRepository(db);
    final start = DateTime.utc(2024, 6, 1, 8);
    final run = _run('run-a', start);
    await repo.upsertRuns([run]);
    final startIso = exerciseStartIso(run)!;
    final endIso = exerciseEndIso(run)!;
    await repo.saveBlob(
      'hr|$startIso|$endIso',
      'heart_rate',
      [
        {'time': startIso, 'bpm': 141},
      ],
      source: 'google_health',
    );
    GoogleHealthService.debugStore = repo;
    GoogleHealthService.httpClient = MockClient((request) async {
      fail('heart rate should come from the database');
    });

    final points = await GoogleHealthService.getHeartRatePoints(
      startTime: startIso,
      endTime: endIso,
    );
    expect(points.single['bpm'], 141);

    await db.close();
    await File(path).delete();
  });

  test('a fetched heart-rate series is written into the database', () async {
    final path = '${Directory.systemTemp.path}/runs_hr_write_${DateTime.now().microsecondsSinceEpoch}.db';
    final db = await openDatabase(
      path,
      version: RunDatabase.schemaVersion,
      onCreate: RunDatabase.onCreate,
      onUpgrade: RunDatabase.onUpgrade,
    );
    final repo = RunRepository(db);
    final start = DateTime.utc(2024, 6, 2, 8);
    final run = _run('run-b', start);
    await repo.upsertRuns([run]);
    GoogleHealthService.debugStore = repo;
    final startIso = exerciseStartIso(run)!;
    final endIso = exerciseEndIso(run)!;
    GoogleHealthService.httpClient = MockClient((request) async {
      return http.Response(
        jsonEncode({
          'dataPoints': [
            {
              'heartRate': {
                'sampleTime': {'physicalTime': startIso},
                'beatsPerMinute': 133,
              },
            },
          ],
        }),
        200,
      );
    });

    final points = await GoogleHealthService.getHeartRatePoints(
      startTime: startIso,
      endTime: endIso,
      forceRefresh: true,
    );
    expect(points.single['bpm'], 133);
    final stored = await repo.readBlob('hr|$startIso|$endIso');
    expect(stored, isNotNull);
    expect(stored!.single['bpm'], 133);
    expect(await repo.heartRateSamples('run-b'), isNotEmpty);

    await db.close();
    await File(path).delete();
  });
}

Map<String, dynamic> _run(String id, DateTime start) {
  final end = start.add(const Duration(minutes: 30));
  return {
    'name': id,
    'exercise': {
      'exerciseType': 'RUNNING',
      'displayName': 'Lauf',
      'interval': {
        'startTime': start.toUtc().toIso8601String(),
        'endTime': end.toUtc().toIso8601String(),
      },
    },
  };
}

class _MemoryStore implements GoogleTokenStore {
  _MemoryStore(this.tokens);

  OAuthTokens tokens;

  @override
  Future<void> clear() async => tokens = OAuthTokens.empty;

  @override
  Future<OAuthTokens> read() async => tokens;

  @override
  Future<void> write(OAuthTokens value) async => tokens = value;
}

class _NoOAuth implements GoogleOAuthApi {
  @override
  Future<OAuthTokens?> authorizeInteractive() async => null;

  @override
  Future<OAuthTokens> refresh(String refreshToken) {
    throw StateError('refresh was not expected');
  }
}

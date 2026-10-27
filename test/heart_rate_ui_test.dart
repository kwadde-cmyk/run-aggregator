import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_aggregator/screens/compare_screen.dart';
import 'package:run_aggregator/screens/exercise_detail_screen.dart';
import 'package:run_aggregator/services/data_cache.dart';
import 'package:run_aggregator/services/heart_rate_series.dart';
import 'package:run_aggregator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DataCache.clear();
  });

  testWidgets('comparison graph draws the chest-strap curve', (tester) async {
    final runs = [
      _run(id: 'run-a', name: 'Parkrunde', bpm: 160),
      _run(
        id: 'run-b',
        name: 'Langer Sonntag',
        bpm: 175,
        start: DateTime.utc(2026, 10, 18, 9, 5),
      ),
    ];
    for (final run in runs) {
      _seed(run, strapBpm: (run['strapBpm'] as num).toDouble(), strapCount: 12);
    }

    await _pump(tester, CompareScreen(exercises: runs));
    await _settle(tester);

    expect(find.text('HF-Verlauf'), findsOneWidget);
    expect(find.text('Brustgurt: 12.10., 18.10.'), findsOneWidget);

    final hrSpots = _heartRateSpots(tester);
    expect(hrSpots, isNotEmpty);
    expect(hrSpots.map((spot) => spot.y).toSet(), {160, 175});
    expect(hrSpots.every((spot) => spot.y == 160 || spot.y == 175), isTrue);
  });

  testWidgets('comparison graph falls back when the strap recording is missing', (tester) async {
    final run = _run(id: 'run-a', name: 'Parkrunde', bpm: 110);
    _seed(
      run,
      strapBpm: 180,
      strapCount: 3,
      googleBpm: 110,
    );

    await _pump(tester, CompareScreen(exercises: [run]));
    await _settle(tester);

    expect(find.textContaining('Brustgurt'), findsNothing);
    final hrSpots = _heartRateSpots(tester);
    expect(hrSpots, isNotEmpty);
    expect(hrSpots.every((spot) => spot.y == 110), isTrue);
  });

  testWidgets('comparison graph stays empty without heart-rate samples', (tester) async {
    final run = _run(id: 'run-a', name: 'Parkrunde', bpm: 0);
    _seed(run, strapCount: 0, googleCount: 0);

    await _pump(tester, CompareScreen(exercises: [run]));
    await _settle(tester);

    expect(find.text('HF-Verlauf'), findsOneWidget);
    expect(find.text('Pace-Verlauf'), findsOneWidget);
    expect(find.text('Keine Daten'), findsOneWidget);
    expect(_heartRateSpots(tester), isEmpty);
  });

  testWidgets('splits show the chest-strap average and a dash without samples', (tester) async {
    final run = _run(id: 'run-a', name: 'Parkrunde', bpm: 148);
    _seed(run, strapBpm: 160, strapCount: 12, googleBpm: 100);

    await _pump(tester, ExerciseDetailScreen(exercisePoint: run));
    await _settle(tester);

    expect(find.textContaining('Runkeeper (Brustgurt)'), findsWidgets);
    expect(find.text('Durchschnitts-HF'), findsNWidgets(2));
    expect(find.text('160 bpm'), findsOneWidget);
    expect(find.text(missingAverageHeartRate), findsOneWidget);
    expect(find.textContaining('100'), findsNothing);
  });

  testWidgets('splits use Google Health when the strap series is too short', (tester) async {
    final run = _run(id: 'run-a', name: 'Parkrunde', bpm: 99);
    _seed(run, strapBpm: 180, strapCount: 4, googleBpm: 110, googleInBothSplits: true);

    await _pump(tester, ExerciseDetailScreen(exercisePoint: run));
    await _settle(tester);

    expect(find.textContaining('Google Health'), findsWidgets);
    expect(find.text('Durchschnitts-HF'), findsNWidgets(2));
    expect(find.text('110 bpm'), findsNWidgets(2));
    expect(find.textContaining('180'), findsNothing);
    expect(find.text(missingAverageHeartRate), findsNothing);
  });

  testWidgets('a short strap recording still fills the split when Google is empty', (tester) async {
    final run = _run(id: 'run-a', name: 'Parkrunde', bpm: 140);
    _seed(run, strapBpm: 151, strapCount: 4, googleCount: 0);

    await _pump(tester, ExerciseDetailScreen(exercisePoint: run));
    await _settle(tester);

    expect(find.textContaining('Runkeeper (Brustgurt)'), findsWidgets);
    expect(find.text('151 bpm'), findsOneWidget);
    expect(find.text(missingAverageHeartRate), findsOneWidget);
  });
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 5000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: home,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(seconds: 1));
}

List<FlSpot> _heartRateSpots(WidgetTester tester) {
  final spots = <FlSpot>[];
  for (final chart in tester.widgetList<LineChart>(find.byType(LineChart))) {
    for (final bar in chart.data.lineBarsData) {
      if (bar.spots.any((spot) => spot.y >= 40)) {
        spots.addAll(bar.spots);
      }
    }
  }
  return spots;
}

Map<String, dynamic> _run({
  required String id,
  required String name,
  required double bpm,
  DateTime? start,
}) {
  start ??= DateTime.utc(2026, 10, 12, 7, 30);
  final end = start.add(const Duration(minutes: 2));
  return {
    'name': id,
    'strapBpm': bpm,
    'exercise': {
      'exerciseType': 'RUNNING',
      'displayName': name,
      'activeDuration': '120s',
      'interval': {
        'startTime': start.toIso8601String(),
        'endTime': end.toIso8601String(),
      },
      'metricsSummary': {
        'distanceMillimeters': 2000000,
        'averageHeartRateBeatsPerMinute': bpm,
        'averagePaceSecondsPerMeter': 0.06,
        'caloriesKcal': 120,
      },
    },
  };
}

void _seed(
  Map<String, dynamic> run, {
  double strapBpm = 160,
  int strapCount = 12,
  double googleBpm = 100,
  int googleCount = 2,
  bool googleInBothSplits = false,
}) {
  final exercise = run['exercise'] as Map<String, dynamic>;
  final interval = exercise['interval'] as Map<String, dynamic>;
  final startStr = interval['startTime'] as String;
  final endStr = interval['endTime'] as String;
  final start = DateTime.parse(startStr);

  DataCache.set('distance|$startStr|$endStr', [
    {
      'distance': {
        'millimeters': 1000000,
        'interval': {
          'startTime': start.toIso8601String(),
          'endTime': start.add(const Duration(minutes: 1)).toIso8601String(),
        },
      },
    },
    {
      'distance': {
        'millimeters': 1000000,
        'interval': {
          'startTime': start.add(const Duration(minutes: 1)).toIso8601String(),
          'endTime': start.add(const Duration(minutes: 2)).toIso8601String(),
        },
      },
    },
  ]);
  DataCache.set('route|${run['name']}', [
    {'lat': 52.52, 'lon': 13.40},
    {'lat': 52.53, 'lon': 13.41},
  ]);
  DataCache.set<double>('weather|${run['name']}|$startStr', 8);

  DataCache.set(
    'runkeeper_hr|$startStr|$endStr',
    [
      for (var i = 0; i < strapCount; i++)
        {
          'time': start.add(Duration(seconds: 1 + i)),
          'hr': strapBpm,
        },
    ],
  );

  final google = <Map<String, dynamic>>[];
  if (googleCount > 0) {
    google.add({
      'time': start.add(const Duration(seconds: 30)).toIso8601String(),
      'bpm': googleBpm,
    });
  }
  if (googleCount > 1 || googleInBothSplits) {
    google.add({
      'time': start.add(const Duration(seconds: 90)).toIso8601String(),
      'bpm': googleBpm,
    });
  }
  DataCache.set('hr|$startStr|$endStr', google);
}

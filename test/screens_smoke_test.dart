import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:run_aggregator/screens/compare_screen.dart';
import 'package:run_aggregator/screens/exercise_detail_screen.dart';
import 'package:run_aggregator/screens/home_screen.dart';
import 'package:run_aggregator/screens/login_screen.dart';
import 'package:run_aggregator/services/data_cache.dart';
import 'package:run_aggregator/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final shotDir = Platform.environment['SCREENSHOT_DIR'];

  setUpAll(() async {
    if (shotDir == null) return;
    const dir = '/tmp/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    Future<void> load(String family, List<String> files) async {
      final loader = FontLoader(family);
      for (final name in files) {
        final bytes = await File('$dir/$name').readAsBytes();
        loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      }
      await loader.load();
    }

    await load('Roboto', const [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf',
      'Roboto-Light.ttf',
    ]);
    await load('MaterialIcons', const ['MaterialIcons-Regular.otf']);
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    DataCache.clear();
  });

  Future<void> shoot(WidgetTester tester, String name) async {
    if (shotDir == null) return;
    await tester.pump();
    final boundary = tester.renderObject(find.byKey(const Key('shot'))) as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final png = bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
      await File('$shotDir/$name.png').writeAsBytes(png, flush: true);
      image.dispose();
    });
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(390, 844),
    ThemeMode mode = ThemeMode.dark,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('shot'),
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: home,
        ),
      ),
    );
  }

  Future<void> settleHome(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 5));
  }

  testWidgets('login shows the Google Health action', (tester) async {
    await pumpScreen(tester, const LoginScreen());
    await tester.pump();
    expect(find.text('Run Aggregator'), findsOneWidget);
    expect(find.text('Mit Google Health anmelden'), findsOneWidget);
    expect(find.text('Runkeeper-Login kommt als Nächstes.'), findsOneWidget);
    await shoot(tester, 'after_login_dark');
  });

  testWidgets('login light theme', (tester) async {
    await pumpScreen(tester, const LoginScreen(), mode: ThemeMode.light);
    await tester.pump();
    expect(find.text('Mit Google Health anmelden'), findsOneWidget);
    final context = tester.element(find.text('Run Aggregator'));
    expect(Theme.of(context).brightness, Brightness.light);
    await shoot(tester, 'after_login_light');
  });

  testWidgets('home lists runs with prominent stats', (tester) async {
    _seedHome();
    await pumpScreen(tester, const HomeScreen());
    await settleHome(tester);
    expect(find.textContaining('Parkrunde'), findsOneWidget);
    expect(find.textContaining('Langer Sonntag'), findsOneWidget);
    expect(find.textContaining('10.02'), findsWidgets);
    expect(find.text('Läufe'), findsWidgets);
    expect(find.text('Filter'), findsWidgets);
    expect(find.text('Mehr'), findsWidgets);
    await shoot(tester, 'after_home_dark');

    await tester.tap(find.text('Filter').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Anwenden'), findsOneWidget);
    expect(find.text('Wochentag'), findsOneWidget);
    await shoot(tester, 'after_filter_dark');

    await tester.tap(find.text('Mehr').first);
    await tester.pump();
    expect(find.text('Darstellung'), findsOneWidget);
    expect(find.text('Abmelden'), findsOneWidget);
    await shoot(tester, 'after_more_dark');
  });

  testWidgets('home light theme and wide rail', (tester) async {
    _seedHome();
    await pumpScreen(tester, const HomeScreen(), mode: ThemeMode.light);
    await settleHome(tester);
    expect(find.textContaining('Parkrunde'), findsOneWidget);
    await shoot(tester, 'after_home_light');

    await pumpScreen(tester, const HomeScreen(), size: const Size(1200, 800));
    await settleHome(tester);
    expect(find.byType(NavigationRail), findsOneWidget);
    await shoot(tester, 'after_home_wide');
  });

  testWidgets('empty and error states', (tester) async {
    DataCache.set<List<Map<String, dynamic>>>('exercises', []);
    await pumpScreen(tester, const HomeScreen());
    await settleHome(tester);
    expect(find.text('Keine Läufe gefunden'), findsOneWidget);
    await shoot(tester, 'after_home_empty');

    DataCache.clear();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpScreen(tester, const HomeScreen());
    await settleHome(tester);
    expect(find.text('Etwas ist schiefgelaufen'), findsOneWidget);
    expect(find.text('Nochmal versuchen'), findsOneWidget);
    await shoot(tester, 'after_home_error');
  });

  testWidgets('detail shows stats, route and splits', (tester) async {
    final run = _runs().first;
    _seedDetail(run);
    await pumpScreen(tester, ExerciseDetailScreen(exercisePoint: run));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Parkrunde'), findsWidgets);
    expect(find.text('Distanz'), findsWidgets);
    expect(find.text('Route'), findsOneWidget);
    expect(find.textContaining('10.02'), findsWidgets);
    await shoot(tester, 'after_detail_dark');
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shoot(tester, 'after_detail_scrolled');
  });

  testWidgets('compare shows both runs', (tester) async {
    final runs = _runs();
    for (final run in runs) {
      _seedDetail(run);
    }
    await pumpScreen(tester, CompareScreen(exercises: runs));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Vergleich (2)'), findsOneWidget);
    expect(find.textContaining('Parkrunde'), findsOneWidget);
    expect(find.text('Pace-Verlauf'), findsOneWidget);
    await shoot(tester, 'after_compare_dark');
    await tester.drag(find.byType(ListView), const Offset(0, -780));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await shoot(tester, 'after_compare_scrolled');
  });
}

List<Map<String, dynamic>> _runs() {
  return [
    _run(
      id: 'run-park',
      name: 'Parkrunde',
      start: DateTime.utc(2026, 10, 12, 7, 30),
      minutes: 52,
      km: 10.02,
      hr: 148,
      paceMinPerKm: 5.2,
      kcal: 640,
      temp: 8,
    ),
    _run(
      id: 'run-long',
      name: 'Langer Sonntag',
      start: DateTime.utc(2026, 10, 18, 9, 5),
      minutes: 95,
      km: 18.40,
      hr: 141,
      paceMinPerKm: 5.15,
      kcal: 1120,
      temp: 14,
    ),
  ];
}

void _seedHome() {
  final runs = _runs();
  DataCache.set<List<Map<String, dynamic>>>('exercises', runs);
  for (final run in runs) {
    final exercise = run['exercise'] as Map<String, dynamic>;
    final interval = exercise['interval'] as Map<String, dynamic>;
    DataCache.set<double>('weather|${run['name']}|${interval['startTime']}', run['temp'] as double);
  }
}

void _seedDetail(Map<String, dynamic> run) {
  final exercise = run['exercise'] as Map<String, dynamic>;
  final interval = exercise['interval'] as Map<String, dynamic>;
  final startStr = interval['startTime'] as String;
  final endStr = interval['endTime'] as String;
  final start = DateTime.parse(startStr);
  final end = DateTime.parse(endStr);
  final minutes = end.difference(start).inMinutes;
  final km = ((exercise['metricsSummary'] as Map)['distanceMillimeters'] as num) / 1000000.0;

  DataCache.set('distance|$startStr|$endStr', _distancePoints(start, minutes, km));
  DataCache.set('hr|$startStr|$endStr', _hrPoints(start, minutes));
  DataCache.set('route|${run['name']}', _route());
  DataCache.set(
    'runkeeper_hr|${start.toIso8601String()}|${end.toIso8601String()}',
    List.generate(minutes, (i) => {'time': start.add(Duration(minutes: i)), 'hr': 140 + (i % 6)}),
  );
  DataCache.set<double>('weather|${run['name']}|$startStr', (run['temp'] as num).toDouble());
}

Map<String, dynamic> _run({
  required String id,
  required String name,
  required DateTime start,
  required int minutes,
  required double km,
  required double hr,
  required double paceMinPerKm,
  required double kcal,
  required double temp,
}) {
  final end = start.add(Duration(minutes: minutes));
  return {
    'name': id,
    'temp': temp,
    'exercise': {
      'exerciseType': 'RUNNING',
      'displayName': name,
      'activeDuration': '${minutes * 60}s',
      'interval': {
        'startTime': start.toIso8601String(),
        'endTime': end.toIso8601String(),
      },
      'metricsSummary': {
        'distanceMillimeters': km * 1000000,
        'averageHeartRateBeatsPerMinute': hr,
        'averagePaceSecondsPerMeter': paceMinPerKm * 60 / 1000,
        'caloriesKcal': kcal,
      },
    },
  };
}

List<Map<String, dynamic>> _distancePoints(DateTime start, int minutes, double km) {
  final kmPer = km / minutes;
  return List.generate(minutes, (i) {
    final factor = 0.82 + 0.36 * ((i % 5) / 4);
    final a = start.add(Duration(minutes: i));
    final b = start.add(Duration(minutes: i + 1));
    return {
      'distance': {
        'millimeters': kmPer * factor * 1000000,
        'interval': {
          'startTime': a.toIso8601String(),
          'endTime': b.toIso8601String(),
        },
      },
    };
  });
}

List<Map<String, dynamic>> _hrPoints(DateTime start, int minutes) {
  return List.generate(minutes, (i) {
    return {
      'time': start.add(Duration(minutes: i)).toIso8601String(),
      'bpm': 132 + (i % 8) * 3,
    };
  });
}

List<Map<String, dynamic>> _route() {
  const lat0 = 52.520;
  const lon0 = 13.405;
  return List.generate(24, (i) {
    final t = i / 23;
    return {
      'lat': lat0 + 0.012 * t,
      'lon': lon0 + 0.008 * (t < 0.5 ? t : 1 - t),
    };
  });
}

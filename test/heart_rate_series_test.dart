import 'package:flutter_test/flutter_test.dart';
import 'package:run_aggregator/services/data_cache.dart';
import 'package:run_aggregator/services/heart_rate_series.dart';
import 'package:run_aggregator/services/runkeeper_service.dart';

void main() {
  final start = DateTime.utc(2026, 10, 12, 7, 30);
  final end = start.add(const Duration(minutes: 30));

  HeartRateSample at(Duration offset, double bpm) =>
      HeartRateSample(time: start.add(offset), bpm: bpm);

  setUp(DataCache.clear);

  test('GPX chest-strap samples keep namespaced and decimal heart rates', () {
    const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx xmlns="http://www.topografix.com/GPX/1/1"
     xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
     version="1.1" creator="Runkeeper">
  <trk><trkseg>
    <trkpt lat="52.52" lon="13.40">
      <time>2026-10-12T07:30:05Z</time>
      <extensions>
        <gpxtpx:TrackPointExtension>
          <gpxtpx:hr>148</gpxtpx:hr>
        </gpxtpx:TrackPointExtension>
      </extensions>
    </trkpt>
    <trkpt lat="52.52" lon="13.41">
      <time>2026-10-12T07:30:06Z</time>
      <extensions>
        <gpxtpx:TrackPointExtension>
          <gpxtpx:hr>149.5</gpxtpx:hr>
        </gpxtpx:TrackPointExtension>
      </extensions>
    </trkpt>
    <trkpt lat="52.52" lon="13.42">
      <ele>40</ele>
    </trkpt>
  </trkseg></trk>
</gpx>
''';

    final samples = heartRateSamplesFromGpxXml(xml);
    expect(samples, hasLength(2));
    expect(samples[0]['hr'], 148);
    expect(samples[1]['hr'], 149.5);
    expect((samples[0]['time'] as DateTime).toUtc(), DateTime.utc(2026, 10, 12, 7, 30, 5));
  });

  test('parser accepts strap hr and Google bpm values', () {
    final fromStrap = tryParseHeartRateSample({
      'time': start,
      'hr': 72,
    });
    final fromGoogle = tryParseHeartRateSample({
      'time': '2026-10-12T07:31:00.000Z',
      'bpm': '155.5',
    });

    expect(fromStrap!.bpm, 72);
    expect(fromStrap.time.isUtc, isTrue);
    expect(fromGoogle!.bpm, 155.5);
    expect(fromGoogle.time, DateTime.utc(2026, 10, 12, 7, 31));
    expect(tryParseHeartRateSample({'time': 'nope', 'hr': 140}), isNull);
  });

  test('chest-strap series wins when the activity window has enough samples', () {
    final strap = [
      for (var i = 0; i < 12; i++) at(Duration(seconds: 10 + i), 168),
    ];
    final google = [at(const Duration(minutes: 2), 100)];

    final chosen = chooseHeartRateSeries(
      chestStrap: strap,
      googleHealth: google,
      start: start,
      end: end,
    );

    expect(chosen.source, HeartRateSources.chestStrap);
    expect(chosen.samples, hasLength(12));
    expect(chosen.samples.every((sample) => sample.bpm == 168), isTrue);
  });

  test('samples outside the activity do not count as the chest-strap curve', () {
    final strap = [
      for (var i = 0; i < 12; i++)
        HeartRateSample(
          time: start.subtract(const Duration(hours: 2)),
          bpm: 170,
        ),
      at(const Duration(minutes: 1), 170),
    ];
    final google = [at(const Duration(minutes: 2), 120)];

    final chosen = chooseHeartRateSeries(
      chestStrap: strap,
      googleHealth: google,
      start: start,
      end: end,
    );

    expect(chosen.source, HeartRateSources.googleHealth);
    expect(chosen.samples.single.bpm, 120);

    final curve = heartRateCurve(chosen.samples, start);
    expect(curve.single.minutes, 2);
    expect(curve.single.bpm, 120);
  });

  test('short chest-strap recording falls back to Google Health', () {
    final chosen = chooseHeartRateSeries(
      chestStrap: [at(const Duration(minutes: 1), 180)],
      googleHealth: [
        at(const Duration(minutes: 1), 110),
        at(const Duration(minutes: 3), 114),
      ],
      start: start,
      end: end,
    );

    expect(chosen.source, HeartRateSources.googleHealth);
    expect(chosen.samples.map((sample) => sample.bpm), [110, 114]);
  });

  test('short chest-strap recording is kept when Google Health is empty', () {
    final chosen = chooseHeartRateSeries(
      chestStrap: [
        at(const Duration(seconds: 20), 151),
        at(const Duration(seconds: 40), 153),
      ],
      googleHealth: const [],
      start: start,
      end: end,
    );

    expect(chosen.source, HeartRateSources.chestStrap);
    expect(chosen.samples.map((sample) => sample.bpm), [151, 153]);
  });

  test('implausible heart rates are dropped and never averaged as zero', () {
    final avg = averageHeartRateForSplit(
      samples: [
        at(const Duration(seconds: 10), 0),
        at(const Duration(seconds: 20), 30),
        at(const Duration(seconds: 30), 250),
      ],
      start: start,
      end: end,
    );

    expect(avg, isNull);
    expect(formatAverageHeartRate(avg), missingAverageHeartRate);
    expect(formatAverageHeartRate(avg), isNot('0'));
    expect(
      averageHeartRateForSplit(samples: const [], start: start, end: end),
      isNull,
    );
  });

  test('split average uses only samples inside that split', () {
    final split1End = start.add(const Duration(minutes: 5));
    final split2End = start.add(const Duration(minutes: 10));
    final samples = [
      at(const Duration(seconds: -1), 200),
      at(const Duration(seconds: 30), 150),
      at(const Duration(minutes: 2), 160),
      at(const Duration(minutes: 4), 170),
      at(const Duration(minutes: 5), 180),
      at(const Duration(minutes: 7), 140),
      at(const Duration(minutes: 10, seconds: 1), 200),
    ];

    final first = averageHeartRateForSplit(
      samples: samples,
      start: start,
      end: split1End,
    );
    final second = averageHeartRateForSplit(
      samples: samples,
      start: split1End,
      end: split2End,
    );
    final empty = averageHeartRateForSplit(
      samples: samples,
      start: split2End.add(const Duration(seconds: 2)),
      end: split2End.add(const Duration(minutes: 5)),
    );

    expect(first, closeTo(165, 0.001));
    expect(formatAverageHeartRate(first), '165');
    expect(second, closeTo(160, 0.001));
    expect(formatAverageHeartRate(second), '160');
    expect(empty, isNull);
    expect(formatAverageHeartRate(empty), missingAverageHeartRate);

    final rounded = averageHeartRateForSplit(
      samples: [
        at(const Duration(seconds: 1), 155),
        at(const Duration(seconds: 2), 156),
      ],
      start: start,
      end: split1End,
    );
    expect(rounded, closeTo(155.5, 0.001));
    expect(formatAverageHeartRate(rounded), '156');
  });

  test('curve minutes are aligned to the activity start', () {
    final points = heartRateCurve(
      [
        at(const Duration(seconds: 90), 150),
        at(const Duration(seconds: -5), 150),
        at(const Duration(seconds: 30), 40),
      ],
      start,
    );

    expect(points.map((point) => point.minutes), [0.5, 1.5]);
    expect(points.map((point) => point.bpm), [40, 150]);
  });

  test('loader reads cached chest-strap samples and ignores Google Health', () async {
    final startStr = start.toIso8601String();
    final endStr = end.toIso8601String();
    DataCache.set('runkeeper_hr|$startStr|$endStr', [
      for (var i = 0; i < 12; i++)
        {'time': start.add(Duration(seconds: 5 + i)), 'hr': 168},
    ]);
    DataCache.set('hr|$startStr|$endStr', [
      {'time': start.add(const Duration(minutes: 1)).toIso8601String(), 'bpm': 100},
    ]);

    final series = await loadActivityHeartRate(startTime: startStr, endTime: endStr);

    expect(series.source, HeartRateSources.chestStrap);
    expect(series.samples, hasLength(12));
    expect(series.samples.every((sample) => sample.bpm == 168), isTrue);
  });

  test('loader falls back to cached Google Health samples', () async {
    final startStr = start.toIso8601String();
    final endStr = end.toIso8601String();
    DataCache.set('runkeeper_hr|$startStr|$endStr', <Map<String, dynamic>>[]);
    DataCache.set('hr|$startStr|$endStr', [
      {'time': start.add(const Duration(minutes: 4)).toIso8601String(), 'bpm': 126},
    ]);

    final series = await loadActivityHeartRate(startTime: startStr, endTime: endStr);

    expect(series.source, HeartRateSources.googleHealth);
    expect(series.samples.single.bpm, 126);
  });
}

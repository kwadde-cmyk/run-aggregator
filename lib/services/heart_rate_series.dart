import 'google_health_service.dart';
import 'runkeeper_service.dart';

/// Labels stored with a resolved heart-rate series.
class HeartRateSources {
  static const chestStrap = 'Runkeeper (Brustgurt)';
  static const googleHealth = 'Google Health';

  /// A chest-strap recording of a real run has far more than a handful of
  /// samples. Fewer than this and we keep the Google Health series, which is
  /// usually the wrist optical stream, instead of replacing it with noise.
  static const minimumChestStrapSamples = 10;
}

/// Shown when a split has no heart-rate samples. Never "0".
const missingAverageHeartRate = '–';

/// One heart-rate sample, normalized to UTC.
class HeartRateSample {
  const HeartRateSample({required this.time, required this.bpm});

  final DateTime time;
  final double bpm;
}

/// The series the charts and split table should draw for one activity.
class HeartRateSeries {
  const HeartRateSeries({required this.samples, this.source = ''});

  final List<HeartRateSample> samples;
  final String source;

  static const empty = HeartRateSeries(samples: []);
}

class HeartRateCurvePoint {
  const HeartRateCurvePoint({required this.minutes, required this.bpm});

  /// Minutes after the activity start. This is the comparison graph's x axis.
  final double minutes;
  final double bpm;
}

/// Wrist and strap samples outside a running range are noise, not a curve.
bool isPlausibleHeartRate(double bpm) => bpm >= 40 && bpm <= 220;

HeartRateSample? tryParseHeartRateSample(Map<String, dynamic> raw) {
  final time = _parseTime(raw['time']);
  final bpm = _parseBpm(raw['bpm'] ?? raw['hr']);
  if (time == null || bpm == null) return null;
  return HeartRateSample(time: time.toUtc(), bpm: bpm);
}

/// Samples whose timestamp falls inside [start, end], inclusive, with a
/// plausible heart rate. Sorted by time so a curve does not jump backwards.
List<HeartRateSample> heartRateSamplesInRange(
  Iterable<HeartRateSample> samples,
  DateTime start,
  DateTime end,
) {
  final inRange = samples.where((sample) {
    if (!isPlausibleHeartRate(sample.bpm)) return false;
    return !sample.time.isBefore(start) && !sample.time.isAfter(end);
  }).toList()
    ..sort((a, b) => a.time.compareTo(b.time));
  return inRange;
}

/// Prefer the chest-strap series when the activity window actually contains
/// one. Otherwise use Google Health. A short strap recording is still used
/// when Google Health has nothing, so a curve is shown whenever any samples
/// exist.
HeartRateSeries chooseHeartRateSeries({
  required Iterable<HeartRateSample> chestStrap,
  required Iterable<HeartRateSample> googleHealth,
  required DateTime start,
  required DateTime end,
}) {
  final strap = heartRateSamplesInRange(chestStrap, start, end);
  if (strap.length >= HeartRateSources.minimumChestStrapSamples) {
    return HeartRateSeries(samples: strap, source: HeartRateSources.chestStrap);
  }

  final google = heartRateSamplesInRange(googleHealth, start, end);
  if (google.isNotEmpty) {
    return HeartRateSeries(
      samples: google,
      source: HeartRateSources.googleHealth,
    );
  }
  if (strap.isNotEmpty) {
    return HeartRateSeries(samples: strap, source: HeartRateSources.chestStrap);
  }
  return const HeartRateSeries(samples: [], source: HeartRateSources.googleHealth);
}

/// Arithmetic mean of the plausible samples inside [start, end].
/// Null when the split has no samples — callers must not substitute 0.
double? averageHeartRateForSplit({
  required Iterable<HeartRateSample> samples,
  required DateTime start,
  required DateTime end,
}) {
  if (end.isBefore(start)) return null;
  final inRange = heartRateSamplesInRange(samples, start, end);
  if (inRange.isEmpty) return null;
  var sum = 0.0;
  for (final sample in inRange) {
    sum += sample.bpm;
  }
  return sum / inRange.length;
}

String formatAverageHeartRate(double? bpm) {
  if (bpm == null || bpm.isNaN || bpm.isInfinite) return missingAverageHeartRate;
  return bpm.round().toString();
}

/// Comparison-graph points. X is minutes from [activityStart], same axis as pace.
List<HeartRateCurvePoint> heartRateCurve(
  Iterable<HeartRateSample> samples,
  DateTime activityStart,
) {
  final points = <HeartRateCurvePoint>[];
  for (final sample in samples) {
    if (!isPlausibleHeartRate(sample.bpm)) continue;
    final minutes = sample.time.difference(activityStart).inSeconds / 60.0;
    if (minutes < 0) continue;
    points.add(HeartRateCurvePoint(minutes: minutes, bpm: sample.bpm));
  }
  points.sort((a, b) => a.minutes.compareTo(b.minutes));
  return points;
}

/// Chest-strap samples recorded in a Runkeeper GPX, otherwise the Google
/// Health heart-rate stream for the same activity interval.
Future<HeartRateSeries> loadActivityHeartRate({
  required String startTime,
  required String endTime,
}) async {
  final start = DateTime.tryParse(startTime);
  final end = DateTime.tryParse(endTime);
  if (start == null || end == null || end.isBefore(start)) {
    return HeartRateSeries.empty;
  }

  final strap = await _loadChestStrapSamples(start, end);
  final strapInWindow = heartRateSamplesInRange(strap, start, end);
  if (strapInWindow.length >= HeartRateSources.minimumChestStrapSamples) {
    return HeartRateSeries(
      samples: strapInWindow,
      source: HeartRateSources.chestStrap,
    );
  }

  Object? googleError;
  var google = const <HeartRateSample>[];
  try {
    google = await _loadGoogleHealthSamples(startTime, endTime);
  } catch (error) {
    googleError = error;
  }

  final chosen = chooseHeartRateSeries(
    chestStrap: strapInWindow,
    googleHealth: google,
    start: start,
    end: end,
  );
  if (chosen.samples.isEmpty && googleError != null) {
    throw googleError;
  }
  return chosen;
}

Future<List<HeartRateSample>> _loadChestStrapSamples(
  DateTime start,
  DateTime end,
) async {
  try {
    final raw = await RunkeeperService.loadHeartRateSamples(
      windowStart: start,
      windowEnd: end,
    );
    return raw.map(tryParseHeartRateSample).whereType<HeartRateSample>().toList();
  } catch (_) {
    return const [];
  }
}

Future<List<HeartRateSample>> _loadGoogleHealthSamples(
  String startTime,
  String endTime,
) async {
  final raw = await GoogleHealthService.getHeartRatePoints(
    startTime: startTime,
    endTime: endTime,
  );
  return raw.map(tryParseHeartRateSample).whereType<HeartRateSample>().toList();
}

DateTime? _parseTime(dynamic raw) {
  if (raw is DateTime) return raw;
  if (raw is String) return DateTime.tryParse(raw);
  return null;
}

double? _parseBpm(dynamic raw) {
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

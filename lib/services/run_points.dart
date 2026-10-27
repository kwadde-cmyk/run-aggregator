// Helpers for the Google Health exercise maps the UI already uses.

bool isRunningExercise(Map<String, dynamic> item) {
  final exercise = item['exercise'];
  final map = exercise is Map ? exercise : const <String, dynamic>{};
  final type = (map['exerciseType'] ?? '').toString().toUpperCase();
  final name = (map['displayName'] ?? '').toString().toLowerCase();
  return type == 'RUNNING' || name.contains('laufen') || name.contains('running');
}

/// Stable identity for dedupe. Google Health resource names do not change
/// when a run is fetched again.
String stableRunId(Map<String, dynamic> item) {
  final name = item['name']?.toString();
  if (name != null && name.isNotEmpty) return name;
  final alt = item['dataPointName']?.toString();
  if (alt != null && alt.isNotEmpty) return alt;
  final start = exerciseStartIso(item) ?? '';
  final source = item['source']?.toString();
  final prefix = (source == null || source.isEmpty) ? 'google_health' : source;
  return '$prefix|$start';
}

String? exerciseStartIso(Map<String, dynamic> item) => _intervalField(item, 'startTime');

String? exerciseEndIso(Map<String, dynamic> item) => _intervalField(item, 'endTime');

DateTime? exerciseStart(Map<String, dynamic> item) {
  final raw = exerciseStartIso(item);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

DateTime? exerciseEnd(Map<String, dynamic> item) {
  final raw = exerciseEndIso(item);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
}

String? _intervalField(Map<String, dynamic> item, String field) {
  final exercise = item['exercise'];
  if (exercise is! Map) return null;
  final interval = exercise['interval'];
  if (interval is! Map) return null;
  final value = interval[field];
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

/// Calendar day of [since] in local time, inclusive.
bool isOnOrAfterDay(DateTime start, DateTime since) {
  final local = start.toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final cut = DateTime(since.year, since.month, since.day);
  return !day.isBefore(cut);
}

bool sameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Civil-time literal for `exercise.interval.civil_start_time`.
///
/// Midnight stays a date (`YYYY-MM-DD`) so the whole local day is included.
/// Any other clock time keeps `YYYY-MM-DDTHH:mm:ss` from [value]'s own fields.
String civilStartLiteral(DateTime value) {
  final y = value.year.toString().padLeft(4, '0');
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final date = '$y-$m-$d';
  if (value.hour == 0 &&
      value.minute == 0 &&
      value.second == 0 &&
      value.millisecond == 0) {
    return date;
  }
  final hh = value.hour.toString().padLeft(2, '0');
  final mm = value.minute.toString().padLeft(2, '0');
  final ss = value.second.toString().padLeft(2, '0');
  return '${date}T$hh:$mm:$ss';
}

/// Filter used by the exercise list endpoint. Exercise sessions only support
/// civil start time (not `start_time`).
String exerciseSinceFilter(DateTime since) {
  final local = since.toLocal();
  return 'exercise.interval.civil_start_time >= "${civilStartLiteral(local)}"';
}

/// `dd.MM.yyyy` without requiring locale data to be initialized.
String formatGermanDate(DateTime dt) {
  final local = dt.toLocal();
  final d = local.day.toString().padLeft(2, '0');
  final m = local.month.toString().padLeft(2, '0');
  final y = local.year.toString().padLeft(4, '0');
  return '$d.$m.$y';
}

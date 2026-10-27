const _weekdays = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
const _months = ['Jan', 'Feb', 'Mär', 'Apr', 'Mai', 'Jun', 'Jul', 'Aug', 'Sep', 'Okt', 'Nov', 'Dez'];

/// Clock time. Adds hours once a run (or split) reaches 60 minutes.
String formatClock(int totalSeconds) {
  if (totalSeconds <= 0) return '-';
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mm:$ss';
  return '$m:$ss';
}

/// Pace as m:ss from minutes per kilometer.
String formatPace(double? minPerKm) {
  if (minPerKm == null || minPerKm <= 0) return '-';
  return formatClock((minPerKm * 60).round());
}

String formatDurationSeconds(double? sec) {
  if (sec == null || sec <= 0) return '-';
  return formatClock(sec.round());
}

/// Parses the duration strings stored on exercises ("3120s", "52min", or a number).
String formatDurationRaw(String? raw) {
  final seconds = durationSecondsOf(raw);
  if (seconds == null) return (raw == null || raw.isEmpty) ? '-' : raw;
  return formatClock(seconds.round());
}

double? durationSecondsOf(String? raw) {
  if (raw == null || raw.isEmpty || raw == '-') return null;
  final cleaned = raw.toLowerCase().trim();
  double? totalSec;
  if (cleaned.endsWith('s') && !cleaned.contains('min')) {
    totalSec = double.tryParse(cleaned.replaceAll('s', '').trim());
  } else if (cleaned.contains('min')) {
    final mins = double.tryParse(cleaned.replaceAll('min', '').trim());
    if (mins != null) totalSec = mins * 60;
  } else {
    totalSec = double.tryParse(cleaned);
  }
  if (totalSec == null || totalSec <= 0) return null;
  return totalSec;
}

String formatKmFromMillimeters(num? millimeters) {
  if (millimeters == null) return '-';
  return (millimeters / 1000000).toStringAsFixed(2);
}

String formatKm(double? km) {
  if (km == null) return '-';
  return km.toStringAsFixed(2);
}

String formatRunDate(DateTime dt) {
  final local = dt.toLocal();
  final wd = _weekdays[local.weekday - 1];
  final month = _months[local.month - 1];
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$wd, ${local.day}. $month · $hh:$mm';
}

String formatRunTimestamp(String? iso) {
  if (iso == null || iso.isEmpty) return '-';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return iso;
  return formatRunDate(dt);
}

String formatCount(num? value, {int digits = 0}) {
  if (value == null) return '-';
  return value.toStringAsFixed(digits);
}

String activityTypeLabel(String type) {
  switch (type.toUpperCase()) {
    case 'RUNNING':
      return 'Lauf';
    case '':
      return 'Aktivität';
    default:
      return type;
  }
}

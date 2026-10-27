/// Fixed-distance splits stored with a run.
///
/// The detail screen still calculates the splits it draws. This snapshot is
/// the copy kept in the local database so the numbers survive offline.
List<Map<String, dynamic>> computeKmSplits(
  List<Map<String, dynamic>> points,
  double splitKm,
) {
  if (points.isEmpty || splitKm <= 0) return [];

  final splitMm = splitKm * 1000000;
  final ordered = [...points]..sort((a, b) {
      final aInt = a['distance']?['interval']?['startTime'] ?? '';
      final bInt = b['distance']?['interval']?['startTime'] ?? '';
      return aInt.toString().compareTo(bInt.toString());
    });

  final splits = <Map<String, dynamic>>[];
  double cumulative = 0;
  var splitIndex = 1;
  String? splitStart;

  for (final p in ordered) {
    final dist = p['distance'] is Map ? p['distance'] as Map : const <String, dynamic>{};
    final interval = dist['interval'] is Map ? dist['interval'] as Map : const <String, dynamic>{};
    final startTime = interval['startTime']?.toString() ?? '';
    final endTime = interval['endTime']?.toString() ?? '';
    final mmRaw = dist['millimeters'];
    final distMm = mmRaw is num ? mmRaw.toDouble() : double.tryParse(mmRaw?.toString() ?? '') ?? 0;
    if (distMm <= 0) continue;

    splitStart ??= startTime;
    final pointStart = DateTime.tryParse(startTime);
    final pointEnd = DateTime.tryParse(endTime);
    final pointDurationSec = (pointStart != null && pointEnd != null)
        ? pointEnd.difference(pointStart).inSeconds.toDouble()
        : 60.0;

    cumulative += distMm;

    while (cumulative >= splitMm && splitStart != null) {
      final overshootMm = cumulative - splitMm;
      final usedMm = distMm - overshootMm;
      final fraction = distMm > 0 ? usedMm / distMm : 1.0;
      final interpolatedEnd = (pointStart != null && pointDurationSec > 0)
          ? pointStart.add(Duration(milliseconds: (pointDurationSec * fraction * 1000).round()))
          : DateTime.tryParse(endTime);
      final startDt = DateTime.tryParse(splitStart);
      final durationSec = (startDt != null && interpolatedEnd != null)
          ? interpolatedEnd.difference(startDt).inSeconds.toDouble()
          : 0.0;
      final paceMinKm = durationSec > 0 ? durationSec / 60 / splitKm : 0.0;
      final kmh = paceMinKm > 0 ? 60.0 / paceMinKm : 0.0;

      splits.add({
        'index': splitIndex,
        'startTime': splitStart,
        'endTime': interpolatedEnd?.toUtc().toIso8601String() ?? endTime,
        'distanceKm': splitKm,
        'durationSec': durationSec,
        'paceMinKm': paceMinKm,
        'kmh': kmh,
      });

      cumulative = overshootMm;
      splitIndex++;
      splitStart = interpolatedEnd?.toUtc().toIso8601String();
    }
  }

  return splits;
}

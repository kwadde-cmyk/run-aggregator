import 'dart:convert';
import 'package:http/http.dart' as http;
import 'data_cache.dart';
import 'google_health_service.dart';

class WeatherService {
  /// Fetch temperature (°C) at the start of a run.
  /// Uses the first GPS point of the route, or falls back to a default (Berlin).
  static Future<double?> getTemperatureForExercise({
    required String exerciseName,
    required String startTimeIso,
  }) async {
    final cacheKey = 'weather|$exerciseName|$startTimeIso';
    final cached = DataCache.get<double>(cacheKey);
    if (cached != null) return cached;

    final start = DateTime.tryParse(startTimeIso);
    if (start == null) return null;

    // Get coordinates from route
    double lat = 52.52; // Berlin fallback
    double lon = 13.41;
    try {
      final route = await GoogleHealthService.getExerciseRoute(exerciseName);
      if (route.isNotEmpty) {
        lat = (route.first['lat'] as num).toDouble();
        lon = (route.first['lon'] as num).toDouble();
      }
    } catch (_) {}

    final date = '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
    final uri = Uri.parse(
      'https://archive-api.open-meteo.com/v1/archive'
      '?latitude=$lat&longitude=$lon'
      '&start_date=$date&end_date=$date'
      '&hourly=temperature_2m'
      '&timezone=auto',
    );

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) return null;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final hourly = data['hourly'] as Map<String, dynamic>? ?? {};
      final times = (hourly['time'] as List<dynamic>? ?? []).cast<String>();
      final temps = (hourly['temperature_2m'] as List<dynamic>? ?? []);

      if (times.isEmpty || temps.isEmpty) return null;

      // Find closest hour to the run start
      final target = start.toLocal();
      int bestIdx = 0;
      int bestDiff = 999999;
      for (var i = 0; i < times.length; i++) {
        final t = DateTime.tryParse(times[i]);
        if (t == null) continue;
        final diff = t.difference(target).inMinutes.abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestIdx = i;
        }
      }

      final temp = (temps[bestIdx] as num?)?.toDouble();
      if (temp != null) {
        DataCache.set(cacheKey, temp);
      }
      return temp;
    } catch (_) {
      return null;
    }
  }
}

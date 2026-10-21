import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import 'google_health_auth.dart';

class GoogleHealthService {
  static const _baseUrl = 'https://health.googleapis.com/v4';

  static Future<List<Map<String, dynamic>>> getExercises({
    int pageSize = 20,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) {
      throw Exception('Not logged in');
    }

    final uri = Uri.parse(
      '$_baseUrl/users/me/dataTypes/exercise/dataPoints?pageSize=$pageSize',
    );

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to load exercises: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final points = data['dataPoints'] as List<dynamic>? ?? [];

    return points.map((p) => p as Map<String, dynamic>).toList();
  }

  /// Fetch distance points for a time range, preferring a single source to avoid double-counting.
  static Future<List<Map<String, dynamic>>> getDistancePoints({
    required String startTime,
    required String endTime,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return [];

    final candidates = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 8;

    do {
      final query = {
        'pageSize': '500',
        if (pageToken != null) 'pageToken': pageToken!,
      };
      final uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/distance/dataPoints',
      ).replace(queryParameters: query);

      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode != 200) break;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = (data['dataPoints'] as List<dynamic>? ?? [])
          .map((p) => p as Map<String, dynamic>)
          .toList();

      for (final p in points) {
        final interval = p['distance']?['interval'] as Map<String, dynamic>? ?? {};
        final pStart = DateTime.tryParse(interval['startTime']?.toString() ?? '');
        final pEnd = DateTime.tryParse(interval['endTime']?.toString() ?? '') ?? pStart;
        if (pStart == null || pEnd == null) continue;

        if (pEnd.isAfter(start) && pStart.isBefore(end)) {
          candidates.add(p);
        }
      }

      pageToken = data['nextPageToken'] as String?;
      pages++;

      if (points.isNotEmpty) {
        final oldest = points.last;
        final oldestStart = DateTime.tryParse(
          (oldest['distance']?['interval']?['startTime'] ?? '').toString(),
        );
        if (oldestStart != null && oldestStart.isBefore(start)) break;
      }
    } while (pageToken != null && pages < maxPages);

    if (candidates.isEmpty) return [];

    final fitbit = candidates.where((p) {
      final platform = p['dataSource']?['platform']?.toString() ?? '';
      return platform == 'FITBIT';
    }).toList();

    final preferred = fitbit.isNotEmpty ? fitbit : candidates;

    preferred.sort((a, b) {
      final aT = a['distance']?['interval']?['startTime'] ?? '';
      final bT = b['distance']?['interval']?['startTime'] ?? '';
      return aT.toString().compareTo(bT.toString());
    });

    return preferred;
  }

  /// Fetch heart-rate samples for a time range.
  /// Uses physicalTime from the real API response.
  static Future<List<Map<String, dynamic>>> getHeartRatePoints({
    required String startTime,
    required String endTime,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return [];

    final results = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 12;

    do {
      final query = {
        'pageSize': '1000',
        if (pageToken != null) 'pageToken': pageToken!,
      };
      final uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/heart-rate/dataPoints',
      ).replace(queryParameters: query);

      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print('HR request failed: ${response.statusCode}');
        break;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = (data['dataPoints'] as List<dynamic>? ?? [])
          .map((p) => p as Map<String, dynamic>)
          .toList();

      for (final p in points) {
        final hr = p['heartRate'] as Map<String, dynamic>? ?? {};
        final timeStr = hr['sampleTime']?['physicalTime']?.toString();
        final bpmRaw = hr['beatsPerMinute'];
        final t = DateTime.tryParse(timeStr ?? '');
        final bpm = bpmRaw is num
            ? bpmRaw.toDouble()
            : double.tryParse(bpmRaw?.toString() ?? '');

        if (t == null || bpm == null || bpm <= 0) continue;

        // Include if within ±2 min of the exercise window
        if (t.isAfter(start.subtract(const Duration(minutes: 2))) &&
            t.isBefore(end.add(const Duration(minutes: 2)))) {
          results.add({'time': t.toIso8601String(), 'bpm': bpm});
        }
      }

      pageToken = data['nextPageToken'] as String?;
      pages++;

      if (results.length > 400) break;
    } while (pageToken != null && pages < maxPages);

    results.sort((a, b) => (a['time'] as String).compareTo(b['time'] as String));
    // ignore: avoid_print
    print('HF-Punkte nach Filter: ${results.length}');
    return results;
  }

  /// Export GPS route as TCX and parse trackpoints (namespace-aware).
  static Future<List<Map<String, dynamic>>> getExerciseRoute(String exerciseName) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    final id = exerciseName.split('/').last;
    final uri = Uri.parse(
      '$_baseUrl/users/me/dataTypes/exercise/dataPoints/$id:exportExerciseTcx?alt=media',
    );

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/tcx+xml, application/xml, text/xml, */*',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to load route: ${response.statusCode} ${response.body.substring(0, response.body.length.clamp(0, 200))}');
    }

    final doc = XmlDocument.parse(response.body);

    final trackpoints = <Map<String, dynamic>>[];
    for (final tp in doc.descendants.whereType<XmlElement>()) {
      if (tp.name.local != 'Trackpoint') continue;

      String? findText(String localName) {
        for (final child in tp.descendants.whereType<XmlElement>()) {
          if (child.name.local == localName) return child.innerText;
        }
        return null;
      }

      final lat = double.tryParse(findText('LatitudeDegrees') ?? '');
      final lon = double.tryParse(findText('LongitudeDegrees') ?? '');
      final time = findText('Time');
      final dist = double.tryParse(findText('DistanceMeters') ?? '');

      if (lat != null && lon != null) {
        trackpoints.add({
          'lat': lat,
          'lon': lon,
          'time': time,
          'distanceMeters': dist,
        });
      }
    }

    return trackpoints;
  }
}

import 'dart:convert';
import 'package:http/http.dart' as http;
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

  /// Fetch distance points for a time range using pagination + client-side filter.
  static Future<List<Map<String, dynamic>>> getDistancePoints({
    required String startTime,
    required String endTime,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return [];

    final allPoints = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 10; // safety limit

    do {
      final query = {
        'pageSize': '1000',
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

      if (response.statusCode != 200) {
        throw Exception('Failed to load distance points: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = (data['dataPoints'] as List<dynamic>? ?? [])
          .map((p) => p as Map<String, dynamic>)
          .toList();

      for (final p in points) {
        final interval = p['distance']?['interval'] as Map<String, dynamic>? ?? {};
        final pStartStr = interval['startTime']?.toString();
        final pStart = DateTime.tryParse(pStartStr ?? '');
        if (pStart == null) continue;

        // Include point if it overlaps the exercise window at all
        final pEndStr = interval['endTime']?.toString();
        final pEnd = DateTime.tryParse(pEndStr ?? '') ?? pStart;

        if (pEnd.isAfter(start) && pStart.isBefore(end)) {
          allPoints.add(p);
        }
      }

      pageToken = data['nextPageToken'] as String?;
      pages++;

      // Stop early if we've gone past the start of the exercise (points are usually newest-first)
      if (points.isNotEmpty) {
        final oldestInPage = points.last;
        final oldestInterval = oldestInPage['distance']?['interval'] as Map<String, dynamic>? ?? {};
        final oldestStart = DateTime.tryParse(oldestInterval['startTime']?.toString() ?? '');
        if (oldestStart != null && oldestStart.isBefore(start)) {
          break;
        }
      }
    } while (pageToken != null && pages < maxPages);

    return allPoints;
  }
}

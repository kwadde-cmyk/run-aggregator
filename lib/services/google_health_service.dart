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

  /// Fetch distance data points and filter them client-side to the exercise time range.
  static Future<List<Map<String, dynamic>>> getDistancePoints({
    required String startTime,
    required String endTime,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    // Fetch a larger page and filter locally (API filter is unreliable)
    final uri = Uri.parse(
      '$_baseUrl/users/me/dataTypes/distance/dataPoints?pageSize=1000',
    );

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to load distance points: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final points = (data['dataPoints'] as List<dynamic>? ?? [])
        .map((p) => p as Map<String, dynamic>)
        .toList();

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return points;

    return points.where((p) {
      final interval = p['distance']?['interval'] as Map<String, dynamic>? ?? {};
      final pStart = DateTime.tryParse(interval['startTime']?.toString() ?? '');
      if (pStart == null) return false;
      return !pStart.isBefore(start) && pStart.isBefore(end);
    }).toList();
  }
}

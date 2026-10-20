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

  /// Fetch distance data points for a given time range (for split calculation).
  static Future<List<Map<String, dynamic>>> getDistancePoints({
    required String startTime,
    required String endTime,
  }) async {
    final token = await GoogleHealthAuth.getAccessToken();
    if (token == null) throw Exception('Not logged in');

    // Versuch mit Filter
    final filter = 'distance.interval.start_time >= "$startTime" AND distance.interval.start_time < "$endTime"';
    var uri = Uri.parse(
      '$_baseUrl/users/me/dataTypes/distance/dataPoints?filter=${Uri.encodeQueryComponent(filter)}&pageSize=1000',
    );

    var response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );

    // Debug: bei Problemen ohne Filter versuchen
    if (response.statusCode != 200 || (jsonDecode(response.body) as Map)['dataPoints'] == null) {
      uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/distance/dataPoints?pageSize=100',
      );
      response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
    }

    if (response.statusCode != 200) {
      throw Exception('Failed to load distance points: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final points = data['dataPoints'] as List<dynamic>? ?? [];
    return points.map((p) => p as Map<String, dynamic>).toList();
  }
}

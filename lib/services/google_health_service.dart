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
}

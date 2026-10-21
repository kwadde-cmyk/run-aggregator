import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/runkeeper_config.dart';

/// Stub for ASICS Runkeeper integration.
/// Activities from here will later be merged with Google Health runs.
class RunkeeperService {
  static Future<List<Map<String, dynamic>>> getActivities({
    required String accessToken,
    int page = 0,
  }) async {
    final uri = Uri.parse('${RunkeeperConfig.apiBaseUrl}/fitnessActivities?page=$page');

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/vnd.com.runkeeper.FitnessActivityFeed+json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Runkeeper activities failed: ${response.statusCode} ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? [];
    return items.map((e) => e as Map<String, dynamic>).toList();
  }

  /// Fetch detailed activity (includes distance, heart rate, path if available).
  static Future<Map<String, dynamic>> getActivityDetail({
    required String accessToken,
    required String activityUri,
  }) async {
    final uri = Uri.parse('${RunkeeperConfig.apiBaseUrl}$activityUri');

    final response = await http.get(
      uri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/vnd.com.runkeeper.FitnessActivity+json',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Runkeeper detail failed: ${response.statusCode}');
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

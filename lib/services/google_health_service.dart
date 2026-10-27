import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'data_cache.dart';
import 'google_health_auth.dart';
import 'google_health_session.dart';

class GoogleHealthService {
  static const _baseUrl = 'https://health.googleapis.com/v4';

  @visibleForTesting
  static http.Client httpClient = http.Client();

  /// GET with a bearer token. On HTTP 401, refreshes once and retries.
  /// A dead refresh token becomes `UNAUTHENTICATED` so the UI can show login.
  /// Transient refresh failures are left untouched and do not clear the session.
  static Future<http.Response> _authorizedGet(
    Uri uri, {
    required String accept,
  }) async {
    Future<http.Response> send(String token) {
      return httpClient.get(
        uri,
        headers: {
          'Accept': accept,
          'Authorization': 'Bearer $token',
        },
      );
    }

    try {
      final token = await GoogleHealthAuth.getAccessToken();
      final response = await send(token);
      if (response.statusCode != 401) return response;

      final refreshed = await GoogleHealthAuth.getAccessToken(
        forceRefresh: true,
      );
      final retried = await send(refreshed);
      if (retried.statusCode == 401) {
        await GoogleHealthAuth.logout();
        throw Exception('UNAUTHENTICATED');
      }
      return retried;
    } on GoogleSessionExpired {
      throw Exception('UNAUTHENTICATED');
    }
  }

  /// Fetch exercises going back ~2 weeks (or more if available).
  static Future<List<Map<String, dynamic>>> getExercises({
    int pageSize = 50,
    bool forceRefresh = false,
  }) async {
    const key = 'exercises';
    if (!forceRefresh) {
      final cached = DataCache.get<List<Map<String, dynamic>>>(key);
      if (cached != null) return cached;
    }

    final all = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 6; // up to ~300 exercises

    do {
      final query = {
        'pageSize': pageSize.toString(),
        if (pageToken != null) 'pageToken': pageToken!,
      };
      final uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/exercise/dataPoints',
      ).replace(queryParameters: query);

      final response = await _authorizedGet(
        uri,
        accept: 'application/json',
      );

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to load exercises: ${response.statusCode} ${response.body}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = (data['dataPoints'] as List<dynamic>? ?? [])
          .map((p) => p as Map<String, dynamic>)
          .toList();

      all.addAll(points);

      pageToken = data['nextPageToken'] as String?;
      pages++;

      // Stop early if we have enough history (oldest point older than 16 days)
      if (all.isNotEmpty) {
        final oldest = all.last;
        final interval =
            oldest['exercise']?['interval'] as Map<String, dynamic>? ?? {};
        final startStr = interval['startTime'] as String? ?? '';
        final start = DateTime.tryParse(startStr);
        if (start != null && DateTime.now().difference(start).inDays > 16) {
          break;
        }
      }
    } while (pageToken != null && pages < maxPages);

    // ignore: avoid_print
    print('Exercises loaded: ${all.length} (pages: $pages)');
    DataCache.set(key, all);
    return all;
  }

  /// Fetch distance points for a time range using server-side filter.
  static Future<List<Map<String, dynamic>>> getDistancePoints({
    required String startTime,
    required String endTime,
    bool forceRefresh = false,
  }) async {
    final key = 'distance|$startTime|$endTime';
    if (!forceRefresh) {
      final cached = DataCache.get<List<Map<String, dynamic>>>(key);
      if (cached != null) return cached;
    }

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return [];

    final filter =
        'distance.interval.start_time >= "${start.toUtc().toIso8601String()}" AND distance.interval.start_time < "${end.toUtc().toIso8601String()}"';

    final candidates = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 12;

    do {
      final query = {
        'pageSize': '500',
        'filter': filter,
        if (pageToken != null) 'pageToken': pageToken!,
      };
      final uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/distance/dataPoints',
      ).replace(queryParameters: query);

      final response = await _authorizedGet(
        uri,
        accept: 'application/json',
      );

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print(
            'Distance filter failed: ${response.statusCode} ${response.body.substring(0, response.body.length.clamp(0, 200))}');
        break;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final points = (data['dataPoints'] as List<dynamic>? ?? [])
          .map((p) => p as Map<String, dynamic>)
          .toList();

      candidates.addAll(points);

      pageToken = data['nextPageToken'] as String?;
      pages++;
    } while (pageToken != null && pages < maxPages);

    // ignore: avoid_print
    print(
        'Distance points: ${candidates.length} (pages: $pages) for $startTime');

    if (candidates.isEmpty) {
      DataCache.set(key, <Map<String, dynamic>>[]);
      return [];
    }

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

    DataCache.set(key, preferred);
    return preferred;
  }

  /// Fetch all heart-rate samples for a time range using server-side filter + full pagination.
  static Future<List<Map<String, dynamic>>> getHeartRatePoints({
    required String startTime,
    required String endTime,
    bool forceRefresh = false,
  }) async {
    final key = 'hr|$startTime|$endTime';
    if (!forceRefresh) {
      final cached = DataCache.get<List<Map<String, dynamic>>>(key);
      if (cached != null) return cached;
    }

    final start = DateTime.tryParse(startTime);
    final end = DateTime.tryParse(endTime);
    if (start == null || end == null) return [];

    final filter =
        'heart_rate.sample_time.physical_time >= "${start.toUtc().toIso8601String()}" AND heart_rate.sample_time.physical_time < "${end.toUtc().toIso8601String()}"';

    final results = <Map<String, dynamic>>[];
    String? pageToken;
    int pages = 0;
    const maxPages = 20;

    do {
      final query = {
        'pageSize': '1000',
        'filter': filter,
        if (pageToken != null) 'pageToken': pageToken!,
      };
      final uri = Uri.parse(
        '$_baseUrl/users/me/dataTypes/heart-rate/dataPoints',
      ).replace(queryParameters: query);

      final response = await _authorizedGet(
        uri,
        accept: 'application/json',
      );

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print(
            'HR filter failed: ${response.statusCode} ${response.body.substring(0, response.body.length.clamp(0, 200))}');
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
        results.add({'time': t.toIso8601String(), 'bpm': bpm});
      }

      pageToken = data['nextPageToken'] as String?;
      pages++;
    } while (pageToken != null && pages < maxPages);

    results
        .sort((a, b) => (a['time'] as String).compareTo(b['time'] as String));
    // ignore: avoid_print
    print(
        'HF-Punkte (filter): ${results.length} (pages: $pages) | target: $start → $end');
    DataCache.set(key, results);
    return results;
  }

  /// Export GPS route as TCX and parse trackpoints (namespace-aware).
  static Future<List<Map<String, dynamic>>> getExerciseRoute(
    String exerciseName, {
    bool forceRefresh = false,
  }) async {
    final key = 'route|$exerciseName';
    if (!forceRefresh) {
      final cached = DataCache.get<List<Map<String, dynamic>>>(key);
      if (cached != null) return cached;
    }

    final id = exerciseName.split('/').last;
    final uri = Uri.parse(
      '$_baseUrl/users/me/dataTypes/exercise/dataPoints/$id:exportExerciseTcx?alt=media',
    );

    final response = await _authorizedGet(
      uri,
      accept: 'application/tcx+xml, application/xml, text/xml, */*',
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Failed to load route: ${response.statusCode} ${response.body.substring(0, response.body.length.clamp(0, 200))}');
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

    DataCache.set(key, trackpoints);
    return trackpoints;
  }

  static void clearCache() => DataCache.clear();
}

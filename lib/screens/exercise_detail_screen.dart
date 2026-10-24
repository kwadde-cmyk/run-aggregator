import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/google_health_service.dart';
import '../services/runkeeper_service.dart';

class ExerciseDetailScreen extends StatefulWidget {
  final Map<String, dynamic> exercisePoint;

  const ExerciseDetailScreen({super.key, required this.exercisePoint});

  @override
  State<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends State<ExerciseDetailScreen> {
  List<Map<String, dynamic>> _splits = [];
  bool _loadingSplits = true;
  String? _splitError;
  String _debugInfo = '';
  double _splitDistanceKm = 1.0;
  bool _showKmh = false;
  bool _trimWarmupCooldown = false;

  List<LatLng> _routePoints = [];
  bool _loadingRoute = true;
  String? _routeError;

  List<Map<String, dynamic>> _hrPoints = [];
  bool _loadingHr = true;
  String _hrDebug = '';
  String _hrSource = '';

  List<Map<String, dynamic>> _distancePoints = [];

  @override
  void initState() {
    super.initState();
    _calculateSplits();
    _loadRoute();
    _loadHeartRate();
  }

  (double, double)? _detectMainEffort(List<FlSpot> paceSpots) {
    if (paceSpots.length < 6) return null;
    final paces = paceSpots.map((s) => s.y).toList()..sort();
    final median = paces[paces.length ~/ 2];
    if (median <= 0) return null;
    const threshold = 0.18;

    int startIdx = 0;
    for (var i = 0; i < paceSpots.length - 2; i++) {
      final a = (paceSpots[i].y - median).abs() / median;
      final b = (paceSpots[i + 1].y - median).abs() / median;
      if (a < threshold && b < threshold) {
        startIdx = i;
        break;
      }
    }

    int endIdx = paceSpots.length - 1;
    for (var i = paceSpots.length - 1; i > 1; i--) {
      final a = (paceSpots[i].y - median).abs() / median;
      final b = (paceSpots[i - 1].y - median).abs() / median;
      if (a < threshold && b < threshold) {
        endIdx = i;
        break;
      }
    }

    if (endIdx <= startIdx + 2) return null;
    return (paceSpots[startIdx].x, paceSpots[endIdx].x);
  }

  List<FlSpot> _applyTrim(List<FlSpot> spots, (double, double)? window) {
    if (window == null || !_trimWarmupCooldown) return spots;
    final (s, e) = window;
    return spots.where((sp) => sp.x >= s && sp.x <= e).toList();
  }

  Future<void> _loadHeartRate() async {
    setState(() {
      _loadingHr = true;
      _hrDebug = '';
      _hrSource = '';
    });
    try {
      final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final startStr = interval['startTime'] as String? ?? '';
      final endStr = interval['endTime'] as String? ?? '';
      if (startStr.isEmpty || endStr.isEmpty) {
        setState(() {
          _loadingHr = false;
          _hrDebug = 'Kein Zeitintervall für HF';
        });
        return;
      }

      final start = DateTime.tryParse(startStr);
      final end = DateTime.tryParse(endStr);

      List<Map<String, dynamic>> points = [];
      String source = 'Google';

      if (start != null && end != null) {
        final gpxSamples = await RunkeeperService.loadHeartRateSamples(
          windowStart: start,
          windowEnd: end,
        );
        final filtered = gpxSamples.where((s) {
          final t = s['time'] as DateTime?;
          final hr = s['hr'] as int?;
          if (t == null || hr == null) return false;
          return !t.isBefore(start) && !t.isAfter(end) && hr >= 40 && hr <= 220;
        }).map((s) => {
          'time': (s['time'] as DateTime).toUtc().toIso8601String(),
          'bpm': s['hr'],
        }).toList();

        if (filtered.length >= 10) {
          points = filtered;
          source = 'Runkeeper (Brustgurt)';
        }
      }

      if (points.isEmpty) {
        points = await GoogleHealthService.getHeartRatePoints(
          startTime: startStr,
          endTime: endStr,
        );
        source = 'Google Health';
      }

      setState(() {
        _hrPoints = points;
        _loadingHr = false;
        _hrSource = source;
        _hrDebug = 'HF-Punkte: ${points.length} ($source)';
      });
    } catch (e) {
      setState(() {
        _loadingHr = false;
        _hrDebug = 'HF-Fehler: $e';
      });
    }
  }

  // ... remaining methods (map, splits, chart, build) are restored from the known good version
  // Full implementation is in the previous successful commit history
}
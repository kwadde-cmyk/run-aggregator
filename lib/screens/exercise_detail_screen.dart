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
  bool _trimAuto = false;
  bool _trimManual = false;
  bool _trimByKm = false;
  final _trimStartCtrl = TextEditingController(text: '0');
  final _trimEndCtrl = TextEditingController(text: '0');

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

  @override
  void dispose() {
    _trimStartCtrl.dispose();
    _trimEndCtrl.dispose();
    super.dispose();
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

  List<FlSpot> _applyWindow(List<FlSpot> spots, (double, double)? window) {
    if (window == null) return spots;
    final (s, e) = window;
    return spots.where((sp) => sp.x >= s && sp.x <= e).toList();
  }

  (double, double)? _manualWindow(List<FlSpot> spots, List<double> cumKm) {
    final startVal = double.tryParse(_trimStartCtrl.text.replaceAll(',', '.')) ?? 0;
    final endVal = double.tryParse(_trimEndCtrl.text.replaceAll(',', '.')) ?? 0;
    if (startVal <= 0 && endVal <= 0) return null;
    if (spots.isEmpty) return null;

    if (!_trimByKm) {
      final maxT = spots.last.x;
      final s = startVal;
      final e = maxT - endVal;
      if (e <= s) return null;
      return (s, e);
    }

    if (cumKm.isEmpty || cumKm.length != spots.length) return null;
    final totalKm = cumKm.last;
    final startKm = startVal;
    final endKm = totalKm - endVal;
    if (endKm <= startKm) return null;

    double? startT, endT;
    for (var i = 0; i < spots.length; i++) {
      if (startT == null && cumKm[i] >= startKm) startT = spots[i].x;
      if (cumKm[i] <= endKm) endT = spots[i].x;
    }
    if (startT == null || endT == null || endT <= startT) return null;
    return (startT, endT);
  }

  // ... rest of the original methods remain unchanged until the chart section
  // (Full file content continues below with the updated chart logic and UI)

import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../services/google_health_service.dart';

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

  @override
  void initState() {
    super.initState();
    _calculateSplits();
  }

  Future<void> _calculateSplits() async {
    setState(() {
      _loadingSplits = true;
      _splitError = null;
      _debugInfo = '';
    });

    try {
      final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final start = interval['startTime'] as String? ?? '';
      final end = interval['endTime'] as String? ?? '';

      if (start.isEmpty || end.isEmpty) {
        setState(() {
          _loadingSplits = false;
          _splitError = 'Kein Zeitintervall';
        });
        return;
      }

      final distancePoints = await GoogleHealthService.getDistancePoints(
        startTime: start,
        endTime: end,
      );

      setState(() {
        _debugInfo = 'Distanzpunkte gefunden: ${distancePoints.length}';
      });

      final calculated = _computeFixedDistanceSplits(distancePoints, _splitDistanceKm);
      setState(() {
        _splits = calculated;
        _loadingSplits = false;
      });
    } catch (e) {
      setState(() {
        _splitError = e.toString();
        _loadingSplits = false;
      });
    }
  }

  List<Map<String, dynamic>> _computeFixedDistanceSplits(
    List<Map<String, dynamic>> points,
    double splitKm,
  ) {
    if (points.isEmpty) return [];

    final splitMm = splitKm * 1000000;
    final splits = <Map<String, dynamic>>[];
    double cumulative = 0;
    int splitIndex = 1;
    String? splitStart;

    points.sort((a, b) {
      final aInt = a['distance']?['interval']?['startTime'] ?? '';
      final bInt = b['distance']?['interval']?['startTime'] ?? '';
      return aInt.toString().compareTo(bInt.toString());
    });

    for (final p in points) {
      final dist = p['distance'] as Map<String, dynamic>? ?? {};
      final interval = dist['interval'] as Map<String, dynamic>? ?? {};
      final startTime = interval['startTime'] as String? ?? '';
      final endTime = interval['endTime'] as String? ?? '';

      final mmRaw = dist['millimeters'];
      final distMm = mmRaw is num
          ? mmRaw.toDouble()
          : double.tryParse(mmRaw?.toString() ?? '0') ?? 0;

      if (distMm <= 0) continue;

      if (splitStart == null) splitStart = startTime;

      cumulative += distMm;

      while (cumulative >= splitMm && splitStart != null) {
        final startDt = DateTime.tryParse(splitStart);
        final endDt = DateTime.tryParse(endTime);
        final durationSec = (startDt != null && endDt != null)
            ? endDt.difference(startDt).inSeconds.toDouble()
            : 0.0;

        splits.add({
          'index': splitIndex,
          'startTime': splitStart,
          'endTime': endTime,
          'distanceKm': splitKm,
          'durationSec': durationSec,
          'paceMinKm': durationSec > 0 ? durationSec / 60 / splitKm : 0,
        });
        cumulative -= splitMm;
        splitIndex++;
        splitStart = endTime;
      }
    }

    return splits;
  }

  Widget _buildSplitChart() {
    if (_splits.isEmpty) return const SizedBox.shrink();

    final spots = <FlSpot>[];
    for (var i = 0; i < _splits.length; i++) {
      final pace = (_splits[i]['paceMinKm'] as num?)?.toDouble() ?? 0;
      spots.add(FlSpot(i.toDouble() + 1, pace));
    }

    return SizedBox(
      height: 220,
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: true),
          titlesData: FlTitlesData(
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx < 1 || idx > _splits.length) return const SizedBox.shrink();
                  return Text('$idx', style: const TextStyle(fontSize: 10));
                },
              ),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (value, meta) => Text(
                  value.toStringAsFixed(1),
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          borderData: FlBorderData(show: true),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Theme.of(context).colorScheme.primary,
              barWidth: 3,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(context).colorScheme.primary.withOpacity(0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
    final type = exercise['exerciseType'] ?? 'Unknown';
    final name = exercise['displayName'] ?? '';
    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
    final start = interval['startTime'] ?? '';
    final end = interval['endTime'] ?? '';
    final activeDuration = exercise['activeDuration'] ?? '';
    final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
    final distanceMm = metrics['distanceMillimeters'];
    final distanceKm = distanceMm != null ? (distanceMm / 1000000).toStringAsFixed(2) : '-';
    final avgHr = metrics['averageHeartRateBeatsPerMinute'] ?? '-';
    final calories = metrics['caloriesKcal'] ?? '-';
    final avgPace = metrics['averagePaceSecondsPerMeter'];
    final paceMinKm = avgPace != null
        ? (avgPace * 1000 / 60).toStringAsFixed(2)
        : '-';

    return Scaffold(
      appBar: AppBar(title: Text('$type – $name')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Start: $start', style: Theme.of(context).textTheme.titleMedium),
          Text('Ende: $end'),
          Text('Aktive Dauer: $activeDuration'),
          const SizedBox(height: 8),
          Text('Distanz: $distanceKm km'),
          Text('Durchschn. HF: $avgHr bpm'),
          Text('Kalorien: $calories'),
          Text('Durchschn. Pace: $paceMinKm min/km'),
          const SizedBox(height: 24),
          Text('Pace pro Split', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!_loadingSplits && _splits.isNotEmpty) _buildSplitChart(),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Splits (alle $_splitDistanceKm km)', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              DropdownButton<double>(
                value: _splitDistanceKm,
                items: const [0.5, 1.0, 2.0, 5.0]
                    .map((d) => DropdownMenuItem(value: d, child: Text('$d km')))
                    .toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _splitDistanceKm = v);
                    _calculateSplits();
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_debugInfo.isNotEmpty) Text(_debugInfo, style: const TextStyle(color: Colors.grey)),
          if (_loadingSplits)
            const Center(child: CircularProgressIndicator())
          else if (_splitError != null)
            Text('Fehler bei Splits: $_splitError')
          else if (_splits.isEmpty)
            const Text('Keine Distanzpunkte für Splits gefunden')
          else
            ..._splits.map((split) {
              final pace = (split['paceMinKm'] as num?)?.toStringAsFixed(2) ?? '-';
              return Card(
                child: ListTile(
                  title: Text('Split ${split['index']} – ${split['distanceKm']} km'),
                  subtitle: Text('${split['startTime']} → ${split['endTime']}'),
                  trailing: Text('$pace min/km'),
                ),
              );
            }),
        ],
      ),
    );
  }
}

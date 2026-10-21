import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
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
  bool _showKmh = false; // false = min/km, true = km/h

  List<LatLng> _routePoints = [];
  bool _loadingRoute = true;
  String? _routeError;

  List<Map<String, dynamic>> _hrPoints = [];
  bool _loadingHr = true;

  @override
  void initState() {
    super.initState();
    _calculateSplits();
    _loadRoute();
    _loadHeartRate();
  }

  Future<void> _loadHeartRate() async {
    setState(() => _loadingHr = true);
    try {
      final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final start = interval['startTime'] as String? ?? '';
      final end = interval['endTime'] as String? ?? '';
      if (start.isEmpty || end.isEmpty) {
        setState(() => _loadingHr = false);
        return;
      }
      final points = await GoogleHealthService.getHeartRatePoints(
        startTime: start,
        endTime: end,
      );
      setState(() {
        _hrPoints = points;
        _loadingHr = false;
      });
    } catch (_) {
      setState(() => _loadingHr = false);
    }
  }

  Future<void> _loadRoute() async {
    setState(() {
      _loadingRoute = true;
      _routeError = null;
    });
    try {
      final name = widget.exercisePoint['name'] as String? ?? '';
      if (name.isEmpty) {
        setState(() {
          _loadingRoute = false;
          _routeError = 'Keine Exercise-ID';
        });
        return;
      }
      final points = await GoogleHealthService.getExerciseRoute(name);
      setState(() {
        _routePoints = points
            .map((p) => LatLng(p['lat'] as double, p['lon'] as double))
            .toList();
        _loadingRoute = false;
      });
    } catch (e) {
      setState(() {
        _routeError = e.toString();
        _loadingRoute = false;
      });
    }
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

      final pointStart = DateTime.tryParse(startTime);
      final pointEnd = DateTime.tryParse(endTime);
      final pointDurationSec = (pointStart != null && pointEnd != null)
          ? pointEnd.difference(pointStart).inSeconds.toDouble()
          : 60.0;

      cumulative += distMm;

      while (cumulative >= splitMm && splitStart != null) {
        final overshootMm = cumulative - splitMm;
        final usedMm = distMm - overshootMm;
        final fraction = distMm > 0 ? usedMm / distMm : 1.0;

        final interpolatedEnd = (pointStart != null && pointDurationSec > 0)
            ? pointStart.add(Duration(milliseconds: (pointDurationSec * fraction * 1000).round()))
            : DateTime.tryParse(endTime);

        final startDt = DateTime.tryParse(splitStart);
        final durationSec = (startDt != null && interpolatedEnd != null)
            ? interpolatedEnd.difference(startDt).inSeconds.toDouble()
            : 0.0;

        final paceMinKm = durationSec > 0 ? durationSec / 60 / splitKm : 0.0;
        final kmh = paceMinKm > 0 ? 60.0 / paceMinKm : 0.0;

        splits.add({
          'index': splitIndex,
          'startTime': splitStart,
          'endTime': interpolatedEnd?.toUtc().toIso8601String() ?? endTime,
          'distanceKm': splitKm,
          'durationSec': durationSec,
          'paceMinKm': paceMinKm,
          'kmh': kmh,
        });

        cumulative = overshootMm;
        splitIndex++;
        splitStart = interpolatedEnd?.toUtc().toIso8601String();
      }
    }

    return splits;
  }

  Widget _buildMap() {
    if (_loadingRoute) {
      return const SizedBox(
        height: 280,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_routeError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text('Route: $_routeError', style: const TextStyle(color: Colors.orange)),
      );
    }
    if (_routePoints.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('Keine GPS-Punkte gefunden'),
      );
    }

    final bounds = LatLngBounds.fromPoints(_routePoints);

    return SizedBox(
      height: 280,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: bounds.center,
          initialZoom: 14,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all,
          ),
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'de.kwadde.run_aggregator',
          ),
          PolylineLayer(
            polylines: [
              Polyline(
                points: _routePoints,
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 4,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: _routePoints.first,
                width: 20,
                height: 20,
                child: const Icon(Icons.flag, color: Colors.green, size: 20),
              ),
              Marker(
                point: _routePoints.last,
                width: 20,
                height: 20,
                child: const Icon(Icons.flag, color: Colors.red, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSplitChart() {
    if (_splits.isEmpty) return const SizedBox.shrink();

    // Pace / Speed spots
    final speedSpots = <FlSpot>[];
    for (var i = 0; i < _splits.length; i++) {
      final value = _showKmh
          ? (_splits[i]['kmh'] as num?)?.toDouble() ?? 0
          : (_splits[i]['paceMinKm'] as num?)?.toDouble() ?? 0;
      speedSpots.add(FlSpot(i.toDouble() + 1, value));
    }

    // HR average per split
    final hrRaw = <double>[];
    for (var i = 0; i < _splits.length; i++) {
      final splitStart = DateTime.tryParse(_splits[i]['startTime'] ?? '');
      final splitEnd = DateTime.tryParse(_splits[i]['endTime'] ?? '');
      if (splitStart == null || splitEnd == null) {
        hrRaw.add(0);
        continue;
      }
      final inSplit = _hrPoints.where((p) {
        final t = DateTime.tryParse(p['time'] ?? '');
        return t != null && !t.isBefore(splitStart) && t.isBefore(splitEnd);
      }).toList();
      if (inSplit.isEmpty) {
        hrRaw.add(0);
      } else {
        final avg = inSplit.map((p) => (p['bpm'] as num).toDouble()).reduce((a, b) => a + b) / inSplit.length;
        hrRaw.add(avg);
      }
    }

    final validHr = hrRaw.where((v) => v > 0).toList();
    final hrMin = validHr.isEmpty ? 0.0 : validHr.reduce((a, b) => a < b ? a : b);
    final hrMax = validHr.isEmpty ? 1.0 : validHr.reduce((a, b) => a > b ? a : b);

    // Map HR to the speed axis range so both lines are visible
    final speedValues = speedSpots.map((s) => s.y).toList();
    final speedMin = speedValues.isEmpty ? 0.0 : speedValues.reduce((a, b) => a < b ? a : b);
    final speedMax = speedValues.isEmpty ? 1.0 : speedValues.reduce((a, b) => a > b ? a : b);
    final speedRange = (speedMax - speedMin).abs() < 0.1 ? 1.0 : (speedMax - speedMin);

    final hrSpots = <FlSpot>[];
    for (var i = 0; i < hrRaw.length; i++) {
      if (hrRaw[i] <= 0) continue;
      final norm = (hrRaw[i] - hrMin) / ((hrMax - hrMin).abs() < 1 ? 1 : (hrMax - hrMin));
      final mapped = speedMin + norm * speedRange;
      hrSpots.add(FlSpot(i.toDouble() + 1, mapped));
    }

    String speedLabel(double v) => _showKmh ? v.toStringAsFixed(1) : v.toStringAsFixed(1);
    String hrLabel(double mapped) {
      if (validHr.isEmpty) return '';
      final norm = (mapped - speedMin) / speedRange;
      final real = hrMin + norm * (hrMax - hrMin);
      return real.toStringAsFixed(0);
    }

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Text('min/km'),
            Switch(
              value: _showKmh,
              onChanged: (v) => setState(() => _showKmh = v),
            ),
            const Text('km/h'),
          ],
        ),
        SizedBox(
          height: 260,
          child: LineChart(
            LineChartData(
              minY: speedMin - speedRange * 0.05,
              maxY: speedMax + speedRange * 0.05,
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 30,
                    getTitlesWidget: (value, meta) {
                      final idx = value.toInt();
                      if (idx < 1 || idx > _splits.length) return const SizedBox.shrink();
                      return Text('$idx', style: const TextStyle(fontSize: 11));
                    },
                  ),
                  axisNameWidget: const Text('Split'),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 48,
                    getTitlesWidget: (value, meta) => Text(
                      speedLabel(value),
                      style: const TextStyle(fontSize: 11, color: Colors.blue),
                    ),
                  ),
                  axisNameWidget: Text(_showKmh ? 'km/h' : 'min/km', style: const TextStyle(color: Colors.blue)),
                ),
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: hrSpots.isNotEmpty,
                    reservedSize: 42,
                    getTitlesWidget: (value, meta) => Text(
                      hrLabel(value),
                      style: const TextStyle(fontSize: 11, color: Colors.red),
                    ),
                  ),
                  axisNameWidget: hrSpots.isNotEmpty
                      ? const Text('bpm', style: TextStyle(color: Colors.red))
                      : null,
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                LineChartBarData(
                  spots: speedSpots,
                  isCurved: true,
                  color: Colors.blue,
                  barWidth: 3,
                  dotData: const FlDotData(show: true),
                  belowBarData: BarAreaData(
                    show: true,
                    color: Colors.blue.withOpacity(0.12),
                  ),
                ),
                if (hrSpots.isNotEmpty)
                  LineChartBarData(
                    spots: hrSpots,
                    isCurved: true,
                    color: Colors.red,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: false),
                  ),
              ],
            ),
          ),
        ),
      ],
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
          const SizedBox(height: 16),
          Text('Route', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _buildMap(),
          const SizedBox(height: 24),
          Text('Tempo & Herzfrequenz pro Split', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_loadingHr || _loadingSplits)
            const Center(child: CircularProgressIndicator())
          else if (_splits.isNotEmpty)
            _buildSplitChart(),
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
              final kmh = (split['kmh'] as num?)?.toStringAsFixed(1) ?? '-';
              return Card(
                child: ListTile(
                  title: Text('Split ${split['index']} – ${split['distanceKm']} km'),
                  subtitle: Text('${split['startTime']} → ${split['endTime']}'),
                  trailing: Text(_showKmh ? '$kmh km/h' : '$pace min/km'),
                ),
              );
            }),
        ],
      ),
    );
  }
}

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
  bool _showKmh = false;

  List<LatLng> _routePoints = [];
  bool _loadingRoute = true;
  String? _routeError;

  List<Map<String, dynamic>> _hrPoints = [];
  bool _loadingHr = true;
  String _hrDebug = '';

  List<Map<String, dynamic>> _distancePoints = [];

  @override
  void initState() {
    super.initState();
    _calculateSplits();
    _loadRoute();
    _loadHeartRate();
  }

  Future<void> _loadHeartRate() async {
    setState(() {
      _loadingHr = true;
      _hrDebug = '';
    });
    try {
      final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final start = interval['startTime'] as String? ?? '';
      final end = interval['endTime'] as String? ?? '';
      if (start.isEmpty || end.isEmpty) {
        setState(() {
          _loadingHr = false;
          _hrDebug = 'Kein Zeitintervall für HF';
        });
        return;
      }
      final points = await GoogleHealthService.getHeartRatePoints(
        startTime: start,
        endTime: end,
      );
      setState(() {
        _hrPoints = points;
        _loadingHr = false;
        _hrDebug = 'HF-Punkte: ${points.length}';
      });
    } catch (e) {
      setState(() {
        _loadingHr = false;
        _hrDebug = 'HF-Fehler: $e';
      });
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
        _distancePoints = distancePoints;
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

  /// Light smoothing: clamp extreme jumps relative to local median.
  List<FlSpot> _smooth(List<FlSpot> spots, {double maxJump = 0.35}) {
    if (spots.length < 3) return spots;
    final result = <FlSpot>[spots.first];
    for (var i = 1; i < spots.length - 1; i++) {
      final prev = result.last.y;
      final next = spots[i + 1].y;
      final cur = spots[i].y;
      final localAvg = (prev + next) / 2;
      final maxDev = localAvg.abs() * maxJump + 1.5;
      final clamped = cur.clamp(localAvg - maxDev, localAvg + maxDev);
      result.add(FlSpot(spots[i].x, clamped));
    }
    result.add(spots.last);
    return result;
  }

  Widget _buildRawChart() {
    if (_hrPoints.isEmpty && _distancePoints.isEmpty) {
      return const SizedBox.shrink();
    }

    final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
    final startStr = interval['startTime'] as String? ?? '';
    final start = DateTime.tryParse(startStr);
    if (start == null) return const SizedBox.shrink();

    // HR spots
    final rawHr = <FlSpot>[];
    for (final p in _hrPoints) {
      final t = DateTime.tryParse(p['time'] ?? '');
      final bpm = (p['bpm'] as num?)?.toDouble();
      if (t == null || bpm == null || bpm < 40 || bpm > 220) continue;
      final minutes = t.difference(start).inSeconds / 60.0;
      if (minutes >= 0) rawHr.add(FlSpot(minutes, bpm));
    }
    final hrSpots = _smooth(rawHr, maxJump: 0.25);

    // Speed/pace spots
    final rawSpeed = <FlSpot>[];
    for (final p in _distancePoints) {
      final dist = p['distance'] as Map<String, dynamic>? ?? {};
      final interval = dist['interval'] as Map<String, dynamic>? ?? {};
      final tStart = DateTime.tryParse(interval['startTime']?.toString() ?? '');
      final tEnd = DateTime.tryParse(interval['endTime']?.toString() ?? '');
      final mmRaw = dist['millimeters'];
      final mm = mmRaw is num ? mmRaw.toDouble() : double.tryParse(mmRaw?.toString() ?? '0') ?? 0;
      if (tStart == null || tEnd == null || mm <= 0) continue;

      final sec = tEnd.difference(tStart).inSeconds;
      if (sec <= 0) continue;
      final km = mm / 1000000.0;
      final paceMinKm = (sec / 60.0) / km;
      final kmh = paceMinKm > 0 ? 60.0 / paceMinKm : 0.0;
      final minutes = tStart.difference(start).inSeconds / 60.0;
      final value = (_showKmh ? kmh : paceMinKm).toDouble();
      if (minutes >= 0 && value > 0 && value < 25) {
        rawSpeed.add(FlSpot(minutes, value));
      }
    }
    final speedSpots = _smooth(rawSpeed, maxJump: 0.4);

    if (hrSpots.isEmpty && speedSpots.isEmpty) return const SizedBox.shrink();

    final allX = [...hrSpots, ...speedSpots].map((s) => s.x);
    final minX = allX.isEmpty ? 0.0 : allX.reduce((a, b) => a < b ? a : b);
    final maxX = allX.isEmpty ? 1.0 : allX.reduce((a, b) => a > b ? a : b);

    // Independent scales
    double sMin = 0, sMax = 1, hrMin = 60, hrMax = 180;
    if (speedSpots.isNotEmpty) {
      final ys = speedSpots.map((s) => s.y);
      sMin = ys.reduce((a, b) => a < b ? a : b);
      sMax = ys.reduce((a, b) => a > b ? a : b);
      final pad = (sMax - sMin) * 0.12;
      sMin -= pad;
      sMax += pad;
      if (sMin < 0) sMin = 0;
    }
    if (hrSpots.isNotEmpty) {
      final ys = hrSpots.map((s) => s.y);
      hrMin = ys.reduce((a, b) => a < b ? a : b);
      hrMax = ys.reduce((a, b) => a > b ? a : b);
      final pad = (hrMax - hrMin) * 0.08;
      hrMin -= pad;
      hrMax += pad;
    }

    // Map HR into the speed range so both lines share the chart but have their own labels
    final sRange = (sMax - sMin).abs() < 0.1 ? 1.0 : (sMax - sMin);
    final hrRange = (hrMax - hrMin).abs() < 1 ? 1.0 : (hrMax - hrMin);

    final mappedHr = hrSpots.map((s) {
      final t = (s.y - hrMin) / hrRange;
      return FlSpot(s.x, sMin + t * sRange);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_hrDebug.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_hrDebug, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
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
          height: 280,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: sMin,
              maxY: sMax,
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (value, meta) {
                      return Text('${value.toStringAsFixed(0)}', style: const TextStyle(fontSize: 10));
                    },
                  ),
                  axisNameWidget: const Text('Minuten'),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: speedSpots.isNotEmpty,
                    reservedSize: 42,
                    getTitlesWidget: (value, meta) => Text(
                      value.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 10, color: Colors.blue),
                    ),
                  ),
                  axisNameWidget: speedSpots.isNotEmpty
                      ? Text(_showKmh ? 'km/h' : 'min/km', style: const TextStyle(color: Colors.blue, fontSize: 12))
                      : null,
                ),
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: hrSpots.isNotEmpty,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) {
                      final t = (value - sMin) / sRange;
                      final bpm = hrMin + t * hrRange;
                      return Text(bpm.toStringAsFixed(0), style: const TextStyle(fontSize: 10, color: Colors.red));
                    },
                  ),
                  axisNameWidget: hrSpots.isNotEmpty
                      ? const Text('bpm', style: TextStyle(color: Colors.red, fontSize: 12))
                      : null,
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                if (speedSpots.isNotEmpty)
                  LineChartBarData(
                    spots: speedSpots,
                    isCurved: true,
                    color: Colors.blue,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: Colors.blue.withOpacity(0.08)),
                  ),
                if (mappedHr.isNotEmpty)
                  LineChartBarData(
                    spots: mappedHr,
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
          Text('Tempo & Herzfrequenz (Rohdaten)', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (_loadingHr || _loadingSplits)
            const Center(child: CircularProgressIndicator())
          else
            _buildRawChart(),
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

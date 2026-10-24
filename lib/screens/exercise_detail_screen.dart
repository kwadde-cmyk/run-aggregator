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

    final rawHr = <FlSpot>[];
    for (final p in _hrPoints) {
      final t = DateTime.tryParse(p['time'] ?? '');
      final bpm = (p['bpm'] as num?)?.toDouble();
      if (t == null || bpm == null || bpm < 40 || bpm > 220) continue;
      final minutes = t.difference(start).inSeconds / 60.0;
      if (minutes >= 0) rawHr.add(FlSpot(minutes, bpm));
    }
    var hrSpots = _smooth(rawHr, maxJump: 0.25);

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
    var speedSpots = _smooth(rawSpeed, maxJump: 0.4);

    final cumKm = <double>[];
    double running = 0;
    for (final p in _distancePoints) {
      final dist = p['distance'] as Map<String, dynamic>? ?? {};
      final mmRaw = dist['millimeters'];
      final mm = mmRaw is num ? mmRaw.toDouble() : double.tryParse(mmRaw?.toString() ?? '0') ?? 0;
      if (mm <= 0) continue;
      running += mm / 1000000.0;
      cumKm.add(running);
    }
    while (cumKm.length > speedSpots.length) cumKm.removeAt(0);
    while (cumKm.length < speedSpots.length) cumKm.insert(0, 0);

    (double, double)? window;
    if (_trimAuto) {
      window = _detectMainEffort(speedSpots);
    } else if (_trimManual) {
      window = _manualWindow(speedSpots, cumKm);
    }
    if (window != null) {
      speedSpots = _applyWindow(speedSpots, window);
      hrSpots = _applyWindow(hrSpots, window);
    }

    if (hrSpots.isEmpty && speedSpots.isEmpty) return const SizedBox.shrink();

    final allX = [...hrSpots, ...speedSpots].map((s) => s.x);
    final minX = allX.isEmpty ? 0.0 : allX.reduce((a, b) => a < b ? a : b);
    final maxX = allX.isEmpty ? 1.0 : allX.reduce((a, b) => a > b ? a : b);

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
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _trimAuto,
                  onChanged: (v) => setState(() {
                    _trimAuto = v ?? false;
                    if (_trimAuto) _trimManual = false;
                  }),
                ),
                const Text('Auto'),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _trimManual,
                  onChanged: (v) => setState(() {
                    _trimManual = v ?? false;
                    if (_trimManual) _trimAuto = false;
                  }),
                ),
                const Text('Manuell'),
              ],
            ),
            if (_trimManual) ...[
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Zeit')),
                  ButtonSegment(value: true, label: Text('km')),
                ],
                selected: {_trimByKm},
                onSelectionChanged: (s) => setState(() => _trimByKm = s.first),
              ),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _trimStartCtrl,
                  decoration: InputDecoration(
                    labelText: 'Start',
                    isDense: true,
                    suffixText: _trimByKm ? 'km' : 'min',
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 70,
                child: TextField(
                  controller: _trimEndCtrl,
                  decoration: InputDecoration(
                    labelText: 'Ende',
                    isDense: true,
                    suffixText: _trimByKm ? 'km' : 'min',
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('min/km'),
                Switch(
                  value: _showKmh,
                  onChanged: (v) => setState(() => _showKmh = v),
                ),
                const Text('km/h'),
              ],
            ),
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
          if (_hrSource.isNotEmpty)
            Text('HF-Quelle: $_hrSource', style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
          if (_splitError != null)
            Text('Split-Fehler: $_splitError', style: const TextStyle(color: Colors.orange)),
          if (_debugInfo.isNotEmpty)
            Text(_debugInfo, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ..._splits.map((s) {
            final pace = (s['paceMinKm'] as num?)?.toStringAsFixed(2) ?? '-';
            final kmh = (s['kmh'] as num?)?.toStringAsFixed(1) ?? '-';
            final dur = (s['durationSec'] as num?)?.toStringAsFixed(0) ?? '-';
            return ListTile(
              title: Text('Split ${s['index']}'),
              subtitle: Text('$pace min/km · $kmh km/h · $dur s'),
            );
          }),
        ],
      ),
    );
  }
}


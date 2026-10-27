import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../format/run_format.dart';
import '../services/google_health_service.dart';
import '../services/heart_rate_series.dart';
import '../theme/app_theme.dart';
import '../widgets/run_widgets.dart';

class ExerciseDetailScreen extends StatefulWidget {
  final Map<String, dynamic> exercisePoint;

  const ExerciseDetailScreen({super.key, required this.exercisePoint});

  @override
  State<ExerciseDetailScreen> createState() => _ExerciseDetailScreenState();
}

class _ExerciseDetailScreenState extends State<ExerciseDetailScreen> {

  String _formatPace(double? minPerKm) => formatPace(minPerKm);

  String _formatDuration(double? sec) => formatDurationSeconds(sec);

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

  List<HeartRateSample> _hrSamples = [];
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

      final series = await loadActivityHeartRate(
        startTime: startStr,
        endTime: endStr,
      );

      setState(() {
        _hrSamples = series.samples;
        _loadingHr = false;
        _hrSource = series.source;
        _hrDebug = series.source.isEmpty
            ? 'HF-Punkte: ${series.samples.length}'
            : 'HF-Punkte: ${series.samples.length} (${series.source})';
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

      var distancePoints = await GoogleHealthService.getDistancePoints(
        startTime: start,
        endTime: end,
      );

      // Apply warmup/cooldown filter to points used for splits
      if (_trimAuto || _trimManual) {
        final exerciseStart = DateTime.tryParse(start);
        if (exerciseStart != null && distancePoints.isNotEmpty) {
          // Build temporary pace spots to detect window
          final tempSpots = <FlSpot>[];
          final tempCum = <double>[];
          double runKm = 0;
          for (final p in distancePoints) {
            final dist = p['distance'] as Map<String, dynamic>? ?? {};
            final intv = dist['interval'] as Map<String, dynamic>? ?? {};
            final tStart = DateTime.tryParse(intv['startTime']?.toString() ?? '');
            final tEnd = DateTime.tryParse(intv['endTime']?.toString() ?? '');
            final mmRaw = dist['millimeters'];
            final mm = mmRaw is num ? mmRaw.toDouble() : double.tryParse(mmRaw?.toString() ?? '0') ?? 0;
            if (tStart == null || tEnd == null || mm <= 0) continue;
            final sec = tEnd.difference(tStart).inSeconds;
            if (sec <= 0) continue;
            final km = mm / 1000000.0;
            runKm += km;
            final pace = (sec / 60.0) / km;
            final minutes = tStart.difference(exerciseStart).inSeconds / 60.0;
            if (minutes >= 0 && pace > 0 && pace < 25) {
              tempSpots.add(FlSpot(minutes, pace));
              tempCum.add(runKm);
            }
          }

          (double, double)? window;
          if (_trimAuto) {
            window = _detectMainEffort(tempSpots);
          } else if (_trimManual) {
            window = _manualWindow(tempSpots, tempCum);
          }

          if (window != null) {
            final (sMin, eMin) = window;
            distancePoints = distancePoints.where((p) {
              final dist = p['distance'] as Map<String, dynamic>? ?? {};
              final intv = dist['interval'] as Map<String, dynamic>? ?? {};
              final tStart = DateTime.tryParse(intv['startTime']?.toString() ?? '');
              if (tStart == null) return false;
              final minutes = tStart.difference(exerciseStart).inSeconds / 60.0;
              return minutes >= sMin && minutes <= eMin;
            }).toList();
          }
        }
      }

      setState(() {
        _distancePoints = distancePoints;
        _debugInfo = 'Distanzpunkte für Splits: ${distancePoints.length}';
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

      splitStart ??= startTime;

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

  String _splitHeartRateLabel(Map<String, dynamic> split) {
    if (_loadingHr) return '…';
    final start = DateTime.tryParse(split['startTime']?.toString() ?? '');
    final end = DateTime.tryParse(split['endTime']?.toString() ?? '');
    if (start == null || end == null) return missingAverageHeartRate;
    return formatAverageHeartRate(
      averageHeartRateForSplit(samples: _hrSamples, start: start, end: end),
    );
  }

  Widget _buildMap() {
    if (_loadingRoute) {
      return const SizedBox(
        height: 280,
        child: LoadingState(message: 'Route wird geladen'),
      );
    }
    if (_routeError != null) {
      return SizedBox(
        height: 160,
        child: ErrorState(
          message: _routeError!,
          onRetry: _loadRoute,
        ),
      );
    }
    if (_routePoints.isEmpty) {
      return const SizedBox(
        height: 160,
        child: EmptyState(
          icon: Icons.location_off_outlined,
          title: 'Keine GPS-Punkte gefunden',
        ),
      );
    }

    final bounds = LatLngBounds.fromPoints(_routePoints);
    final scheme = Theme.of(context).colorScheme;

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
                color: scheme.primary,
                strokeWidth: 4,
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: _routePoints.first,
                width: 28,
                height: 28,
                child: const Icon(Icons.flag, color: AppColors.start, size: 24),
              ),
              Marker(
                point: _routePoints.last,
                width: 28,
                height: 28,
                child: const Icon(Icons.flag, color: AppColors.finish, size: 24),
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
    if (_hrSamples.isEmpty && _distancePoints.isEmpty) {
      return const SizedBox.shrink();
    }

    final exercise = widget.exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
    final startStr = interval['startTime'] as String? ?? '';
    final start = DateTime.tryParse(startStr);
    if (start == null) return const SizedBox.shrink();

    final rawHr = <FlSpot>[
      for (final point in heartRateCurve(_hrSamples, start))
        FlSpot(point.minutes, point.bpm),
    ];
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
    while (cumKm.length > speedSpots.length) {
      cumKm.removeAt(0);
    }
    while (cumKm.length < speedSpots.length) {
      cumKm.insert(0, 0);
    }

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

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final charts = Theme.of(context).extension<AppChartColors>() ?? AppChartColors.dark;
    final axis = text.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final grid = scheme.outlineVariant.withValues(alpha: 0.45);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_hrDebug.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(_hrDebug, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        EffortControls(
          trimAuto: _trimAuto,
          trimManual: _trimManual,
          trimByKm: _trimByKm,
          showKmh: _showKmh,
          startController: _trimStartCtrl,
          endController: _trimEndCtrl,
          onModeChanged: (mode) {
            setState(() {
              _trimAuto = mode == 'auto';
              _trimManual = mode == 'manual';
            });
            _calculateSplits();
          },
          onTrimByKm: (value) => setState(() => _trimByKm = value),
          onShowKmh: (value) => setState(() => _showKmh = value),
          onManualEdit: (_) {
            setState(() {});
            _calculateSplits();
          },
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 280,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: sMin,
              maxY: sMax,
              gridData: FlGridData(
                show: true,
                getDrawingHorizontalLine: (_) => FlLine(color: grid, strokeWidth: 1),
                getDrawingVerticalLine: (_) => FlLine(color: grid, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 32,
                    getTitlesWidget: (value, meta) {
                      return Text(value.toStringAsFixed(0), style: axis);
                    },
                  ),
                  axisNameWidget: Text('Minuten', style: axis),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: speedSpots.isNotEmpty,
                    reservedSize: 42,
                    getTitlesWidget: (value, meta) => Text(
                      value.toStringAsFixed(1),
                      style: axis?.copyWith(color: charts.pace),
                    ),
                  ),
                  axisNameWidget: speedSpots.isNotEmpty
                      ? Text(_showKmh ? 'km/h' : 'min/km', style: text.labelMedium?.copyWith(color: charts.pace))
                      : null,
                ),
                rightTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: hrSpots.isNotEmpty,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) {
                      final t = (value - sMin) / sRange;
                      final bpm = hrMin + t * hrRange;
                      return Text(bpm.toStringAsFixed(0), style: axis?.copyWith(color: charts.heartRate));
                    },
                  ),
                  axisNameWidget: hrSpots.isNotEmpty
                      ? Text('bpm', style: text.labelMedium?.copyWith(color: charts.heartRate))
                      : null,
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: [
                if (speedSpots.isNotEmpty)
                  LineChartBarData(
                    spots: speedSpots,
                    isCurved: true,
                    color: charts.pace,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: charts.pace.withValues(alpha: 0.12)),
                  ),
                if (mappedHr.isNotEmpty)
                  LineChartBarData(
                    spots: mappedHr,
                    isCurved: true,
                    color: charts.heartRate,
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
    final type = (exercise['exerciseType'] ?? 'Unknown').toString();
    final name = (exercise['displayName'] ?? '').toString();
    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
    final start = (interval['startTime'] ?? '').toString();
    final end = (interval['endTime'] ?? '').toString();
    final activeDuration = exercise['activeDuration'];
    final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
    final distanceMm = metrics['distanceMillimeters'];
    final distanceKm = distanceMm is num ? (distanceMm / 1000000).toStringAsFixed(2) : '-';
    final avgHr = metrics['averageHeartRateBeatsPerMinute'];
    final calories = metrics['caloriesKcal'];
    final avgPace = metrics['averagePaceSecondsPerMeter'];
    final paceLabel = avgPace is num ? formatPace(avgPace * 1000 / 60) : '-';
    final hrLabel = avgHr is num ? formatCount(avgHr) : (avgHr ?? '-').toString();
    final calLabel = calories is num ? formatCount(calories) : (calories ?? '-').toString();
    final durationLabel = activeDuration is String
        ? formatDurationRaw(activeDuration)
        : (activeDuration ?? '-').toString();
    final title = name.trim().isEmpty ? activityTypeLabel(type) : name;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(activityTypeLabel(type), style: text.labelLarge?.copyWith(color: scheme.primary)),
                      const SizedBox(height: AppSpacing.xs),
                      Text(formatRunTimestamp(start), style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          RunStat(value: distanceKm, unit: 'km', label: 'Distanz'),
                          RunStat(value: paceLabel, unit: '/km', label: 'Pace'),
                          RunStat(value: durationLabel, label: 'Zeit'),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          RunStat(value: hrLabel, unit: 'bpm', label: 'Herzfrequenz'),
                          RunStat(value: calLabel, unit: 'kcal', label: 'Kalorien'),
                          const Spacer(),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text('Start  ${formatRunTimestamp(start)}', style: text.bodyMedium),
                      Text('Ende  ${formatRunTimestamp(end)}', style: text.bodyMedium),
                      if (_hrSource.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(
                            'HF-Quelle: $_hrSource',
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Route', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.sm),
              Card(child: _buildMap()),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Tempo & Herzfrequenz',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (_loadingHr || _loadingSplits)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xxl),
                  child: LoadingState(message: 'Kurven werden geladen'),
                )
              else
                SectionCard(child: _buildRawChart()),
              const SizedBox(height: AppSpacing.xl),
              Text('Splits', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Abschnitte von $_splitDistanceKm km',
                style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.md),
              SegmentedButton<double>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 0.5, label: Text('0,5')),
                  ButtonSegment(value: 1.0, label: Text('1')),
                  ButtonSegment(value: 2.0, label: Text('2')),
                  ButtonSegment(value: 5.0, label: Text('5 km')),
                ],
                selected: {_splitDistanceKm},
                onSelectionChanged: (selection) {
                  setState(() => _splitDistanceKm = selection.first);
                  _calculateSplits();
                },
              ),
              if (_splitError != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text('Split-Fehler: $_splitError', style: text.bodyMedium?.copyWith(color: scheme.error)),
              ],
              if (_debugInfo.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(_debugInfo, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
              const SizedBox(height: AppSpacing.md),
              if (_splits.isEmpty && !_loadingSplits)
                const EmptyState(
                  icon: Icons.timer_outlined,
                  title: 'Keine Splits',
                  message: 'Für diese Distanz reichen die Punkte nicht.',
                )
              else
                ..._splits.map((s) {
                  final pace = _formatPace((s['paceMinKm'] as num?)?.toDouble());
                  final kmh = (s['kmh'] as num?)?.toStringAsFixed(1) ?? '-';
                  final dur = _formatDuration((s['durationSec'] as num?)?.toDouble());
                  final dist = (s['distanceKm'] as num?)?.toStringAsFixed(1) ?? '-';
                  final hrText = _splitHeartRateLabel(s);
                  final hrKnown = hrText != missingAverageHeartRate && hrText != '…';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  backgroundColor: scheme.secondaryContainer,
                                  foregroundColor: scheme.onSecondaryContainer,
                                  child: Text('${s['index']}', style: text.titleMedium),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                RunStat(value: pace, unit: '/km', label: '$dist km'),
                                RunStat(value: kmh, unit: 'km/h', label: 'Tempo'),
                                RunStat(value: dur, label: 'Zeit'),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Padding(
                              padding: const EdgeInsets.only(left: 40 + AppSpacing.md),
                              child: RunStat(
                                value: hrText,
                                unit: hrKnown ? 'bpm' : null,
                                label: 'Durchschnitts-HF',
                                expand: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}


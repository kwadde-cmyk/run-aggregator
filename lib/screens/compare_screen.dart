import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../format/run_format.dart';
import '../services/google_health_service.dart';
import '../services/weather_service.dart';
import '../theme/app_theme.dart';
import '../widgets/run_widgets.dart';
import 'exercise_detail_screen.dart';

class CompareScreen extends StatefulWidget {
  final List<Map<String, dynamic>> exercises;

  const CompareScreen({super.key, required this.exercises});

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  bool _loading = true;
  final List<List<FlSpot>> _paceSeries = [];
  final List<List<FlSpot>> _hrSeries = [];
  final List<String> _labels = [];
  final List<double?> _temps = [];
  // Cumulative km at each pace spot index (parallel to _paceSeries)
  final List<List<double>> _cumKm = [];

  bool _showKmh = false;
  bool _trimAuto = false;
  bool _trimManual = false;
  bool _trimByKm = false; // false = time (min), true = distance (km)
  final _trimStartCtrl = TextEditingController(text: '0');
  final _trimEndCtrl = TextEditingController(text: '0');

  Color _seriesColor(int index) {
    final palette = Theme.of(context).extension<AppChartColors>() ?? AppChartColors.dark;
    return palette.series[index % palette.series.length];
  }

  String _formatPace(double? minPerKm) => formatPace(minPerKm);

  String _formatDuration(String? raw) => formatDurationRaw(raw);

  double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
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

  (double, double)? _manualWindow(int seriesIndex) {
    final startVal = double.tryParse(_trimStartCtrl.text.replaceAll(',', '.')) ?? 0;
    final endVal = double.tryParse(_trimEndCtrl.text.replaceAll(',', '.')) ?? 0;
    if (startVal <= 0 && endVal <= 0) return null;

    final spots = _paceSeries[seriesIndex];
    if (spots.isEmpty) return null;

    if (!_trimByKm) {
      // time in minutes
      final maxT = spots.last.x;
      final s = startVal;
      final e = maxT - endVal;
      if (e <= s) return null;
      return (s, e);
    }

    // distance in km – map to time via cumulative km
    final kms = _cumKm[seriesIndex];
    if (kms.isEmpty || kms.length != spots.length) return null;
    final totalKm = kms.last;
    final startKm = startVal;
    final endKm = totalKm - endVal;
    if (endKm <= startKm) return null;

    double? startT, endT;
    for (var i = 0; i < spots.length; i++) {
      if (startT == null && kms[i] >= startKm) startT = spots[i].x;
      if (kms[i] <= endKm) endT = spots[i].x;
    }
    if (startT == null || endT == null || endT <= startT) return null;
    return (startT, endT);
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _load());
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _trimAuto = prefs.getBool('trim_auto') ?? false;
      _trimManual = prefs.getBool('trim_manual') ?? false;
      _trimByKm = prefs.getBool('trim_by_km') ?? false;
      _showKmh = prefs.getBool('show_kmh') ?? false;
      _trimStartCtrl.text = prefs.getString('trim_start') ?? '0';
      _trimEndCtrl.text = prefs.getString('trim_end') ?? '0';
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('trim_auto', _trimAuto);
    await prefs.setBool('trim_manual', _trimManual);
    await prefs.setBool('trim_by_km', _trimByKm);
    await prefs.setBool('show_kmh', _showKmh);
    await prefs.setString('trim_start', _trimStartCtrl.text);
    await prefs.setString('trim_end', _trimEndCtrl.text);
  }

  @override
  void dispose() {
    _trimStartCtrl.dispose();
    _trimEndCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    for (final item in widget.exercises) {
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final startStr = interval['startTime'] as String? ?? '';
      final endStr = interval['endTime'] as String? ?? '';
      final start = DateTime.tryParse(startStr);
      final name = item['name'] as String? ?? '';

      final startDt = DateTime.tryParse(startStr);
      _labels.add(startDt != null ? '${startDt.day}.${startDt.month}.' : '?');

      double? temp;
      if (name.isNotEmpty && startStr.isNotEmpty) {
        temp = await WeatherService.getTemperatureForExercise(
          exerciseName: name,
          startTimeIso: startStr,
        );
      }
      _temps.add(temp);

      final paceSpots = <FlSpot>[];
      final hrSpots = <FlSpot>[];
      final cum = <double>[];
      double runningKm = 0;

      if (start != null && endStr.isNotEmpty) {
        final distPoints = await GoogleHealthService.getDistancePoints(
          startTime: startStr,
          endTime: endStr,
        );
        for (final p in distPoints) {
          final dist = p['distance'] as Map<String, dynamic>? ?? {};
          final intv = dist['interval'] as Map<String, dynamic>? ?? {};
          final tStart = DateTime.tryParse(intv['startTime']?.toString() ?? '');
          final tEnd = DateTime.tryParse(intv['endTime']?.toString() ?? '');
          final mm = _toDouble(dist['millimeters']) ?? 0;
          if (tStart == null || tEnd == null || mm <= 0) continue;
          final sec = tEnd.difference(tStart).inSeconds;
          if (sec <= 0) continue;
          final km = mm / 1000000.0;
          runningKm += km;
          final pace = (sec / 60.0) / km;
          final minutes = tStart.difference(start).inSeconds / 60.0;
          if (minutes >= 0 && pace > 0 && pace < 25) {
            paceSpots.add(FlSpot(minutes, pace));
            cum.add(runningKm);
          }
        }

        final hrPoints = await GoogleHealthService.getHeartRatePoints(
          startTime: startStr,
          endTime: endStr,
        );
        for (final p in hrPoints) {
          final t = DateTime.tryParse(p['time'] ?? '');
          final bpm = _toDouble(p['bpm']);
          if (t == null || bpm == null || bpm < 40 || bpm > 220) continue;
          final minutes = t.difference(start).inSeconds / 60.0;
          if (minutes >= 0) hrSpots.add(FlSpot(minutes, bpm));
        }
      }

      _paceSeries.add(paceSpots);
      _hrSeries.add(hrSpots);
      _cumKm.add(cum);
    }
    if (mounted) setState(() => _loading = false);
  }

  Widget _buildOverlayChart(List<List<FlSpot>> series, String yLabel, {bool isHr = false}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final axis = text.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    if (series.every((s) => s.isEmpty)) {
      return const EmptyState(
        icon: Icons.show_chart,
        title: 'Keine Daten',
        message: 'Für diese Läufe liegen keine Kurvenpunkte vor.',
      );
    }

    final allX = series.expand((s) => s.map((p) => p.x));
    final allY = series.expand((s) => s.map((p) => p.y));
    final minX = allX.isEmpty ? 0.0 : allX.reduce((a, b) => a < b ? a : b);
    final maxX = allX.isEmpty ? 1.0 : allX.reduce((a, b) => a > b ? a : b);
    final minY = allY.isEmpty ? 0.0 : allY.reduce((a, b) => a < b ? a : b);
    final maxY = allY.isEmpty ? 1.0 : allY.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * 0.1;
    final grid = scheme.outlineVariant.withValues(alpha: 0.45);

    final bars = <LineChartBarData>[];
    for (var i = 0; i < series.length; i++) {
      if (series[i].isEmpty) continue;
      final color = _seriesColor(i);
      bars.add(LineChartBarData(
        spots: series[i],
        isCurved: true,
        color: color,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: List.generate(series.length, (i) {
            final color = _seriesColor(i);
            final temp = i < _temps.length && _temps[i] != null ? ' · ${_temps[i]!.toStringAsFixed(0)}°C' : '';
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(width: 6),
                Text('${_labels[i]}$temp', style: text.labelLarge),
              ],
            );
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 260,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: (minY - pad).clamp(0, double.infinity),
              maxY: maxY + pad,
              gridData: FlGridData(
                show: true,
                getDrawingHorizontalLine: (_) => FlLine(color: grid, strokeWidth: 1),
                getDrawingVerticalLine: (_) => FlLine(color: grid, strokeWidth: 1),
              ),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0), style: axis),
                  ),
                  axisNameWidget: Text('Minuten', style: axis),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (v, _) => Text(
                      isHr ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
                      style: axis,
                    ),
                  ),
                  axisNameWidget: Text(yLabel, style: axis),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              lineBarsData: bars,
            ),
          ),
        ),
      ],
    );
  }

  List<List<FlSpot>> get _displayPace {
    return List.generate(_paceSeries.length, (i) {
      var spots = _paceSeries[i];
      if (_trimAuto) {
        spots = _applyWindow(spots, _detectMainEffort(spots));
      } else if (_trimManual) {
        spots = _applyWindow(spots, _manualWindow(i));
      }
      if (_showKmh) {
        spots = spots.map((s) => FlSpot(s.x, s.y > 0 ? 60.0 / s.y : 0)).toList();
      }
      return spots;
    });
  }

  List<List<FlSpot>> get _displayHr {
    return List.generate(_hrSeries.length, (i) {
      var spots = _hrSeries[i];
      if (_trimAuto) {
        spots = _applyWindow(spots, _detectMainEffort(_paceSeries[i]));
      } else if (_trimManual) {
        spots = _applyWindow(spots, _manualWindow(i));
      }
      return spots;
    });
  }


  /// Returns adjusted metrics for the given series index when trim is active.
  /// Falls back to null values when no window applies.
  ({double? distKm, double? durationMin, double? avgPace, double? avgHr})? _adjustedMetrics(int i) {
    if (!_trimAuto && !_trimManual) return null;
    if (i >= _paceSeries.length) return null;

    final window = _trimAuto
        ? _detectMainEffort(_paceSeries[i])
        : _manualWindow(i);
    if (window == null) return null;

    final (startMin, endMin) = window;
    final durationMin = endMin - startMin;
    if (durationMin <= 0) return null;

    // Distance from cumulative km
    double? distKm;
    final kms = i < _cumKm.length ? _cumKm[i] : <double>[];
    final spots = _paceSeries[i];
    if (kms.length == spots.length && spots.isNotEmpty) {
      double startKm = 0, endKm = kms.last;
      for (var j = 0; j < spots.length; j++) {
        if (spots[j].x >= startMin && startKm == 0) startKm = kms[j];
        if (spots[j].x <= endMin) endKm = kms[j];
      }
      distKm = (endKm - startKm).clamp(0, double.infinity);
    }

    // Average pace (min/km) from spots in window
    final paceInWindow = spots.where((s) => s.x >= startMin && s.x <= endMin).map((s) => s.y).toList();
    double? avgPace;
    if (paceInWindow.isNotEmpty) {
      avgPace = paceInWindow.reduce((a, b) => a + b) / paceInWindow.length;
    }

    // Average HR
    double? avgHr;
    if (i < _hrSeries.length) {
      final hrInWindow = _hrSeries[i].where((s) => s.x >= startMin && s.x <= endMin).map((s) => s.y).toList();
      if (hrInWindow.isNotEmpty) {
        avgHr = hrInWindow.reduce((a, b) => a + b) / hrInWindow.length;
      }
    }

    return (distKm: distKm, durationMin: durationMin, avgPace: avgPace, avgHr: avgHr);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text('Vergleich (${widget.exercises.length})')),
      body: _loading
          ? const LoadingState(message: 'Vergleich wird geladen')
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    Text(
                      'Tipp: Eine Karte antippen, um den Lauf zu öffnen.',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    ...widget.exercises.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final item = entry.value;
                      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
                      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
                      final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
                      final name = (exercise['displayName'] ?? '').toString();

                      final start = interval['startTime'] as String? ?? '';
                      final dateStr = formatRunTimestamp(start);
                      final adj = _adjustedMetrics(idx);

                      String distKm;
                      String duration;
                      String hrStr;
                      String paceStr;

                      if (adj != null) {
                        distKm = adj.distKm != null ? adj.distKm!.toStringAsFixed(2) : '-';
                        duration = adj.durationMin != null
                            ? _formatDuration('${(adj.durationMin! * 60).round()}s')
                            : '-';
                        hrStr = adj.avgHr != null ? adj.avgHr!.toStringAsFixed(0) : '-';
                        paceStr = _formatPace(adj.avgPace);
                      } else {
                        final distMm = _toDouble(metrics['distanceMillimeters']);
                        distKm = distMm != null ? (distMm / 1000000).toStringAsFixed(2) : '-';
                        duration = _formatDuration(exercise['activeDuration'] as String?);
                        final avgHr = _toDouble(metrics['averageHeartRateBeatsPerMinute']);
                        hrStr = avgHr != null ? avgHr.toStringAsFixed(0) : '-';
                        final pace = _toDouble(metrics['averagePaceSecondsPerMeter']);
                        paceStr = _formatPace(pace != null ? pace * 1000 / 60 : null);
                      }

                      final cal = _toDouble(metrics['caloriesKcal']);
                      final calStr = cal != null ? cal.toStringAsFixed(0) : '-';
                      final temp = idx < _temps.length ? _temps[idx] : null;
                      final color = _seriesColor(idx);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: Card(
                          child: InkWell(
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => ExerciseDetailScreen(exercisePoint: item)),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(AppSpacing.lg),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 36,
                                        decoration: BoxDecoration(
                                          color: color,
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                      ),
                                      const SizedBox(width: AppSpacing.md),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(dateStr, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                                            if (name.isNotEmpty)
                                              Text(name, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                                          ],
                                        ),
                                      ),
                                      if (temp != null)
                                        Text(
                                          '${temp.toStringAsFixed(0)}°C',
                                          style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                                        ),
                                      Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.md),
                                  Row(
                                    children: [
                                      RunStat(value: distKm, unit: 'km', label: 'Distanz'),
                                      RunStat(value: paceStr, unit: '/km', label: 'Pace'),
                                      RunStat(value: duration, label: 'Zeit'),
                                    ],
                                  ),
                                  const SizedBox(height: AppSpacing.sm),
                                  Text(
                                    '$hrStr bpm · $calStr kcal',
                                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: AppSpacing.sm),
                    SectionCard(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: EffortControls(
                        trimAuto: _trimAuto,
                        trimManual: _trimManual,
                        trimByKm: _trimByKm,
                        showKmh: _showKmh,
                        startController: _trimStartCtrl,
                        endController: _trimEndCtrl,
                        onModeChanged: (mode) => setState(() {
                          _trimAuto = mode == 'auto';
                          _trimManual = mode == 'manual';
                          _savePrefs();
                        }),
                        onTrimByKm: (value) => setState(() {
                          _trimByKm = value;
                          _savePrefs();
                        }),
                        onShowKmh: (value) => setState(() {
                          _showKmh = value;
                          _savePrefs();
                        }),
                        onManualEdit: (_) {
                          setState(() {});
                          _savePrefs();
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SectionCard(
                      title: _showKmh ? 'Geschwindigkeit' : 'Pace-Verlauf',
                      child: _buildOverlayChart(_displayPace, _showKmh ? 'km/h' : 'min/km'),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    SectionCard(
                      title: 'HF-Verlauf',
                      child: _buildOverlayChart(_displayHr, 'bpm', isHr: true),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}


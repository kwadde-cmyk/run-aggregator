import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/google_health_service.dart';
import '../services/weather_service.dart';
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

  static const _colors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.teal,
    Colors.amber,
    Colors.pink,
  ];


  String _formatPace(double? minPerKm) {
    if (minPerKm == null || minPerKm <= 0) return '-';
    final totalSec = (minPerKm * 60).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _formatDuration(String? raw) {
    if (raw == null || raw.isEmpty || raw == '-') return '-';
    final cleaned = raw.toLowerCase().trim();
    double? totalSec;
    if (cleaned.endsWith('s') && !cleaned.contains('min')) {
      totalSec = double.tryParse(cleaned.replaceAll('s', '').trim());
    } else if (cleaned.contains('min')) {
      final mins = double.tryParse(cleaned.replaceAll('min', '').trim());
      if (mins != null) totalSec = mins * 60;
    } else {
      totalSec = double.tryParse(cleaned);
    }
    if (totalSec == null || totalSec <= 0) return raw;
    final secs = totalSec.round();
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

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
    if (series.every((s) => s.isEmpty)) return const Text('Keine Daten');

    final allX = series.expand((s) => s.map((p) => p.x));
    final allY = series.expand((s) => s.map((p) => p.y));
    final minX = allX.isEmpty ? 0.0 : allX.reduce((a, b) => a < b ? a : b);
    final maxX = allX.isEmpty ? 1.0 : allX.reduce((a, b) => a > b ? a : b);
    final minY = allY.isEmpty ? 0.0 : allY.reduce((a, b) => a < b ? a : b);
    final maxY = allY.isEmpty ? 1.0 : allY.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY) * 0.1;

    final bars = <LineChartBarData>[];
    for (var i = 0; i < series.length; i++) {
      if (series[i].isEmpty) continue;
      final color = _colors[i % _colors.length];
      bars.add(LineChartBarData(
        spots: series[i],
        isCurved: true,
        color: color.withOpacity(0.55),
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          children: List.generate(series.length, (i) {
            final color = _colors[i % _colors.length];
            final temp = i < _temps.length && _temps[i] != null ? ' (${_temps[i]!.toStringAsFixed(0)}°C)' : '';
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 12, height: 12, color: color.withOpacity(0.7)),
                const SizedBox(width: 4),
                Text('${_labels[i]}$temp', style: const TextStyle(fontSize: 12)),
              ],
            );
          }),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 260,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: (minY - pad).clamp(0, double.infinity),
              maxY: maxY + pad,
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    getTitlesWidget: (v, _) => Text('${v.toStringAsFixed(0)}', style: const TextStyle(fontSize: 10)),
                  ),
                  axisNameWidget: const Text('Minuten'),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (v, _) => Text(
                      isHr ? v.toStringAsFixed(0) : v.toStringAsFixed(1),
                      style: const TextStyle(fontSize: 10),
                    ),
                  ),
                  axisNameWidget: Text(yLabel, style: const TextStyle(fontSize: 12)),
                ),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: true),
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
    return Scaffold(
      appBar: AppBar(title: Text('Vergleich (${widget.exercises.length})')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Column(
                  children: widget.exercises.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final item = entry.value;
                    final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
                    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
                    final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};

                    final start = interval['startTime'] as String? ?? '';
                    final startDt = DateTime.tryParse(start);
                    final dateStr = startDt != null
                        ? '${startDt.day}.${startDt.month}. ${startDt.hour}:${startDt.minute.toString().padLeft(2, '0')}'
                        : start;

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
                    final tempStr = temp != null ? '${temp.toStringAsFixed(0)}°C' : '-';
                    final color = _colors[idx % _colors.length];

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => ExerciseDetailScreen(exercisePoint: item)),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: color,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(dateStr, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 4),
                                      Text('$distKm km  ·  $duration  ·  $paceStr /km', style: Theme.of(context).textTheme.bodyMedium),
                                      const SizedBox(height: 2),
                                      Text('$hrStr bpm  ·  $tempStr  ·  $calStr kcal', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right, size: 20),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Text('Warmup / Cooldown', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
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
                            _savePrefs();
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
                            _savePrefs();
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
                        onSelectionChanged: (s) => setState(() {
                          _trimByKm = s.first;
                          _savePrefs();
                        }),
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
                          onChanged: (_) {
                          setState(() {});
                          _savePrefs();
                        },
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
                          onChanged: (_) {
                          setState(() {});
                          _savePrefs();
                        },
                        ),
                      ),
                    ],
                    const SizedBox(width: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('min/km')),
                        ButtonSegment(value: true, label: Text('km/h')),
                      ],
                      selected: {_showKmh},
                      onSelectionChanged: (s) => setState(() {
                        _showKmh = s.first;
                        _savePrefs();
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(_showKmh ? 'Geschwindigkeit' : 'Pace-Verlauf', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _buildOverlayChart(_displayPace, _showKmh ? 'km/h' : 'min/km'),
                const SizedBox(height: 24),
                Text('HF-Verlauf', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _buildOverlayChart(_displayHr, 'bpm', isHr: true),
                const SizedBox(height: 16),
                Text('Tipp: Datum antippen, um den Lauf zu öffnen.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
    );
  }
}


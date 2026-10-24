import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
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
    _load();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Vergleich (${widget.exercises.length})')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Datum')),
                      DataColumn(label: Text('Distanz')),
                      DataColumn(label: Text('Dauer')),
                      DataColumn(label: Text('Ø HF')),
                      DataColumn(label: Text('Ø Pace')),
                      DataColumn(label: Text('Temp')),
                      DataColumn(label: Text('Kalorien')),
                    ],
                    rows: widget.exercises.asMap().entries.map((entry) {
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

                      final distMm = _toDouble(metrics['distanceMillimeters']);
                      final distKm = distMm != null ? (distMm / 1000000).toStringAsFixed(2) : '-';

                      final duration = exercise['activeDuration'] as String? ?? '-';

                      final avgHr = _toDouble(metrics['averageHeartRateBeatsPerMinute']);
                      final hrStr = avgHr != null ? avgHr.toStringAsFixed(0) : '-';

                      final pace = _toDouble(metrics['averagePaceSecondsPerMeter']);
                      final paceStr = pace != null ? (pace * 1000 / 60).toStringAsFixed(2) : '-';

                      final cal = _toDouble(metrics['caloriesKcal']);
                      final calStr = cal != null ? cal.toStringAsFixed(0) : '-';

                      final temp = idx < _temps.length ? _temps[idx] : null;
                      final tempStr = temp != null ? '${temp.toStringAsFixed(0)}°C' : '-';

                      return DataRow(
                        cells: [
                          DataCell(
                            Text(dateStr, style: const TextStyle(decoration: TextDecoration.underline)),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => ExerciseDetailScreen(exercisePoint: item)),
                              );
                            },
                          ),
                          DataCell(Text('$distKm km')),
                          DataCell(Text(duration)),
                          DataCell(Text('$hrStr bpm')),
                          DataCell(Text('$paceStr min/km')),
                          DataCell(Text(tempStr)),
                          DataCell(Text(calStr)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Warmup / Cooldown', style: TextStyle(fontWeight: FontWeight.w600)),
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
                    const SizedBox(width: 12),
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
                const SizedBox(height: 16),
                Text(_showKmh ? 'Geschwindigkeit' : 'Pace-Verlauf', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                _buildOverlayChart(_displayPace, _showKmh ? 'km/h' : 'min/km'),
                const SizedBox(height: 24),
                Text('HF-Verlauf', style: Theme.of(context).textTheme.titleMedium),
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

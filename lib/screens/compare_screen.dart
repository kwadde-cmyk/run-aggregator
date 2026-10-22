import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'exercise_detail_screen.dart';

class CompareScreen extends StatelessWidget {
  final List<Map<String, dynamic>> exercises;

  const CompareScreen({super.key, required this.exercises});

  double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final paceValues = <double>[];
    final hrValues = <double>[];
    final labels = <String>[];

    for (final item in exercises) {
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};

      final start = interval['startTime'] as String? ?? '';
      final startDt = DateTime.tryParse(start);
      labels.add(startDt != null ? '${startDt.day}.${startDt.month}.' : '?');

      final pace = _toDouble(metrics['averagePaceSecondsPerMeter']);
      paceValues.add(pace != null ? pace * 1000 / 60 : 0);

      final hr = _toDouble(metrics['averageHeartRateBeatsPerMinute']);
      hrValues.add(hr ?? 0);
    }

    return Scaffold(
      appBar: AppBar(title: Text('Vergleich (${exercises.length})')),
      body: ListView(
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
                DataColumn(label: Text('Kalorien')),
              ],
              rows: exercises.asMap().entries.map((entry) {
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
                    DataCell(Text(calStr)),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 24),
          Text('Durchschn. Pace', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                barGroups: List.generate(paceValues.length, (i) {
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: paceValues[i],
                        color: Colors.blue,
                        width: 16,
                        borderRadius: BorderRadius.zero,
                      ),
                    ],
                  );
                }),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) => Text(labels[v.toInt()], style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (v, _) => Text(v.toStringAsFixed(1), style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Durchschn. HF', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 200,
            child: BarChart(
              BarChartData(
                barGroups: List.generate(hrValues.length, (i) {
                  return BarChartGroupData(
                    x: i,
                    barRods: [
                      BarChartRodData(
                        toY: hrValues[i],
                        color: Colors.red,
                        width: 16,
                        borderRadius: BorderRadius.zero,
                      ),
                    ],
                  );
                }),
                titlesData: FlTitlesData(
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) => Text(labels[v.toInt()], style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 36,
                      getTitlesWidget: (v, _) => Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                gridData: const FlGridData(show: true),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Tipp: Datum antippen, um den Lauf zu öffnen.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

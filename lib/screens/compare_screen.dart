import 'package:flutter/material.dart';

class CompareScreen extends StatelessWidget {
  final List<Map<String, dynamic>> exercises;

  const CompareScreen({super.key, required this.exercises});

  @override
  Widget build(BuildContext context) {
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
              rows: exercises.map((item) {
                final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
                final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
                final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};

                final start = interval['startTime'] as String? ?? '';
                final startDt = DateTime.tryParse(start);
                final dateStr = startDt != null
                    ? '${startDt.day}.${startDt.month}. ${startDt.hour}:${startDt.minute.toString().padLeft(2, '0')}'
                    : start;

                final distMm = metrics['distanceMillimeters'];
                final distKm = distMm is num ? (distMm / 1000000).toStringAsFixed(2) : '-';

                final duration = exercise['activeDuration'] as String? ?? '-';

                final avgHr = metrics['averageHeartRateBeatsPerMinute'];
                final hrStr = avgHr is num ? avgHr.toStringAsFixed(0) : '-';

                final pace = metrics['averagePaceSecondsPerMeter'];
                final paceStr = pace is num ? (pace * 1000 / 60).toStringAsFixed(2) : '-';

                final cal = metrics['caloriesKcal'];
                final calStr = cal is num ? cal.toStringAsFixed(0) : '-';

                return DataRow(cells: [
                  DataCell(Text(dateStr)),
                  DataCell(Text('$distKm km')),
                  DataCell(Text(duration)),
                  DataCell(Text('$hrStr bpm')),
                  DataCell(Text('$paceStr min/km')),
                  DataCell(Text(calStr)),
                ]);
              }).toList(),
            ),
          ),
          const SizedBox(height: 24),
          Text('Tipp: Einzelne Läufe öffnen, um Route und Rohdaten-Chart zu sehen.',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

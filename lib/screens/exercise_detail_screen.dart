import 'package:flutter/material.dart';

class ExerciseDetailScreen extends StatelessWidget {
  final Map<String, dynamic> exercisePoint;

  const ExerciseDetailScreen({super.key, required this.exercisePoint});

  @override
  Widget build(BuildContext context) {
    final exercise = exercisePoint['exercise'] as Map<String, dynamic>? ?? {};
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

    final splits = (exercise['splitSummaries'] as List<dynamic>?) ?? [];

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
          Text('Zwischenzeiten / Splits', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (splits.isEmpty)
            const Text('Keine Splits vorhanden')
          else
            ...splits.asMap().entries.map((entry) {
              final i = entry.key;
              final split = entry.value as Map<String, dynamic>;
              final sStart = split['startTime'] ?? '';
              final sEnd = split['endTime'] ?? '';
              final sDuration = split['activeDuration'] ?? '';
              final sMetrics = split['metricsSummary'] as Map<String, dynamic>? ?? {};
              final sDistMm = sMetrics['distanceMillimeters'];
              final sDistKm = sDistMm != null ? (sDistMm / 1000000).toStringAsFixed(2) : '-';
              return Card(
                child: ListTile(
                  title: Text('Split ${i + 1}'),
                  subtitle: Text('$sStart → $sEnd\nDauer: $sDuration · $sDistKm km'),
                  isThreeLine: true,
                ),
              );
            }),
        ],
      ),
    );
  }
}

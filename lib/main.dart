import 'package:flutter/material.dart';

void main() {
  runApp(const RunAggregatorApp());
}

class RunAggregatorApp extends StatelessWidget {
  const RunAggregatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Run Aggregator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Run Aggregator'),
      ),
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Run Aggregator',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text('Import and analyze your running data from Google Health and Runkeeper.'),
            SizedBox(height: 8),
            Text('Features: raw data, splits, filters, weather correlations, graphs & tables.'),
            SizedBox(height: 32),
            Text('Skeleton - implementation in progress.'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // TODO: Import activity
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Import coming soon')),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

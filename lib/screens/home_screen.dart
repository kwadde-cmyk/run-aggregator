import 'package:flutter/material.dart';
import '../services/google_health_auth.dart';
import '../services/google_health_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _exercises = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadExercises();
  }

  Future<void> _loadExercises() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await GoogleHealthService.getExercises();
      setState(() {
        _exercises = data;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _logout() async {
    await GoogleHealthAuth.logout();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Run Aggregator'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadExercises,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Fehler: $_error', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadExercises,
                          child: const Text('Nochmal versuchen'),
                        ),
                      ],
                    ),
                  ),
                )
              : _exercises.isEmpty
                  ? const Center(child: Text('Keine Aktivitäten gefunden'))
                  : RefreshIndicator(
                      onRefresh: _loadExercises,
                      child: ListView.builder(
                        itemCount: _exercises.length,
                        itemBuilder: (context, index) {
                          final item = _exercises[index];
                          final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
                          final type = exercise['exerciseType'] ?? 'Unknown';
                          final name = exercise['displayName'] ?? '';
                          final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
                          final start = interval['startTime'] ?? '';
                          final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
                          final distanceMm = metrics['distanceMillimeters'];
                          final distanceKm = distanceMm != null ? (distanceMm / 1000000).toStringAsFixed(2) : '-';

                          return ListTile(
                            title: Text('$type – $name'),
                            subtitle: Text('$start · $distanceKm km'),
                            isThreeLine: false,
                          );
                        },
                      ),
                    ),
    );
  }
}

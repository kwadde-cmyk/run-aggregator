import 'package:flutter/material.dart';
import '../services/google_health_auth.dart';
import '../services/google_health_service.dart';
import '../services/runkeeper_service.dart';
import 'login_screen.dart';
import 'exercise_detail_screen.dart';
import 'runkeeper_login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _exercises = [];
  bool _loading = true;
  String? _error;
  bool _runkeeperBusy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadExercises();
    // Auto-import Runkeeper if last import is not from today
    _checkRunkeeper();
  }

  Future<void> _checkRunkeeper({bool force = false}) async {
    if (!await RunkeeperService.isLoggedIn()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bitte zuerst Runkeeper einloggen')),
        );
      }
      return;
    }
    setState(() => _runkeeperBusy = true);
    try {
      final did = await RunkeeperService.importIfNeeded(force: force);
      if (did && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Runkeeper-Daten aktualisiert')),
        );
      } else if (mounted && !force) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Runkeeper bereits heute aktualisiert')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Runkeeper-Fehler: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _runkeeperBusy = false);
    }
  }

  bool _isRunning(Map<String, dynamic> item) {
    final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
    final type = (exercise['exerciseType'] ?? '').toString().toUpperCase();
    final name = (exercise['displayName'] ?? '').toString().toLowerCase();
    return type == 'RUNNING' || name.contains('laufen') || name.contains('running');
  }

  Future<void> _loadExercises({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (forceRefresh) GoogleHealthService.clearCache();
      final data = await GoogleHealthService.getExercises(forceRefresh: forceRefresh);
      final runs = data.where(_isRunning).toList();
      setState(() {
        _exercises = runs;
        _loading = false;
      });
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('401') || msg.contains('UNAUTHENTICATED')) {
        await GoogleHealthAuth.logout();
        if (mounted) {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          );
        }
        return;
      }
      setState(() {
        _error = msg;
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

  Future<void> _openRunkeeperLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RunkeeperLoginScreen()),
    );
    if (ok == true) {
      _checkRunkeeper(force: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Run Aggregator'),
        actions: [
          if (_runkeeperBusy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.directions_run),
            tooltip: 'Runkeeper erzwingen',
            onPressed: _runkeeperBusy ? null : () => _checkRunkeeper(force: true),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Google aktualisieren',
            onPressed: () => _loadExercises(forceRefresh: true),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openRunkeeperLogin,
        icon: const Icon(Icons.login),
        label: const Text('Runkeeper'),
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
                          onPressed: () => _loadExercises(forceRefresh: true),
                          child: const Text('Nochmal versuchen'),
                        ),
                      ],
                    ),
                  ),
                )
              : _exercises.isEmpty
                  ? const Center(child: Text('Keine Läufe gefunden'))
                  : RefreshIndicator(
                      onRefresh: () => _loadExercises(forceRefresh: true),
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
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ExerciseDetailScreen(exercisePoint: item),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
    );
  }
}

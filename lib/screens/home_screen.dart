import 'package:flutter/material.dart';
import '../services/google_health_auth.dart';
import '../services/google_health_service.dart';
import '../services/runkeeper_service.dart';
import 'login_screen.dart';
import 'exercise_detail_screen.dart';
import 'runkeeper_login_screen.dart';
import 'compare_screen.dart';

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

  // Filters
  int? _weekday; // 1=Mon ... 7=Sun
  double? _minDistKm;
  double? _maxDistKm;
  double? _minAvgHr;
  double? _maxAvgHr;
  double? _minPace; // min/km
  double? _maxPace;

  // Multi-select for comparison
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadExercises();
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
        _selected.clear();
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

  List<Map<String, dynamic>> get _filtered {
    return _exercises.where((item) {
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};

      final startStr = interval['startTime'] as String? ?? '';
      final start = DateTime.tryParse(startStr);
      if (_weekday != null && start != null && start.weekday != _weekday) return false;

      final distMm = metrics['distanceMillimeters'];
      final distKm = distMm is num ? distMm / 1000000.0 : null;
      if (_minDistKm != null && (distKm == null || distKm < _minDistKm!)) return false;
      if (_maxDistKm != null && (distKm == null || distKm > _maxDistKm!)) return false;

      final avgHr = metrics['averageHeartRateBeatsPerMinute'];
      final hr = avgHr is num ? avgHr.toDouble() : null;
      if (_minAvgHr != null && (hr == null || hr < _minAvgHr!)) return false;
      if (_maxAvgHr != null && (hr == null || hr > _maxAvgHr!)) return false;

      final paceSecPerM = metrics['averagePaceSecondsPerMeter'];
      final paceMinKm = paceSecPerM is num ? paceSecPerM * 1000 / 60 : null;
      if (_minPace != null && (paceMinKm == null || paceMinKm < _minPace!)) return false;
      if (_maxPace != null && (paceMinKm == null || paceMinKm > _maxPace!)) return false;

      return true;
    }).toList();
  }

  void _openFilters() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _FilterSheet(
        weekday: _weekday,
        minDist: _minDistKm,
        maxDist: _maxDistKm,
        minHr: _minAvgHr,
        maxHr: _maxAvgHr,
        minPace: _minPace,
        maxPace: _maxPace,
        onApply: (w, minD, maxD, minH, maxH, minP, maxP) {
          setState(() {
            _weekday = w;
            _minDistKm = minD;
            _maxDistKm = maxD;
            _minAvgHr = minH;
            _maxAvgHr = maxH;
            _minPace = minP;
            _maxPace = maxP;
            _selected.clear();
          });
        },
      ),
    );
  }

  void _compare() {
    final selected = _filtered.asMap().entries
        .where((e) => _selected.contains(e.key))
        .map((e) => e.value)
        .toList();
    if (selected.length < 2) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CompareScreen(exercises: selected)),
    );
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
    final filtered = _filtered;
    final hasFilters = _weekday != null || _minDistKm != null || _maxDistKm != null ||
        _minAvgHr != null || _maxAvgHr != null || _minPace != null || _maxPace != null;

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
            icon: Icon(Icons.filter_list, color: hasFilters ? Colors.blue : null),
            tooltip: 'Filter',
            onPressed: _openFilters,
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
      floatingActionButton: _selected.length >= 2
          ? FloatingActionButton.extended(
              onPressed: _compare,
              icon: const Icon(Icons.compare_arrows),
              label: Text('Vergleichen (${_selected.length})'),
            )
          : FloatingActionButton.extended(
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
              : filtered.isEmpty
                  ? Center(child: Text(hasFilters ? 'Keine Läufe passen zu den Filtern' : 'Keine Läufe gefunden'))
                  : RefreshIndicator(
                      onRefresh: () => _loadExercises(forceRefresh: true),
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final item = filtered[index];
                          final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
                          final type = exercise['exerciseType'] ?? 'Unknown';
                          final name = exercise['displayName'] ?? '';
                          final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
                          final start = interval['startTime'] ?? '';
                          final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
                          final distanceMm = metrics['distanceMillimeters'];
                          final distanceKm = distanceMm != null ? (distanceMm / 1000000).toStringAsFixed(2) : '-';
                          final selected = _selected.contains(index);

                          return ListTile(
                            leading: Checkbox(
                              value: selected,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(index);
                                  } else {
                                    _selected.remove(index);
                                  }
                                });
                              },
                            ),
                            title: Text('$type – $name'),
                            subtitle: Text('$start · $distanceKm km'),
                            selected: selected,
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

class _FilterSheet extends StatefulWidget {
  final int? weekday;
  final double? minDist, maxDist, minHr, maxHr, minPace, maxPace;
  final void Function(int?, double?, double?, double?, double?, double?, double?) onApply;

  const _FilterSheet({
    required this.weekday,
    required this.minDist,
    required this.maxDist,
    required this.minHr,
    required this.maxHr,
    required this.minPace,
    required this.maxPace,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late int? _weekday;
  late final TextEditingController _minDist, _maxDist, _minHr, _maxHr, _minPace, _maxPace;

  @override
  void initState() {
    super.initState();
    _weekday = widget.weekday;
    _minDist = TextEditingController(text: widget.minDist?.toString() ?? '');
    _maxDist = TextEditingController(text: widget.maxDist?.toString() ?? '');
    _minHr = TextEditingController(text: widget.minHr?.toString() ?? '');
    _maxHr = TextEditingController(text: widget.maxHr?.toString() ?? '');
    _minPace = TextEditingController(text: widget.minPace?.toString() ?? '');
    _maxPace = TextEditingController(text: widget.maxPace?.toString() ?? '');
  }

  @override
  void dispose() {
    _minDist.dispose();
    _maxDist.dispose();
    _minHr.dispose();
    _maxHr.dispose();
    _minPace.dispose();
    _maxPace.dispose();
    super.dispose();
  }

  double? _parse(String s) => s.isEmpty ? null : double.tryParse(s.replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        left: 16, right: 16, top: 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filter', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('Wochentag'),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Alle'),
                  selected: _weekday == null,
                  onSelected: (_) => setState(() => _weekday = null),
                ),
                for (var i = 0; i < 7; i++)
                  ChoiceChip(
                    label: Text(days[i]),
                    selected: _weekday == i + 1,
                    onSelected: (_) => setState(() => _weekday = i + 1),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: TextField(controller: _minDist, decoration: const InputDecoration(labelText: 'Distanz min (km)'), keyboardType: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _maxDist, decoration: const InputDecoration(labelText: 'max'), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _minHr, decoration: const InputDecoration(labelText: 'HF min (bpm)'), keyboardType: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _maxHr, decoration: const InputDecoration(labelText: 'max'), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _minPace, decoration: const InputDecoration(labelText: 'Pace min (min/km)'), keyboardType: TextInputType.number)),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _maxPace, decoration: const InputDecoration(labelText: 'max'), keyboardType: TextInputType.number)),
            ]),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _weekday = null;
                      _minDist.clear(); _maxDist.clear();
                      _minHr.clear(); _maxHr.clear();
                      _minPace.clear(); _maxPace.clear();
                    });
                  },
                  child: const Text('Zurücksetzen'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    widget.onApply(
                      _weekday,
                      _parse(_minDist.text),
                      _parse(_maxDist.text),
                      _parse(_minHr.text),
                      _parse(_maxHr.text),
                      _parse(_minPace.text),
                      _parse(_maxPace.text),
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Anwenden'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

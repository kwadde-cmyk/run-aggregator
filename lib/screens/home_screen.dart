import 'package:flutter/material.dart';
import '../format/run_format.dart';
import '../services/google_health_auth.dart';
import '../services/google_health_service.dart';
import '../services/runkeeper_service.dart';
import '../services/weather_service.dart';
import '../theme/app_theme.dart';
import '../widgets/run_widgets.dart';
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
  final Map<String, double?> _temperatures = {};
  bool _loading = true;
  String? _error;
  bool _runkeeperBusy = false;
  int _section = 0;

  // Filters
  int? _weekday;
  double? _minDistKm;
  double? _maxDistKm;
  double? _minAvgHr;
  double? _maxAvgHr;
  double? _minPace;
  double? _maxPace;
  double? _minTemp;
  double? _maxTemp;

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
      // Load temperatures in background
      _loadTemperatures(runs);
    } catch (e) {
      final msg = e.toString();
      if (googleHealthErrorRequiresLogin(e)) {
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

  Future<void> _loadTemperatures(List<Map<String, dynamic>> runs) async {
    for (final item in runs) {
      final name = item['name'] as String? ?? '';
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final start = interval['startTime'] as String? ?? '';
      if (name.isEmpty || start.isEmpty) continue;
      if (_temperatures.containsKey(name)) continue;

      final temp = await WeatherService.getTemperatureForExercise(
        exerciseName: name,
        startTimeIso: start,
      );
      if (mounted) {
        setState(() => _temperatures[name] = temp);
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    return _exercises.where((item) {
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
      final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
      final name = item['name'] as String? ?? '';

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

      final temp = _temperatures[name];
      if (_minTemp != null && (temp == null || temp < _minTemp!)) return false;
      if (_maxTemp != null && (temp == null || temp > _maxTemp!)) return false;

      return true;
    }).toList();
  }

  bool get _hasFilters =>
      _weekday != null ||
      _minDistKm != null ||
      _maxDistKm != null ||
      _minAvgHr != null ||
      _maxAvgHr != null ||
      _minPace != null ||
      _maxPace != null ||
      _minTemp != null ||
      _maxTemp != null;

  void _clearFilters() {
    setState(() {
      _weekday = null;
      _minDistKm = null;
      _maxDistKm = null;
      _minAvgHr = null;
      _maxAvgHr = null;
      _minPace = null;
      _maxPace = null;
      _minTemp = null;
      _maxTemp = null;
      _selected.clear();
    });
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
    final wide = MediaQuery.sizeOf(context).width >= AppSpacing.wideBreakpoint;
    final body = _sectionBody();
    if (!wide) {
      return Scaffold(
        appBar: _appBar(),
        body: body,
        floatingActionButton: _section == 0 ? _fab() : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _section,
          onDestinationSelected: (index) => setState(() => _section = index),
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.directions_run_outlined),
              selectedIcon: Icon(Icons.directions_run),
              label: 'Läufe',
            ),
            NavigationDestination(
              icon: _filterIcon(selected: false),
              selectedIcon: _filterIcon(selected: true),
              label: 'Filter',
            ),
            const NavigationDestination(
              icon: Icon(Icons.more_horiz),
              selectedIcon: Icon(Icons.more_horiz),
              label: 'Mehr',
            ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section,
            onDestinationSelected: (index) => setState(() => _section = index),
            labelType: NavigationRailLabelType.all,
            groupAlignment: -0.85,
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.directions_run_outlined),
                selectedIcon: Icon(Icons.directions_run),
                label: Text('Läufe'),
              ),
              NavigationRailDestination(
                icon: _filterIcon(selected: false),
                selectedIcon: _filterIcon(selected: true),
                label: const Text('Filter'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.more_horiz),
                selectedIcon: Icon(Icons.more_horiz),
                label: Text('Mehr'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Scaffold(
              appBar: _appBar(),
              body: body,
              floatingActionButton: _section == 0 ? _fab() : null,
            ),
          ),
        ],
      ),
    );
  }

  AppBar _appBar() {
    const titles = ['Run Aggregator', 'Filter', 'Mehr'];
    return AppBar(
      title: Text(titles[_section]),
      actions: [
        if (_section == 0 && _runkeeperBusy)
          const Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_section == 0)
          IconButton(
            tooltip: 'Google aktualisieren',
            onPressed: () => _loadExercises(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
      ],
    );
  }

  Widget _filterIcon({required bool selected}) {
    return Badge(
      isLabelVisible: _hasFilters,
      smallSize: 8,
      child: Icon(selected ? Icons.tune : Icons.tune_outlined),
    );
  }

  Widget? _fab() {
    if (_selected.length >= 2) {
      return FloatingActionButton.extended(
        onPressed: _compare,
        icon: const Icon(Icons.compare_arrows),
        label: Text('Vergleichen (${_selected.length})'),
      );
    }
    return FloatingActionButton.extended(
      onPressed: _openRunkeeperLogin,
      icon: const Icon(Icons.login),
      label: const Text('Runkeeper'),
    );
  }

  Widget _sectionBody() {
    return switch (_section) {
      1 => _FilterSheet(
          weekday: _weekday,
          minDist: _minDistKm,
          maxDist: _maxDistKm,
          minHr: _minAvgHr,
          maxHr: _maxAvgHr,
          minPace: _minPace,
          maxPace: _maxPace,
          minTemp: _minTemp,
          maxTemp: _maxTemp,
          onApply: (w, minD, maxD, minH, maxH, minP, maxP, minT, maxT) {
            setState(() {
              _weekday = w;
              _minDistKm = minD;
              _maxDistKm = maxD;
              _minAvgHr = minH;
              _maxAvgHr = maxH;
              _minPace = minP;
              _maxPace = maxP;
              _minTemp = minT;
              _maxTemp = maxT;
              _selected.clear();
              _section = 0;
            });
          },
        ),
      2 => _MorePage(
          runkeeperBusy: _runkeeperBusy,
          onRefresh: () => _loadExercises(forceRefresh: true),
          onRunkeeperLogin: _openRunkeeperLogin,
          onRunkeeperSync: _runkeeperBusy ? null : () => _checkRunkeeper(force: true),
          onLogout: _logout,
        ),
      _ => _runList(),
    };
  }

  Widget _runList() {
    if (_loading) {
      return const LoadingState(message: 'Läufe werden geladen');
    }
    if (_error != null) {
      return ErrorState(
        message: _error!,
        onRetry: () => _loadExercises(forceRefresh: true),
      );
    }

    final filtered = _filtered;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
        child: RefreshIndicator(
          onRefresh: () => _loadExercises(forceRefresh: true),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              if (filtered.isNotEmpty) SliverToBoxAdapter(child: _summary(filtered)),
              if (_hasFilters) SliverToBoxAdapter(child: _filterBanner()),
              if (_selected.isNotEmpty) SliverToBoxAdapter(child: _selectionBanner()),
              if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: _hasFilters ? Icons.filter_alt_off : Icons.directions_run,
                    title: _hasFilters ? 'Keine Läufe passen zu den Filtern' : 'Keine Läufe gefunden',
                    message: _hasFilters
                        ? 'Passe die Filter an oder setze sie zurück.'
                        : 'Ziehe zum Aktualisieren oder melde Runkeeper an.',
                    action: _hasFilters
                        ? FilledButton.tonal(
                            onPressed: _clearFilters,
                            child: const Text('Filter zurücksetzen'),
                          )
                        : null,
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 112),
                  sliver: SliverList.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (context, index) => const SizedBox(height: AppSpacing.md),
                    itemBuilder: (context, index) => _runCard(filtered[index], index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary(List<Map<String, dynamic>> filtered) {
    double totalKm = 0;
    double paceWeighted = 0;
    double paceWeight = 0;
    var totalSec = 0;
    for (final item in filtered) {
      final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
      final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
      final distMm = metrics['distanceMillimeters'];
      final km = distMm is num ? distMm / 1000000.0 : null;
      if (km != null) totalKm += km;
      final paceSec = metrics['averagePaceSecondsPerMeter'];
      if (paceSec is num && km != null && paceSec > 0 && km > 0) {
        paceWeighted += (paceSec * 1000 / 60) * km;
        paceWeight += km;
      }
      final seconds = durationSecondsOf(exercise['activeDuration'] as String?);
      if (seconds != null) totalSec += seconds.round();
    }
    final avgPace = paceWeight > 0 ? paceWeighted / paceWeight : null;
    final countLabel = filtered.length == 1 ? '1 Lauf' : '${filtered.length} Läufe';

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(countLabel, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  RunStat(value: formatKm(totalKm), unit: 'km', label: 'Distanz'),
                  RunStat(value: formatPace(avgPace), unit: '/km', label: 'Ø Pace'),
                  RunStat(value: formatClock(totalSec), label: 'Zeit'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.sm, AppSpacing.sm),
      child: Row(
        children: [
          Icon(Icons.filter_alt, size: 18, color: scheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              _filterLabel(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(onPressed: _clearFilters, child: const Text('Zurücksetzen')),
        ],
      ),
    );
  }

  String _filterLabel() {
    final parts = <String>[];
    const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    if (_weekday != null) parts.add(days[_weekday! - 1]);
    if (_minDistKm != null || _maxDistKm != null) {
      parts.add('${_minDistKm ?? '–'}–${_maxDistKm ?? '–'} km');
    }
    if (_minAvgHr != null || _maxAvgHr != null) {
      parts.add('${_minAvgHr?.toStringAsFixed(0) ?? '–'}–${_maxAvgHr?.toStringAsFixed(0) ?? '–'} bpm');
    }
    if (_minPace != null || _maxPace != null) {
      parts.add('Pace ${_minPace ?? '–'}–${_maxPace ?? '–'}');
    }
    if (_minTemp != null || _maxTemp != null) {
      parts.add('${_minTemp ?? '–'}–${_maxTemp ?? '–'}°C');
    }
    return parts.join(' · ');
  }

  Widget _selectionBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.sm, AppSpacing.xs),
      child: Row(
        children: [
          Text(
            '${_selected.length} ausgewählt',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(_selected.clear),
            child: const Text('Aufheben'),
          ),
        ],
      ),
    );
  }

  Widget _runCard(Map<String, dynamic> item, int index) {
    final exercise = item['exercise'] as Map<String, dynamic>? ?? {};
    final type = (exercise['exerciseType'] ?? '').toString();
    final name = (exercise['displayName'] ?? '').toString();
    final interval = exercise['interval'] as Map<String, dynamic>? ?? {};
    final start = interval['startTime'] as String? ?? '';
    final metrics = exercise['metricsSummary'] as Map<String, dynamic>? ?? {};
    final distance = formatKmFromMillimeters(metrics['distanceMillimeters'] as num?);
    final paceSec = metrics['averagePaceSecondsPerMeter'];
    final pace = formatPace(paceSec is num ? paceSec * 1000 / 60 : null);
    final duration = formatDurationRaw(exercise['activeDuration'] as String?);
    final selected = _selected.contains(index);
    final exName = item['name'] as String? ?? '';
    final temp = _temperatures[exName];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final title = name.trim().isEmpty ? activityTypeLabel(type) : name;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radius),
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ExerciseDetailScreen(exercisePoint: item),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          _selected.add(index);
                        } else {
                          _selected.remove(index);
                        }
                      });
                    },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          formatRunTimestamp(start),
                          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$title · ${activityTypeLabel(type)}',
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (temp != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${temp.toStringAsFixed(0)}°C',
                        style: text.labelLarge?.copyWith(color: scheme.onSecondaryContainer),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.only(left: AppSpacing.md),
                child: Row(
                  children: [
                    RunStat(value: distance, unit: 'km', label: 'Distanz'),
                    RunStat(value: pace, unit: '/km', label: 'Pace'),
                    RunStat(value: duration, label: 'Zeit'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MorePage extends StatelessWidget {
  const _MorePage({
    required this.runkeeperBusy,
    required this.onRefresh,
    required this.onRunkeeperLogin,
    required this.onRunkeeperSync,
    required this.onLogout,
  });

  final bool runkeeperBusy;
  final VoidCallback onRefresh;
  final VoidCallback onRunkeeperLogin;
  final VoidCallback? onRunkeeperSync;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              'Darstellung',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Dunkel ist voreingestellt. Die Wahl bleibt auf diesem Gerät gespeichert.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.md),
            ListenableBuilder(
              listenable: AppThemeController.instance,
              builder: (context, _) {
                return SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ],
                  selected: {AppThemeController.instance.mode},
                  onSelectionChanged: (selection) {
                    AppThemeController.instance.setMode(selection.first);
                  },
                );
              },
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Daten',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Google aktualisieren'),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.tonalIcon(
              onPressed: onRunkeeperLogin,
              icon: const Icon(Icons.login),
              label: const Text('Runkeeper einloggen'),
            ),
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: onRunkeeperSync,
              icon: runkeeperBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.directions_run),
              label: const Text('Runkeeper jetzt holen'),
            ),
            const SizedBox(height: AppSpacing.xxl),
            OutlinedButton.icon(
              onPressed: onLogout,
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              icon: const Icon(Icons.logout),
              label: const Text('Abmelden'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  final int? weekday;
  final double? minDist, maxDist, minHr, maxHr, minPace, maxPace, minTemp, maxTemp;
  final void Function(int?, double?, double?, double?, double?, double?, double?, double?, double?) onApply;

  const _FilterSheet({
    required this.weekday,
    required this.minDist,
    required this.maxDist,
    required this.minHr,
    required this.maxHr,
    required this.minPace,
    required this.maxPace,
    required this.minTemp,
    required this.maxTemp,
    required this.onApply,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late int? _weekday;
  late final TextEditingController _minDist, _maxDist, _minHr, _maxHr, _minPace, _maxPace, _minTemp, _maxTemp;

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
    _minTemp = TextEditingController(text: widget.minTemp?.toString() ?? '');
    _maxTemp = TextEditingController(text: widget.maxTemp?.toString() ?? '');
  }

  @override
  void dispose() {
    _minDist.dispose();
    _maxDist.dispose();
    _minHr.dispose();
    _maxHr.dispose();
    _minPace.dispose();
    _maxPace.dispose();
    _minTemp.dispose();
    _maxTemp.dispose();
    super.dispose();
  }

  double? _parse(String s) => s.isEmpty ? null : double.tryParse(s.replaceAll(',', '.'));

  @override
  Widget build(BuildContext context) {
    const days = ['Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: AppSpacing.contentMaxWidth),
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  Text(
                    'Die Liste zeigt nur Läufe, die alle Angaben erfüllen.',
                    style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text('Wochentag', style: text.titleSmall),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
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
                  const SizedBox(height: AppSpacing.lg),
                  _rangeRow('Distanz (km)', _minDist, _maxDist, 'min', 'max'),
                  const SizedBox(height: AppSpacing.md),
                  _rangeRow('Herzfrequenz (bpm)', _minHr, _maxHr, 'min', 'max'),
                  const SizedBox(height: AppSpacing.md),
                  _rangeRow('Pace (min/km)', _minPace, _maxPace, 'min', 'max'),
                  const SizedBox(height: AppSpacing.md),
                  _rangeRow('Temperatur (°C)', _minTemp, _maxTemp, 'min', 'max'),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _weekday = null;
                        _minDist.clear();
                        _maxDist.clear();
                        _minHr.clear();
                        _maxHr.clear();
                        _minPace.clear();
                        _maxPace.clear();
                        _minTemp.clear();
                        _maxTemp.clear();
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
                        _parse(_minTemp.text),
                        _parse(_maxTemp.text),
                      );
                    },
                    child: const Text('Anwenden'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rangeRow(String label, TextEditingController min, TextEditingController max, String minLabel, String maxLabel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: min,
                decoration: InputDecoration(labelText: minLabel),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: TextField(
                controller: max,
                decoration: InputDecoration(labelText: maxLabel),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

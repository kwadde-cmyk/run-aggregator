import '../db/run_repository.dart';
import 'exercise_page.dart';
import 'google_health_service.dart';
import 'rate_limit.dart';
import 'run_points.dart';
import 'run_sync.dart';
import 'split_snapshot.dart';

/// Exercise pages from the Google Health endpoint the app already uses.
class GoogleExercisePageSource implements ExercisePageSource {
  @override
  Future<ExercisePage> fetchPage({String? pageToken, DateTime? since}) {
    return GoogleHealthService.fetchExercisePage(pageToken: pageToken, since: since);
  }
}

/// Heart rate, distance, GPS route, and 1 km splits for one run.
class GoogleRunDetailFetcher implements RunDetailFetcher {
  @override
  Future<RunDetailPayload> fetch(Map<String, dynamic> run) async {
    final start = exerciseStartIso(run);
    final end = exerciseEndIso(run);
    final name = run['name']?.toString() ?? '';
    var heartRate = <Map<String, dynamic>>[];
    var distance = <Map<String, dynamic>>[];
    var route = <Map<String, dynamic>>[];
    if (start != null && end != null) {
      heartRate = await GoogleHealthService.getHeartRatePoints(
        startTime: start,
        endTime: end,
        forceRefresh: true,
      );
      distance = await GoogleHealthService.getDistancePoints(
        startTime: start,
        endTime: end,
        forceRefresh: true,
      );
    }
    if (name.isNotEmpty) {
      try {
        route = await GoogleHealthService.getExerciseRoute(name, forceRefresh: true);
      } on RateLimited {
        rethrow;
      } catch (error) {
        if (error.toString().contains('UNAUTHENTICATED')) rethrow;
      }
    }
    return RunDetailPayload(
      heartRate: heartRate,
      distance: distance,
      route: route,
      splits: computeKmSplits(distance, 1),
      heartRateSource: 'google_health',
    );
  }
}

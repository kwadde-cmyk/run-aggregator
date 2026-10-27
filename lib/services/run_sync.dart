import '../db/run_repository.dart';
import 'exercise_page.dart';
import 'rate_limit.dart';
import 'run_points.dart';

/// Loads one page of exercises. [since] is the inclusive lower bound.
abstract class ExercisePageSource {
  Future<ExercisePage> fetchPage({String? pageToken, DateTime? since});
}

/// Loads heart rate, distance, route, and splits for one stored run.
abstract class RunDetailFetcher {
  Future<RunDetailPayload> fetch(Map<String, dynamic> run);
}

class ImportProgress {
  const ImportProgress({
    required this.since,
    required this.pagesDone,
    required this.runsStored,
    required this.detailsDone,
    required this.paging,
    required this.paused,
    required this.done,
    this.reached,
    this.message,
  });

  final DateTime since;
  final int pagesDone;
  final int runsStored;
  final int detailsDone;
  final bool paging;
  final bool paused;
  final bool done;
  final DateTime? reached;
  final String? message;

  String get statusLine {
    final date = formatGermanDate(since);
    final runs = runsStored == 1 ? '1 Lauf' : '$runsStored Läufe';
    final extra = (message == null || message!.isEmpty) ? '' : ' $message';
    if (done) {
      return 'Fertig seit $date · $runs gespeichert';
    }
    if (paused) {
      return 'Pausiert seit $date · Seite $pagesDone · $runs.$extra';
    }
    if (paging) {
      final back = reached == null ? '' : ' · zurück bis ${formatGermanDate(reached!)}';
      return 'Seite $pagesDone · $runs$back';
    }
    return 'Details · $detailsDone geladen · $runs seit $date';
  }
}

typedef WaitFor = Future<void> Function(Duration duration);
typedef BackoffFor = Duration Function(int attempt, Duration? retryAfter);

/// Historical import and incremental sync on top of [RunRepository].
class RunSync {
  RunSync({
    required this.repository,
    required this.source,
    required this.details,
    this.maxAttempts = 5,
    this.maxDetailAttempts = 3,
    this.betweenPages = Duration.zero,
    this.backoff = rateLimitBackoff,
    this.wait = _defaultWait,
  });

  final RunRepository repository;
  final ExercisePageSource source;
  final RunDetailFetcher details;
  final int maxAttempts;
  final int maxDetailAttempts;
  final Duration betweenPages;
  final BackoffFor backoff;
  final WaitFor wait;

  /// Fetches runs at or after the stored watermark and upserts them by id.
  ///
  /// Google Health lists newest first, so paging stops once a page overlaps
  /// the previous watermark. A checkpoint keeps that anchor until detail data
  /// for the new runs is stored, so a pause cannot skip the gap.
  Future<List<Map<String, dynamic>>> syncIncremental({
    bool Function()? isCancelled,
  }) async {
    final watermark = await repository.latestStart();
    if (watermark == null) return const [];

    final existing = await repository.incrementalCheckpoint();
    final anchor = existing?.anchor ?? watermark;
    var pageToken = existing?.pageToken;
    var pagingComplete = existing?.pagingComplete ?? false;
    final collected = <Map<String, dynamic>>[];
    var pages = 0;
    const safetyCap = 2000;

    try {
      while (!pagingComplete && pages < safetyCap) {
        if (isCancelled?.call() == true) {
          await repository.saveIncrementalCheckpoint(
            IncrementalCheckpoint(anchor: anchor, pageToken: pageToken),
          );
          return collected;
        }
        final page = await _withBackoff(
          () => source.fetchPage(pageToken: pageToken, since: anchor),
        );
        final batch = <Map<String, dynamic>>[];
        var overlapped = false;
        for (final point in page.points) {
          if (!isRunningExercise(point)) continue;
          final start = exerciseStart(point);
          if (start == null) continue;
          if (start.isBefore(anchor)) {
            overlapped = true;
            continue;
          }
          batch.add(point);
        }
        if (batch.isNotEmpty) {
          await repository.upsertRuns(batch);
          collected.addAll(batch);
        }
        pages++;
        final next = page.nextPageToken;
        final stop = overlapped || next == null || next.isEmpty || next == pageToken;
        if (stop) {
          pagingComplete = true;
          pageToken = null;
        } else {
          pageToken = next;
        }
        await repository.saveIncrementalCheckpoint(
          IncrementalCheckpoint(
            anchor: anchor,
            pageToken: pageToken,
            pagingComplete: pagingComplete,
          ),
        );
        if (!pagingComplete && betweenPages > Duration.zero) await wait(betweenPages);
      }
    } on RateLimited {
      await repository.saveIncrementalCheckpoint(
        IncrementalCheckpoint(anchor: anchor, pageToken: pageToken, pagingComplete: pagingComplete),
      );
      rethrow;
    }

    if (!pagingComplete) {
      await repository.saveIncrementalCheckpoint(
        IncrementalCheckpoint(anchor: anchor, pageToken: pageToken),
      );
      return collected;
    }

    await _fetchDetailsSince(anchor, isCancelled: isCancelled);
    if (isCancelled?.call() == true) return collected;
    await repository.clearIncrementalCheckpoint();
    return collected;
  }

  /// One-shot import of every run on or after [since]. The same id is updated,
  /// not inserted twice. A saved page token is continued after a pause.
  Future<ImportProgress> importSince(
    DateTime since, {
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final day = DateTime(since.year, since.month, since.day);
    final existing = await repository.importCursor();
    ImportCursor cursor;
    if (existing == null || !sameCalendarDay(existing.since, day)) {
      cursor = ImportCursor(
        since: day,
        pageToken: null,
        pagingComplete: false,
        done: false,
        pagesDone: 0,
        runsStored: await repository.countRuns(),
      );
      await repository.saveImportCursor(cursor);
    } else if (existing.done) {
      final finished = _progress(existing, paging: false, paused: false, done: true);
      onProgress?.call(finished);
      return finished;
    } else {
      cursor = existing;
    }

    try {
      if (!cursor.pagingComplete) {
        final paging = await _importPages(
          cursor,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
        cursor = paging.cursor;
        if (paging.paused) {
          final progress = _progress(
            cursor,
            paging: false,
            paused: true,
            done: false,
            message: 'Import kann später fortgesetzt werden.',
          );
          onProgress?.call(progress);
          return progress;
        }
      }

      final detailsProgress = await _importDetails(
        cursor,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );
      onProgress?.call(detailsProgress);
      return detailsProgress;
    } on RateLimited catch (error) {
      final current = await repository.importCursor() ?? cursor;
      final waitFor = error.retryAfter;
      final hint = waitFor == null
          ? 'Google Health begrenzt gerade die Anfragen.'
          : 'Google Health begrenzt die Anfragen für ${waitFor.inSeconds}s.';
      final progress = _progress(
        current,
        paging: false,
        paused: true,
        done: false,
        message: hint,
      );
      onProgress?.call(progress);
      return progress;
    }
  }

  Future<_PagingOutcome> _importPages(
    ImportCursor start, {
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    var cursor = start;
    var pageToken = start.pageToken;
    while (cursor.pagesDone < 2000) {
      if (isCancelled?.call() == true) {
        cursor = cursor.copyWith(pageToken: pageToken, pagingComplete: false, done: false);
        await repository.saveImportCursor(cursor);
        return _PagingOutcome(cursor: cursor, paused: true);
      }
      final page = await _withBackoff(
        () => source.fetchPage(pageToken: pageToken, since: cursor.since),
      );
      final batch = <Map<String, dynamic>>[];
      DateTime? oldest;
      for (final point in page.points) {
        if (!isRunningExercise(point)) continue;
        final startTime = exerciseStart(point);
        if (startTime == null || !isOnOrAfterDay(startTime, cursor.since)) continue;
        batch.add(point);
        if (oldest == null || startTime.isBefore(oldest)) oldest = startTime;
      }
      if (batch.isNotEmpty) {
        await repository.upsertRuns(batch);
      }
      final next = page.nextPageToken;
      final complete = next == null || next.isEmpty || next == pageToken;
      cursor = ImportCursor(
        since: cursor.since,
        pageToken: complete ? null : next,
        pagingComplete: complete,
        done: false,
        pagesDone: cursor.pagesDone + 1,
        runsStored: await repository.countRuns(),
      );
      await repository.saveImportCursor(cursor);
      onProgress?.call(
        _progress(cursor, paging: true, paused: false, done: false, reached: oldest),
      );
      if (complete) return _PagingOutcome(cursor: cursor, paused: false);
      pageToken = next;
      if (betweenPages > Duration.zero) await wait(betweenPages);
    }
    cursor = cursor.copyWith(pageToken: pageToken, pagingComplete: false, done: false);
    await repository.saveImportCursor(cursor);
    return _PagingOutcome(cursor: cursor, paused: true);
  }

  Future<ImportProgress> _importDetails(
    ImportCursor cursor, {
    void Function(ImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final missing = await repository.runsMissingDetails(since: cursor.since);
    var doneDetails = 0;
    for (final run in missing) {
      if (isCancelled?.call() == true) {
        final paused = cursor.copyWith(
          pagingComplete: true,
          done: false,
          clearPageToken: true,
          runsStored: await repository.countRuns(),
        );
        await repository.saveImportCursor(paused);
        return _progress(
          paused,
          paging: false,
          paused: true,
          done: false,
          message: 'Details werden beim Fortsetzen weiter geladen.',
        );
      }
      final id = stableRunId(run);
      if (await repository.detailAttempts(id) >= maxDetailAttempts) {
        await repository.markDetailsSkipped(id);
        continue;
      }
      try {
        final payload = await _withBackoff(() => details.fetch(run));
        await repository.saveDetails(id, payload);
        doneDetails++;
        if (betweenPages > Duration.zero) await wait(betweenPages);
        cursor = cursor.copyWith(
          pagingComplete: true,
          done: false,
          clearPageToken: true,
          runsStored: await repository.countRuns(),
        );
        await repository.saveImportCursor(cursor);
        onProgress?.call(
          _progress(cursor, paging: false, paused: false, done: false, detailsDone: doneDetails),
        );
      } on RateLimited {
        await repository.recordDetailFailure(id);
        rethrow;
      } catch (error) {
        if (error.toString().contains('UNAUTHENTICATED')) rethrow;
        await repository.recordDetailFailure(id);
      }
    }

    final stillMissing = await repository.runsMissingDetails(since: cursor.since);
    final finished = stillMissing.isEmpty;
    final saved = cursor.copyWith(
      pagingComplete: true,
      done: finished,
      clearPageToken: true,
      runsStored: await repository.countRuns(),
    );
    await repository.saveImportCursor(saved);
    if (!finished) {
      return _progress(
        saved,
        paging: false,
        paused: true,
        done: false,
        detailsDone: doneDetails,
        message: '${stillMissing.length} Läufe ohne Details. Import fortsetzen lädt sie erneut.',
      );
    }
    return _progress(
      saved,
      paging: false,
      paused: false,
      done: true,
      detailsDone: doneDetails,
    );
  }

  Future<void> _fetchDetailsSince(
    DateTime anchor, {
    bool Function()? isCancelled,
  }) async {
    final missing = await repository.runsMissingDetails(since: anchor);
    for (final run in missing) {
      if (isCancelled?.call() == true) return;
      final start = exerciseStart(run);
      if (start == null || start.isBefore(anchor)) continue;
      final id = stableRunId(run);
      if (await repository.detailAttempts(id) >= maxDetailAttempts) {
        await repository.markDetailsSkipped(id);
        continue;
      }
      try {
        final payload = await _withBackoff(() => details.fetch(run));
        await repository.saveDetails(id, payload);
        if (betweenPages > Duration.zero) await wait(betweenPages);
      } on RateLimited {
        rethrow;
      } catch (error) {
        if (error.toString().contains('UNAUTHENTICATED')) rethrow;
        await repository.recordDetailFailure(id);
      }
    }
  }

  Future<T> _withBackoff<T>(Future<T> Function() action) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await action();
      } on RateLimited catch (error) {
        if (attempt >= maxAttempts - 1) rethrow;
        await wait(backoff(attempt, error.retryAfter));
      }
    }
  }

  ImportProgress _progress(
    ImportCursor cursor, {
    required bool paging,
    required bool paused,
    required bool done,
    DateTime? reached,
    String? message,
    int detailsDone = 0,
  }) {
    return ImportProgress(
      since: cursor.since,
      pagesDone: cursor.pagesDone,
      runsStored: cursor.runsStored,
      detailsDone: detailsDone,
      paging: paging,
      paused: paused,
      done: done,
      reached: reached,
      message: message,
    );
  }
}

class _PagingOutcome {
  const _PagingOutcome({required this.cursor, required this.paused});

  final ImportCursor cursor;
  final bool paused;
}

Future<void> _defaultWait(Duration duration) => Future<void>.delayed(duration);

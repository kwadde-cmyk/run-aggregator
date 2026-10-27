/// Google Health answered 429, 503, or 504. Callers retry with [retryAfter]
/// or [rateLimitBackoff].
class RateLimited implements Exception {
  const RateLimited({this.retryAfter});

  final Duration? retryAfter;

  @override
  String toString() {
    final wait = retryAfter;
    if (wait == null) return 'RateLimited';
    return 'RateLimited(retryAfter: ${wait.inSeconds}s)';
  }
}

bool isTransientStatus(int statusCode) {
  return statusCode == 429 || statusCode == 503 || statusCode == 504;
}

/// `Retry-After` as a number of seconds. HTTP-date values are ignored.
Duration? retryAfterFromHeader(String? header) {
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds == null || seconds <= 0) return null;
  return Duration(seconds: seconds);
}

/// Exponential backoff. A positive `Retry-After` wins, capped at [cap].
Duration rateLimitBackoff(
  int attempt,
  Duration? retryAfter, {
  Duration base = const Duration(seconds: 1),
  Duration cap = const Duration(seconds: 32),
}) {
  if (retryAfter != null && retryAfter > Duration.zero) {
    return retryAfter > cap ? cap : retryAfter;
  }
  final shift = attempt < 0 ? 0 : (attempt > 16 ? 16 : attempt);
  final millis = base.inMilliseconds * (1 << shift);
  if (millis >= cap.inMilliseconds) return cap;
  return Duration(milliseconds: millis);
}

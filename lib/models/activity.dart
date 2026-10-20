// Basic data models for running activities

class Activity {
  final String id;
  final DateTime startTime;
  final Duration duration;
  final double distanceMeters;
  final double? avgHeartRate;
  final double? avgPaceSecondsPerKm;
  final String source; // 'google_health', 'runkeeper', etc.
  final List<TrackPoint> trackPoints;
  final Map<String, dynamic>? weather; // e.g. {'temp': 15.2, 'humidity': 60}

  Activity({
    required this.id,
    required this.startTime,
    required this.duration,
    required this.distanceMeters,
    this.avgHeartRate,
    this.avgPaceSecondsPerKm,
    required this.source,
    this.trackPoints = const [],
    this.weather,
  });

  double get distanceKm => distanceMeters / 1000;
  double get paceMinPerKm => (avgPaceSecondsPerKm ?? 0) / 60;
}

class TrackPoint {
  final DateTime time;
  final double? lat;
  final double? lon;
  final double? elevation;
  final double? heartRate;
  final double? speed;

  TrackPoint({
    required this.time,
    this.lat,
    this.lon,
    this.elevation,
    this.heartRate,
    this.speed,
  });
}

// TODO: parsers for GPX, TCX, Fitbit JSON, etc.
// TODO: split calculation from trackpoints
// TODO: weather fetch using Open-Meteo based on lat/lon or default location + date

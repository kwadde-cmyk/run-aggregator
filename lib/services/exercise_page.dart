/// One page of exercise data points from a remote source.
class ExercisePage {
  const ExercisePage({required this.points, this.nextPageToken});

  final List<Map<String, dynamic>> points;
  final String? nextPageToken;
}

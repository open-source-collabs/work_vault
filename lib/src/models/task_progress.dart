/// One progress sample for a transfer.
final class TaskProgress {
  /// Creates a progress sample.
  ///
  /// [percentage] is in the range 0 to 100 when the total size is known.
  const TaskProgress({
    required this.taskId,
    required this.bytesDownloaded,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.elapsed,
    required this.percentage,
  }) : assert(bytesDownloaded >= 0, 'bytesDownloaded must be >= 0'),
       assert(totalBytes == null || totalBytes >= 0, 'totalBytes must be >= 0'),
       assert(bytesPerSecond >= 0, 'bytesPerSecond must be >= 0'),
       assert(
         percentage == null || (percentage >= 0 && percentage <= 100),
         'percentage must be null or in the range 0 to 100',
       );

  /// Task this sample belongs to.
  final String taskId;

  /// Bytes written to the destination so far.
  final int bytesDownloaded;

  /// Total bytes expected, or null when the server omitted the length.
  final int? totalBytes;

  /// Smoothed transfer speed in bytes per second.
  final double bytesPerSecond;

  /// Time since the transfer started.
  final Duration elapsed;

  /// Completion in the range 0 to 100, or null when [totalBytes] is unknown.
  final double? percentage;

  /// [percentage] expressed as a fraction from 0 to 1.
  double? get fraction => percentage == null ? null : percentage! / 100;

  @override
  bool operator ==(Object other) {
    return other is TaskProgress &&
        other.taskId == taskId &&
        other.bytesDownloaded == bytesDownloaded &&
        other.totalBytes == totalBytes &&
        other.bytesPerSecond == bytesPerSecond &&
        other.elapsed == elapsed &&
        other.percentage == percentage;
  }

  @override
  int get hashCode => Object.hash(
    taskId,
    bytesDownloaded,
    totalBytes,
    bytesPerSecond,
    elapsed,
    percentage,
  );

  @override
  String toString() {
    return 'TaskProgress($taskId, $bytesDownloaded/${totalBytes ?? '?'}, '
        '${percentage ?? '?'}%)';
  }
}

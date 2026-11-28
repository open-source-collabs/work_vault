/// Display helpers for transfer sizes, speeds, and time estimates.
library;

const List<String> _units = <String>['B', 'KB', 'MB', 'GB', 'TB'];

/// Formats [bytes] with a binary-scaled unit, for example `12.4 MB`.
String formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  double value = bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < _units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String digits = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$digits ${_units[unit]}';
}

/// Formats a transfer rate, for example `1.8 MB/s`.
String formatSpeed(double bytesPerSecond) {
  if (!bytesPerSecond.isFinite || bytesPerSecond <= 0) {
    return '0 B/s';
  }
  return '${formatBytes(bytesPerSecond.round())}/s';
}

/// Estimated time left, or null when it cannot be known.
///
/// Returns null when [totalBytes] is unknown, the speed is zero, or the
/// transfer has already reached [totalBytes].
String? formatEta({
  required int bytesDownloaded,
  required int? totalBytes,
  required double bytesPerSecond,
}) {
  if (totalBytes == null ||
      !bytesPerSecond.isFinite ||
      bytesPerSecond <= 0 ||
      bytesDownloaded >= totalBytes) {
    return null;
  }
  final int seconds = ((totalBytes - bytesDownloaded) / bytesPerSecond).ceil();
  return 'about ${formatDuration(Duration(seconds: seconds))} left';
}

/// Formats [duration] as its two most significant units, for example `2 m 5 s`.
String formatDuration(Duration duration) {
  final int hours = duration.inHours;
  final int minutes = duration.inMinutes.remainder(60);
  final int seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours h $minutes m';
  }
  if (minutes > 0) {
    return '$minutes m $seconds s';
  }
  return '$seconds s';
}

/// Delay schedule used when a transfer fails and can be retried.
final class RetryPolicy {
  /// Creates a retry policy.
  ///
  /// [maxAttempts] counts the first try. [initialBackoff] is the delay before
  /// the second try, and each later delay is multiplied by [multiplier] until
  /// it reaches [maxBackoff].
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(minutes: 5),
    this.multiplier = 2,
  });

  /// Attempts including the first try.
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialBackoff;

  /// Upper bound on a single retry delay.
  final Duration maxBackoff;

  /// Factor applied to the delay after each retry.
  final double multiplier;

  @override
  bool operator ==(Object other) {
    return other is RetryPolicy &&
        other.maxAttempts == maxAttempts &&
        other.initialBackoff == initialBackoff &&
        other.maxBackoff == maxBackoff &&
        other.multiplier == multiplier;
  }

  @override
  int get hashCode =>
      Object.hash(maxAttempts, initialBackoff, maxBackoff, multiplier);

  @override
  String toString() {
    return 'RetryPolicy(maxAttempts: $maxAttempts, initialBackoff: $initialBackoff, '
        'maxBackoff: $maxBackoff, multiplier: $multiplier)';
  }
}

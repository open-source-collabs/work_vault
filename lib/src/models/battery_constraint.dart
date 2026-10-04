/// Power conditions the scheduler must satisfy before a task runs.
///
/// Android enforces both flags. iOS treats [requiresCharging] as a request for
/// external power and treats [requiresBatteryNotLow] as advisory.
final class BatteryConstraint {
  /// Creates a battery constraint.
  const BatteryConstraint({
    this.requiresCharging = false,
    this.requiresBatteryNotLow = false,
  });

  /// The device must be on external power.
  final bool requiresCharging;

  /// The device must not be in a low-battery state.
  final bool requiresBatteryNotLow;

  @override
  bool operator ==(Object other) {
    return other is BatteryConstraint &&
        other.requiresCharging == requiresCharging &&
        other.requiresBatteryNotLow == requiresBatteryNotLow;
  }

  @override
  int get hashCode => Object.hash(requiresCharging, requiresBatteryNotLow);

  @override
  String toString() {
    return 'BatteryConstraint(requiresCharging: $requiresCharging, '
        'requiresBatteryNotLow: $requiresBatteryNotLow)';
  }
}

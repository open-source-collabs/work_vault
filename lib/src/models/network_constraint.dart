/// Which networks may carry a transfer.
enum NetworkConstraint {
  /// Any connected network, including metered cellular data.
  any,

  /// Unmetered links only, typically Wi-Fi.
  unmetered,

  /// A connected network that is not currently roaming.
  notRoaming,
}

/// Notification copy for a running transfer and its completion.
final class NotificationMetadata {
  /// Creates notification metadata.
  const NotificationMetadata({
    required this.title,
    required this.body,
    required this.channelId,
    required this.channelName,
  });

  /// Short title shown in the status notification.
  final String title;

  /// Supporting line shown under [title].
  final String body;

  /// Android notification channel id. iOS ignores this value.
  final String channelId;

  /// Android notification channel name shown in system settings.
  final String channelName;

  @override
  bool operator ==(Object other) {
    return other is NotificationMetadata &&
        other.title == title &&
        other.body == body &&
        other.channelId == channelId &&
        other.channelName == channelName;
  }

  @override
  int get hashCode => Object.hash(title, body, channelId, channelName);

  @override
  String toString() => 'NotificationMetadata($channelId, $title)';
}

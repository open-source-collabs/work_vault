import 'package:flutter/foundation.dart' show kIsWeb;

import 'battery_constraint.dart';
import 'http_method.dart';
import 'network_constraint.dart';
import 'notification_metadata.dart';
import 'retry_policy.dart';
import 'work_vault_failure.dart';

/// Description of one download.
final class WorkTaskConfig {
  /// Creates a download description.
  ///
  /// Call [validate] before enqueueing. [WorkVault.enqueue] does that itself.
  const WorkTaskConfig({
    required this.taskId,
    required this.url,
    required this.destinationPath,
    this.method = HttpMethod.get,
    this.headers = const <String, String>{},
    this.network = NetworkConstraint.any,
    this.retry = const RetryPolicy(),
    this.battery = const BatteryConstraint(),
    required this.notification,
  });

  /// Stable caller-supplied identity. A second enqueue of the same id fails.
  final String taskId;

  /// Absolute `https` URL.
  final String url;

  /// Absolute file path that receives the response body.
  final String destinationPath;

  /// Verb stored with the task. Version 1 accepts [HttpMethod.get] only.
  final HttpMethod method;

  /// Extra request headers. Hop-by-hop and control characters are rejected.
  final Map<String, String> headers;

  /// Networks that may carry the transfer.
  final NetworkConstraint network;

  /// Retry schedule for a retryable failure.
  final RetryPolicy retry;

  /// Power conditions required before the task starts.
  final BatteryConstraint battery;

  /// Notification shown for the life of the transfer.
  final NotificationMetadata notification;

  /// Throws [InvalidWorkConfig] when this description cannot be executed.
  void validate() {
    if (taskId != taskId.trim() || !_taskIdPattern.hasMatch(taskId)) {
      throw const InvalidWorkConfig(
        'taskId must contain 1 to 128 letters, digits, dots, underscores, hyphens, or colons.',
      );
    }

    final Uri? uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const InvalidWorkConfig('url must be an absolute https URL.');
    }

    if (kIsWeb) {
      if (!_isValidWebDestination(destinationPath)) {
        throw const InvalidWorkConfig(
          'destinationPath must be a valid destination name without traversal.',
        );
      }
    } else if (!_isAbsolutePath(destinationPath)) {
      throw const InvalidWorkConfig(
        'destinationPath must be an absolute file path.',
      );
    }

    if (method != HttpMethod.get) {
      throw const InvalidWorkConfig(
        'Only GET downloads are supported in this version.',
      );
    }

    for (final MapEntry<String, String> header in headers.entries) {
      if (!_headerName.hasMatch(header.key) ||
          _controlCharacters.hasMatch(header.value)) {
        throw InvalidWorkConfig(
          'Header "${header.key}" must use a token name and a value without control characters.',
        );
      }
    }

    if (retry.maxAttempts < 1) {
      throw const InvalidWorkConfig('retry.maxAttempts must be at least 1.');
    }
    if (retry.initialBackoff.isNegative ||
        retry.maxBackoff < retry.initialBackoff) {
      throw const InvalidWorkConfig(
        'retry backoff must be non-negative and maxBackoff must cover initialBackoff.',
      );
    }
    if (!retry.multiplier.isFinite || retry.multiplier < 1) {
      throw const InvalidWorkConfig(
        'retry.multiplier must be a finite number >= 1.',
      );
    }

    _validateNotification(notification);
  }

  /// Returns a copy with the given fields replaced.
  WorkTaskConfig copyWith({
    String? taskId,
    String? url,
    String? destinationPath,
    HttpMethod? method,
    Map<String, String>? headers,
    NetworkConstraint? network,
    RetryPolicy? retry,
    BatteryConstraint? battery,
    NotificationMetadata? notification,
  }) {
    return WorkTaskConfig(
      taskId: taskId ?? this.taskId,
      url: url ?? this.url,
      destinationPath: destinationPath ?? this.destinationPath,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      network: network ?? this.network,
      retry: retry ?? this.retry,
      battery: battery ?? this.battery,
      notification: notification ?? this.notification,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is WorkTaskConfig &&
        other.taskId == taskId &&
        other.url == url &&
        other.destinationPath == destinationPath &&
        other.method == method &&
        _mapsEqual(other.headers, headers) &&
        other.network == network &&
        other.retry == retry &&
        other.battery == battery &&
        other.notification == notification;
  }

  @override
  int get hashCode => Object.hash(
    taskId,
    url,
    destinationPath,
    method,
    _mapHash(headers),
    network,
    retry,
    battery,
    notification,
  );

  @override
  String toString() => 'WorkTaskConfig($taskId, $method, $url)';
}

void _validateNotification(NotificationMetadata notification) {
  _visibleText('notification.title', notification.title);
  _visibleText('notification.body', notification.body);
  if (!_channelIdPattern.hasMatch(notification.channelId)) {
    throw const InvalidWorkConfig(
      'notification.channelId must contain 1 to 128 letters, digits, dots, underscores, or hyphens.',
    );
  }
  _visibleText('notification.channelName', notification.channelName);
}

final RegExp _taskIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,128}$');
final RegExp _channelIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final RegExp _headerName = RegExp(r'^[A-Za-z0-9-]{1,128}$');
final RegExp _controlCharacters = RegExp(r'[\u0000-\u001F\u007F]');
final RegExp _windowsAbsolute = RegExp(r'^[A-Za-z]:[\\/]');

bool _isAbsolutePath(String path) {
  if (path.isEmpty || _controlCharacters.hasMatch(path)) {
    return false;
  }
  return path.startsWith('/') ||
      path.startsWith(r'\\') ||
      _windowsAbsolute.hasMatch(path);
}

bool _isValidWebDestination(String path) {
  if (path.isEmpty || _controlCharacters.hasMatch(path) || path.contains('..')) {
    return false;
  }
  return true;
}

void _visibleText(String field, String value) {
  if (value.trim().isEmpty || _controlCharacters.hasMatch(value)) {
    throw InvalidWorkConfig(
      '$field must be visible text without control characters.',
    );
  }
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final MapEntry<String, String> entry in a.entries) {
    if (b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

int _mapHash(Map<String, String> map) {
  var hash = 0;
  for (final MapEntry<String, String> entry in map.entries) {
    hash ^= Object.hash(entry.key, entry.value);
  }
  return hash;
}

/// Headers that ask the server for the bytes after [offset].
///
/// `If-Range` makes the server answer with the full body (status 200) when the
/// entity tag changed, so a stale prefix is never appended to a new file.
Map<String, String> resumeRequestHeaders(int offset, {String? eTag}) {
  if (offset <= 0) {
    return const <String, String>{};
  }
  return <String, String>{'Range': 'bytes=$offset-', 'If-Range': ?eTag};
}

/// Total entity size from a `Content-Range` value such as `bytes 10-99/100`.
///
/// Returns null when the header is missing, malformed, or the size is `*`.
int? parseContentRangeTotal(String? contentRange) {
  if (contentRange == null) {
    return null;
  }
  final int slash = contentRange.lastIndexOf('/');
  if (slash < 0) {
    return null;
  }
  return int.tryParse(contentRange.substring(slash + 1).trim());
}

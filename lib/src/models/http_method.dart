/// HTTP verb stored with a task.
///
/// Version 1 executes [HttpMethod.get] only.
enum HttpMethod {
  /// Resumable download. The only verb version 1 executes.
  get,

  /// Rejected by the native engines in version 1.
  post,

  /// Rejected by the native engines in version 1.
  put,

  /// Rejected by the native engines in version 1.
  head,
}

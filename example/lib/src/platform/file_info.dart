/// Reads facts about a downloaded file on platforms that expose a file system.
///
/// On web the browser owns the saved file, so [supportsFileInfo] is false and
/// the other functions are never called.
library;

export 'file_info_io.dart' if (dart.library.js_interop) 'file_info_web.dart';

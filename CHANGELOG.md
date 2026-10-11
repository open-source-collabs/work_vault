## 0.2.0

* Add official support for **Windows**, **Linux**, and **Web**.
* Add `DesktopWorkVaultEngine` (`dartPluginClass`) for Windows and Linux with resumable HTTP GET streaming via `Range: bytes=X-` headers, SHA-256 integrity verification, and SQLite database persistence.
* Add `WebWorkVaultEngine` (`flutter_web_plugins`) for Web with Fetch/Streams API chunk streaming, progress observation, web database persistence, SHA-256 checks, and automatic browser file download triggers.
* Implement web-safe abstractions and conditional imports across storage and file hashing layers to prevent `dart:io` compilation errors on Web.
* Scaffold native runners for Windows, Linux, and Web in the `example/` application with dynamic cross-platform destination paths.

## 0.1.0

* Support one transfer: a resumable HTTPS GET. Android runs it in WorkManager. iOS runs it in a background URLSession. Any other method is rejected.
* Keep the download running after the UI isolate is gone. A headless Flutter engine receives progress and completion and writes the SQLite projection.
* Treat the native store as the authority for status, byte count, entity tag, and resume position. `initialize` reloads that state.
* Decide `completed` or `failed` in the native checksum verifier. Dart records `verified`, `mismatch`, or `missing` and does not change that status.
* Deliver Android status and progress on the platform main thread while the UI engine is attached.

## 0.0.1

* Add the Pigeon host contract and the typed Dart control plane for background downloads.
* Deliver background events through a headless Flutter engine when the UI engine is gone, and store task rows, resume tokens, and SHA-256 status in SQLite.

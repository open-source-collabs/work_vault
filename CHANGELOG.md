## Unreleased

* Add Android tests that pin entity-tag restart, redirect limits, cleartext refusal, timeouts, and retryable HTTP statuses.
* Record a schema version in the shared SQLite file. A file written by 0.1.0 keeps its rows, and a file from a newer version is refused with a `StateError` instead of being misread.
* Fix the headless background engine reusing the first database it opened. Each dispatched event is now written to the database its payload names.
* Remove the Android TUS upload handler. Version 1 runs resumable HTTPS GET only, so native routing and validation now reject every other method, with or without upload protocol headers.
* Fix Android so an expected digest passed in `X-Work-Vault-Sha256` or `X-Work-Vault-Md5` is no longer replaced by the server's `Digest` or `Content-MD5` response header. A server digest is used only when none was supplied.
* Document expected-digest verification, including that iOS does not read these headers yet.
* Lower the Dart SDK constraint to `^3.13.0` so it matches the documented minimum of Dart 3.13 and Flutter 3.47. The previous `^3.13.4` required Flutter 3.47.7.

## 0.1.0

* Support one transfer: a resumable HTTPS GET. Android runs it in WorkManager. iOS runs it in a background URLSession. Any other method is rejected.
* Keep the download running after the UI isolate is gone. A headless Flutter engine receives progress and completion and writes the SQLite projection.
* Treat the native store as the authority for status, byte count, entity tag, and resume position. `initialize` reloads that state.
* Decide `completed` or `failed` in the native checksum verifier. Dart records `verified`, `mismatch`, or `missing` and does not change that status.
* Deliver Android status and progress on the platform main thread while the UI engine is attached.

## 0.0.1

* Add the Pigeon host contract and the typed Dart control plane for background downloads.
* Deliver background events through a headless Flutter engine when the UI engine is gone, and store task rows, resume tokens, and SHA-256 status in SQLite.

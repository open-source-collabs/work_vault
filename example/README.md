# work_vault example

A download manager built on [`work_vault`](../README.md), the way a real app
would use it.

## What it shows

| Feature | Where | API |
|---|---|---|
| Tasks restored on launch, live status for all of them | `lib/src/downloads_controller.dart` | `initialize`, `getTasks`, `watchStatus` |
| Resync on resume, pull to refresh, refresh button | `lib/src/screens/downloads_screen.dart` | `getTasks` |
| Progress with size, speed and time left | `lib/src/widgets/task_tile.dart` | `watchProgress`, `TaskProgress` |
| Pause, resume and cancel, offered only when legal | `lib/src/widgets/task_tile.dart` | `nextTaskStatus`, `pause`, `resume`, `cancel` |
| Failure code, HTTP status and retryability | `lib/src/widgets/task_tile.dart` | `TaskFailure` |
| New download with network, battery and retry options; refuses a file another active download is writing | `lib/src/widgets/new_download_sheet.dart` | `WorkTaskConfig.validate`, `enqueue` |
| Saved path, size and on-demand SHA-256 | `lib/src/widgets/completed_file_panel.dart` | (app-side) |

`DownloadsController` is the only class that talks to `WorkVault`; widgets read
from it. `TaskSnapshot` carries transfer state only, so the app keeps its own
`taskId -> destination` record (`lib/src/destination_catalog.dart`) to show a
completed file after a restart. Entries for tasks the host no longer
remembers are dropped on each resync, so the record does not grow without
bound. On web the browser owns saved files, so that record lasts for the
session and the file panel shows only the name.

## Run the app

```sh
cd example
flutter pub get
flutter run -d <android|ios|macos|windows|linux|chrome>
```

On Windows, Linux and Web the download runs only while the app is open. See
[Platform guarantees](../README.md#platform-guarantees).

## Local HTTPS fixture (Android)

`tool/fixture_server.dart` serves a payload over HTTPS with `Range` support.
The Android emulator reaches it at `https://10.0.2.2:8443`, and the debug build
trusts the self-signed certificate in `tool/certs/`. That key is a throwaway
test fixture, not a secret.

```sh
dart run tool/production_rehearsal.dart [--device=<serial>] [--port=<n>] [scenario...]
```

Without scenario names it runs them all: `controls`, `survive`, `headless`,
`reboot`, `battery`, `host-manual`, `host-provider`, `quota`. `quota` needs
Android 15 (API 35) and is skipped on older devices.

## Tests

```sh
flutter test                                              # unit and widget tests
flutter test integration_test -d <device>                 # end to end
```

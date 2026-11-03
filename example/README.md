# work_vault example

A small app that enqueues, pauses, resumes and cancels a resumable download
with [`work_vault`](../README.md), and shows live progress.

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
flutter test                                              # widget test
flutter test integration_test -d <device>                 # end to end
```

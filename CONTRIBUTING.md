# Contributing

## Setup

```sh
flutter pub get
flutter analyze
flutter test
flutter test --platform chrome test_web
```

## Before opening a PR

- `dart format .` (generated `*.g.*` files are excluded from the CI check).
- Add or update tests. Resume, ETag change, and checksum paths need a test on
  every platform you touch.
- If you change `pigeons/messages.dart`, regenerate and commit the bindings:
  `dart run pigeon --input pigeons/messages.dart `dart run pigeon --input pigeons/messages.dart`. CI fails on drift.`dart run pigeon --input pigeons/messages.dart`. CI fails on drift. dart format lib/src/gen/messages.g.dart`. Pigeon is pinned in `pubspec.yaml`; CI fails if the committed bindings drift.
- Add a CHANGELOG entry for user-visible changes.

## Platform contract

Android and iOS run downloads in the host process and survive app termination.
Windows, Linux, and Web run in the app process or tab: they resume across
restarts from persisted state but do not download while the app is closed.
Keep README claims consistent with this.

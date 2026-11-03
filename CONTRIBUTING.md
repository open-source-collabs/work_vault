# Contributing

## Setup

```sh
flutter pub get
flutter analyze
flutter test
flutter test --platform chrome test/web
```

## Before opening a PR

- `dart format .` (generated `*.g.*` files are excluded from the CI check).
- Add or update tests. Resume, ETag change, and checksum paths need a test on
  every platform you touch.
- If you change `pigeons/messages.dart`, regenerate and commit the bindings:
  `dart run pigeon --input pigeons/messages.dart`, then
  `dart format lib/src/gen/messages.g.dart`. Pigeon is pinned in
  `pubspec.yaml`; CI fails if the committed bindings drift.
- Add a CHANGELOG entry for user-visible changes.
- When bumping the version, update `pubspec.yaml`, `ios/work_vault.podspec`,
  the newest `CHANGELOG.md` heading, and the `work_vault` entry in
  `example/pubspec.lock`. `dart run tool/check_versions.dart` verifies all four
  and runs in CI.

## Releasing (maintainers)

Publishing uses pub.dev automated publishing, so no token is stored.

One-time setup on pub.dev, as a package admin: *Admin > Automated publishing >
Enable publishing from GitHub Actions*, repository
`open-source-collabs/work_vault`, tag pattern `v{{version}}`, and require the
GitHub environment `pub.dev`. Then create an environment named `pub.dev` in the
repository settings (add required reviewers if you want a manual approval).

For each release:

1. Rename `## Unreleased` in `CHANGELOG.md` to the new version heading.
2. Bump `pubspec.yaml`, `ios/work_vault.podspec`, and the `work_vault` entry in
   `example/pubspec.lock`; check with `dart run tool/check_versions.dart`.
3. Merge to `main`, then tag and push: `git tag v<version> && git push origin v<version>`.

The `Release` workflow checks that the tag equals the pubspec version, reruns
the checks, publishes to pub.dev, and creates a GitHub release from the
changelog section.

## Platform contract

Android and iOS run downloads in the host process and survive app termination.
Windows, Linux, and Web run in the app process or tab: they resume across
restarts from persisted state but do not download while the app is closed.
Keep README claims consistent with this.

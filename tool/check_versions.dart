import 'dart:io';

/// Fails when the package version differs between the files that carry it.
///
/// `pubspec.yaml` is the source of truth. Run from the repository root:
/// `dart run tool/check_versions.dart`.
void main() {
  final String expected = _match(
    'pubspec.yaml',
    RegExp(r'^version:\s*(\S+)\s*$', multiLine: true),
  );

  final Map<String, String> found = <String, String>{
    'ios/work_vault.podspec': _match(
      'ios/work_vault.podspec',
      RegExp(r"^\s*s\.version\s*=\s*'([^']+)'", multiLine: true),
    ),
    // The newest numbered heading; "Unreleased" above it is ignored.
    'CHANGELOG.md': _match(
      'CHANGELOG.md',
      RegExp(r'^##\s+(\d+\.\d+\.\d+\S*)\s*$', multiLine: true),
    ),
    'example/pubspec.lock': _lockVersion('example/pubspec.lock', 'work_vault'),
  };

  final List<String> mismatches = <String>[
    for (final MapEntry<String, String> entry in found.entries)
      if (entry.value != expected)
        '${entry.key} has ${entry.value}, expected $expected',
  ];

  if (mismatches.isEmpty) {
    stdout.writeln(
      'Version $expected is consistent in ${found.length + 1} files.',
    );
    return;
  }
  stderr.writeln('Version mismatch (pubspec.yaml is the source of truth):');
  for (final String line in mismatches) {
    stderr.writeln('  $line');
  }
  exit(1);
}

String _read(String path) {
  final File file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('$path not found. Run from the repository root.');
    exit(2);
  }
  return file.readAsStringSync();
}

String _match(String path, RegExp pattern) {
  final RegExpMatch? match = pattern.firstMatch(_read(path));
  if (match == null) {
    stderr.writeln('$path: no version found.');
    exit(2);
  }
  return match.group(1)!;
}

/// Version of [package] in a lockfile: the first `version:` line after the
/// package's own two-space-indented key.
String _lockVersion(String path, String package) {
  bool inPackage = false;
  for (final String line in _read(path).split('\n')) {
    if (line.trimRight() == '  $package:') {
      inPackage = true;
    } else if (inPackage && RegExp(r'^  \S').hasMatch(line)) {
      break;
    } else if (inPackage) {
      final RegExpMatch? match = RegExp(r'^    version:\s*"([^"]+)"')
          .firstMatch(line);
      if (match != null) {
        return match.group(1)!;
      }
    }
  }
  stderr.writeln('$path: no version for $package.');
  exit(2);
}

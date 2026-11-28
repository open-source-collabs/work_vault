@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault_example/src/destination_catalog.dart';
import 'package:work_vault_example/src/platform/file_info_io.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('work_vault_example_test');
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('size and SHA-256 of a file on disk', () async {
    final String path = joinDownloadPath(temp.path, 'hello.txt');
    await File(path).writeAsString('hello');

    expect(await fileSize(path), 5);
    expect(
      await sha256OfFile(path),
      '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );
  });

  test('a missing file has no size and no digest', () async {
    final String path = joinDownloadPath(temp.path, 'missing.bin');

    expect(await fileSize(path), isNull);
    expect(await sha256OfFile(path), isNull);
  });

  test('a directory is not reported as a file', () async {
    expect(await fileSize(temp.path), isNull);
  });

  test('the file catalog round-trips and survives a restart', () async {
    final DestinationCatalog catalog = platformDestinationCatalog();
    expect(await catalog.load(temp.path), isEmpty);

    await catalog.save(temp.path, <String, String>{'a': '/x/a', 'b': '/x/b'});
    await catalog.save(temp.path, <String, String>{'b': '/x/b'});

    expect(await platformDestinationCatalog().load(temp.path), <String, String>{
      'b': '/x/b',
    });
    // The temporary write file is renamed away, not left behind.
    expect(
      temp.listSync().map((FileSystemEntity e) => e.path),
      everyElement(isNot(endsWith('.tmp'))),
    );
  });

  for (final String content in <String>['[1, 2, 3]', '{oops']) {
    test('a corrupt catalog ($content) reads as empty', () async {
      await File(
        joinDownloadPath(temp.path, '.work_vault_example_destinations.json'),
      ).writeAsString(content);

      expect(await platformDestinationCatalog().load(temp.path), isEmpty);
    });
  }
}

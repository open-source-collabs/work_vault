import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/utils/checksum.dart';

void main() {
  group('StreamingSha256', () {
    test('matches a one-shot hash however the input is split', () {
      final Uint8List data = Uint8List.fromList(
        List<int>.generate(100000, (int i) => i * 31),
      );
      final String expected = sha256.convert(data).toString();

      for (final int size in <int>[1, 7, 4096, 65536, data.length]) {
        final StreamingSha256 hash = StreamingSha256();
        for (int start = 0; start < data.length; start += size) {
          final int end = start + size > data.length
              ? data.length
              : start + size;
          hash.add(Uint8List.sublistView(data, start, end));
        }
        expect(hash.length, data.length);
        expect(hash.close(), expected, reason: 'chunk size $size');
      }
    });

    test('reset starts over', () {
      final StreamingSha256 hash = StreamingSha256()
        ..add(Uint8List.fromList(utf8.encode('discarded')));
      hash.reset();
      hash.add(Uint8List.fromList(utf8.encode('abc')));

      expect(hash.length, 3);
      expect(
        hash.close(),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('an empty input has the empty digest', () {
      expect(
        StreamingSha256().close(),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  test('normalizeSha256Hex accepts only 64 hex characters', () {
    expect(normalizeSha256Hex(' ${'AB' * 32}\n'), 'ab' * 32);
    expect(normalizeSha256Hex(null), isNull);
    expect(normalizeSha256Hex('ab' * 31), isNull);
    expect(normalizeSha256Hex('g' * 64), isNull);
  });

  test('wireHeaders drops the local digest headers in any case', () {
    expect(
      wireHeaders(<String, String>{
        'Authorization': 'Bearer token',
        'x-work-vault-sha256': 'a' * 64,
        'X-WORK-VAULT-MD5': 'b' * 32,
      }),
      <String, String>{'Authorization': 'Bearer token'},
    );
  });
}

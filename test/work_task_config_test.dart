import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';

import 'support.dart';

void main() {
  test('accepts a default GET download', () {
    expect(() => sampleConfig().validate(), returnsNormally);
  });

  test('rejects a non-https url, a relative path, and a non-GET method', () {
    expect(
      () => sampleConfig(url: 'http://example.com/file.bin').validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
    expect(
      () => sampleConfig(destinationPath: 'archive.bin').validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
    expect(
      () => sampleConfig(method: HttpMethod.post).validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
  });

  test('rejects an unsafe task id, header, and retry policy', () {
    expect(
      () => sampleConfig(taskId: '../escape').validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
    expect(
      () =>
          sampleConfig(headers: const <String, String>{'Bad Header': '1'})
              .validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
    expect(
      () => sampleConfig(retry: const RetryPolicy(maxAttempts: 0)).validate(),
      throwsA(isA<InvalidWorkConfig>()),
    );
  });

  group('expectedSha256', () {
    const String digest =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    test('accepts hex in any case with surrounding whitespace', () {
      final WorkTaskConfig config = sampleConfig(
        expectedSha256: '  ${digest.toUpperCase()} ',
      );
      expect(config.validate, returnsNormally);
      expect(config.resolvedExpectedSha256, digest);
    });

    test('rejects a value that is not a SHA-256 hex digest', () {
      for (final String bad in <String>['', 'abc', '${digest}00', 'z' * 64]) {
        expect(
          () => sampleConfig(expectedSha256: bad).validate(),
          throwsA(isA<InvalidWorkConfig>()),
          reason: bad,
        );
      }
      expect(
        () => sampleConfig(
          headers: const <String, String>{'X-Work-Vault-Sha256': 'nope'},
        ).validate(),
        throwsA(isA<InvalidWorkConfig>()),
      );
    });

    test('falls back to the header, matched without case', () {
      final WorkTaskConfig config = sampleConfig(
        headers: const <String, String>{'x-work-vault-sha256': digest},
      );
      expect(config.validate, returnsNormally);
      expect(config.resolvedExpectedSha256, digest);
      expect(sampleConfig().resolvedExpectedSha256, isNull);
    });

    test('rejects a field and header that disagree', () {
      expect(
        () => sampleConfig(
          expectedSha256: digest,
          headers: <String, String>{'X-Work-Vault-Sha256': 'a' * 64},
        ).validate(),
        throwsA(isA<InvalidWorkConfig>()),
      );
      expect(
        () => sampleConfig(
          expectedSha256: digest,
          headers: <String, String>{
            'X-Work-Vault-Sha256': digest.toUpperCase(),
          },
        ).validate(),
        returnsNormally,
      );
    });

    test('takes part in equality and copyWith', () {
      expect(
        sampleConfig(expectedSha256: digest),
        sampleConfig(expectedSha256: digest),
      );
      expect(sampleConfig(expectedSha256: digest), isNot(sampleConfig()));
      expect(
        sampleConfig().copyWith(expectedSha256: digest).expectedSha256,
        digest,
      );
    });
  });

  test('accepts a Windows absolute destination', () {
    expect(
      () =>
          sampleConfig(destinationPath: r'D:\Downloads\archive.bin').validate(),
      returnsNormally,
    );
  });
}

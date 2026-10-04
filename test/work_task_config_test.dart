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

  test('accepts a Windows absolute destination', () {
    expect(
      () =>
          sampleConfig(destinationPath: r'D:\Downloads\archive.bin').validate(),
      returnsNormally,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault_example/src/format.dart';

void main() {
  test('formatBytes scales by 1024', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(12 * 1024 * 1024 + 400 * 1024), '12.4 MB');
    expect(formatBytes(150 * 1024 * 1024), '150 MB');
  });

  test('formatSpeed handles idle and non-finite rates', () {
    expect(formatSpeed(0), '0 B/s');
    expect(formatSpeed(double.nan), '0 B/s');
    expect(formatSpeed(2048), '2.0 KB/s');
  });

  test('formatEta needs a total and a speed', () {
    expect(
      formatEta(bytesDownloaded: 0, totalBytes: null, bytesPerSecond: 10),
      isNull,
    );
    expect(
      formatEta(bytesDownloaded: 0, totalBytes: 100, bytesPerSecond: 0),
      isNull,
    );
    expect(
      formatEta(bytesDownloaded: 100, totalBytes: 100, bytesPerSecond: 10),
      isNull,
    );
    expect(
      formatEta(bytesDownloaded: 0, totalBytes: 150, bytesPerSecond: 10),
      'about 15 s left',
    );
  });

  test('formatDuration keeps the two largest units', () {
    expect(formatDuration(const Duration(seconds: 5)), '5 s');
    expect(formatDuration(const Duration(minutes: 2, seconds: 5)), '2 m 5 s');
    expect(formatDuration(const Duration(hours: 1, minutes: 3)), '1 h 3 m');
  });
}

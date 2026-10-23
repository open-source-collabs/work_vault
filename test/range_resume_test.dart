import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/web/range_resume.dart';

void main() {
  group('resumeRequestHeaders', () {
    test('sends no resume headers for a fresh download', () {
      expect(resumeRequestHeaders(0, eTag: '"abc"'), isEmpty);
    });

    test('asks for the remaining bytes', () {
      expect(resumeRequestHeaders(100), <String, String>{
        'Range': 'bytes=100-',
      });
    });

    test('guards the prefix with If-Range when an entity tag is known', () {
      expect(resumeRequestHeaders(100, eTag: '"abc"'), <String, String>{
        'Range': 'bytes=100-',
        'If-Range': '"abc"',
      });
    });
  });

  group('parseContentRangeTotal', () {
    test('reads the total size', () {
      expect(parseContentRangeTotal('bytes 10-99/100'), 100);
    });

    test('returns null for missing, unknown, or malformed values', () {
      expect(parseContentRangeTotal(null), isNull);
      expect(parseContentRangeTotal('bytes 10-99/*'), isNull);
      expect(parseContentRangeTotal('garbage'), isNull);
    });
  });
}

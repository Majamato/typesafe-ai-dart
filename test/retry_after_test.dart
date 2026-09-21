import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_after.dart';

void main() {
  group('parseRetryAfter', () {
    test('prefers retry-after-ms', () {
      expect(
        parseRetryAfter({'retry-after-ms': '250', 'retry-after': '7'}),
        const Duration(milliseconds: 250),
      );
    });

    test('reads seconds, including fractional and negative', () {
      expect(parseRetryAfter({'retry-after': '7'}), const Duration(seconds: 7));
      expect(
        parseRetryAfter({'retry-after': '1.5'}),
        const Duration(milliseconds: 1500),
      );
      expect(parseRetryAfter({'retry-after': '-3'}), Duration.zero);
    });

    test('reads an RFC 1123 date relative to now', () {
      final now = DateTime.utc(2026, 9, 20, 10);
      expect(
        parseRetryAfter(
          {'retry-after': 'Sun, 20 Sep 2026 10:00:30 GMT'},
          now: () => now,
        ),
        const Duration(seconds: 30),
      );
      expect(
        parseRetryAfter(
          {'retry-after': 'Sun, 20 Sep 2026 09:00:00 GMT'},
          now: () => now,
        ),
        Duration.zero,
      );
    });

    test('returns null for missing or garbage values', () {
      expect(parseRetryAfter({}), isNull);
      expect(parseRetryAfter({'retry-after': 'soon'}), isNull);
      expect(
        parseRetryAfter({'retry-after-ms': 'x', 'retry-after': ''}),
        isNull,
      );
    });
  });
}

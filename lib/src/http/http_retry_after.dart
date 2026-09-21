/// Parsing of server-provided retry delays.
///
/// Ported from `typesafe-sdk-js`'s `parseRetryAfter` to match the official
/// SDK's behaviour.
library;

import 'package:typesafe_ai_dart/src/http/http_headers.dart';

// Only RFC 1123 dates are accepted (not RFC 850/asctime). The weekday is
// matched but never checked against the date it precedes.
final RegExp _rfc1123 = RegExp(
  '^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun), '
  r'(\d{2}) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{4}) '
  r'(\d{2}):(\d{2}):(\d{2}) GMT$',
);

const _months = {
  'Jan': 1,
  'Feb': 2,
  'Mar': 3,
  'Apr': 4,
  'May': 5,
  'Jun': 6,
  'Jul': 7,
  'Aug': 8,
  'Sep': 9,
  'Oct': 10,
  'Nov': 11,
  'Dec': 12,
};

/// Upper bound in milliseconds for the two numeric forms, one year, which
/// keeps [Duration] arithmetic sane. The date form is not bounded by it.
const int _maxMs = 365 * 24 * 60 * 60 * 1000;

/// Tries `retry-after-ms` (ms), then `retry-after` as seconds, then as an
/// RFC 1123 date; numeric forms clamp to 0-1yr, the date form only floors at 0.
Duration? parseRetryAfter(
  Map<String, String> headers, {
  DateTime Function()? now,
}) {
  final ms = headers[retryAfterMsHeader];
  if (ms != null) {
    final parsed = _finite(ms.trim());
    if (parsed != null) {
      return Duration(milliseconds: parsed.clamp(0, _maxMs).round());
    }
  }
  final raw = headers[retryAfterHeader]?.trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final seconds = _finite(raw);
  if (seconds != null) {
    return Duration(milliseconds: (seconds * 1000).clamp(0, _maxMs).round());
  }
  final date = _parseHttpDate(raw);
  if (date == null) {
    return null;
  }
  final current = (now ?? DateTime.now)().toUtc();
  final delta = date.difference(current);
  return delta.isNegative ? Duration.zero : delta;
}

/// Returns the UTC instant [raw] denotes, or `null` if it is not an RFC 1123
/// date.
DateTime? _parseHttpDate(String raw) {
  final match = _rfc1123.firstMatch(raw);
  if (match == null) {
    return null;
  }
  return DateTime.utc(
    int.parse(match.group(3)!),
    _months[match.group(2)]!,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}

/// Parses [raw] as a number, or returns `null` for anything else, including
/// `NaN` and `Infinity`, which no delay can represent.
num? _finite(String raw) {
  final parsed = num.tryParse(raw);
  return parsed != null && parsed.isFinite ? parsed : null;
}

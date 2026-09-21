/// Names of the HTTP headers this package sends and reads, all lower-cased
/// to match response headers, which HTTP clients deliver lower-cased.
library;

/// Carries the API key, as `Bearer <key>`.
const authorizationHeader = 'authorization';

/// Content type this client accepts.
const acceptHeader = 'accept';

/// Content type of a request body.
const contentTypeHeader = 'content-type';

/// Identifies this SDK and its version.
const userAgentHeader = 'user-agent';

/// Repeats the SDK identifier in a TypeSafe-specific header.
const sdkHeader = 'x-typesafe-sdk';

/// Number of retries already spent, sent only from the second attempt on.
const retryCountHeader = 'x-typesafe-retry-count';

/// Response header carrying the request id.
const requestIdHeader = 'x-typesafe-request-id';

/// Response header asking the client to wait, in seconds or as a date.
const retryAfterHeader = 'retry-after';

/// Response header asking the client to wait, in milliseconds; wins over
/// [retryAfterHeader] when both are present.
const retryAfterMsHeader = 'retry-after-ms';

/// Runs before sending, so a bad header is an [ArgumentError], not a failed
/// attempt that gets retried. Never echoes [value], which may be a secret.
void checkHeader(String name, String value, {required String argument}) {
  if (name.isEmpty || !name.codeUnits.every(_isTokenChar)) {
    throw ArgumentError('has an invalid header name', argument);
  }
  for (final unit in value.codeUnits) {
    if (unit != 0x09 && (unit < 0x20 || unit > 0x7E)) {
      throw ArgumentError(
        'header "$name" has a value HTTP can\'t carry: only visible ASCII, '
        'spaces and tabs are allowed',
        argument,
      );
    }
  }
}

bool _isTokenChar(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A) ||
    _tokenSymbols.codeUnits.contains(unit);

/// The punctuation RFC 9110 allows in a header name.
const _tokenSymbols = r"!#$%&'*+-.^_`|~";

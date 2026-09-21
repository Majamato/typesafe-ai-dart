/// The exception hierarchy for this package.
library;

import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Base of every exception this package throws.
sealed class TypeSafeException implements Exception {
  const TypeSafeException(this.message);

  /// Human readable description of the failure.
  final String message;

  /// Class name used in [toString]. Each class states its own rather than a
  /// central switch deciding, which a subtype listed out of order would break.
  String get _name;

  @override
  String toString() => '$_name: $message';
}

/// An HTTP response with a non-success status; the subclass is chosen from
/// the code (unmapped ones become [UnknownApiException]).
sealed class TypeSafeApiException extends TypeSafeException {
  const TypeSafeApiException(
    super.message, {
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.endpoint,
    this.errorJson,
    this.requestId,
  });

  /// HTTP status code of the response.
  final int statusCode;

  /// Raw response body, possibly empty.
  final String body;

  /// The [body] decoded as a JSON object; `null` if it was empty, not valid
  /// JSON, or not an object.
  final Map<String, Object?>? errorJson;

  /// Response headers, with lower-cased names.
  final Map<String, String> headers;

  /// The endpoint that was called, printing as `POST /v1/systemone`.
  final Endpoint endpoint;

  /// Value of the `x-typesafe-request-id` response header, when present.
  final String? requestId;

  @override
  String toString() {
    final id = requestId == null ? '' : ', request $requestId';
    return '$_name: HTTP $statusCode from $endpoint$id: $message';
  }
}

/// HTTP 400: the server rejected the request as malformed. Not retried by
/// default — the request has to change before it can succeed.
final class BadRequestException extends TypeSafeApiException {
  const BadRequestException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'BadRequestException';
}

/// HTTP 401: the API key is missing, invalid or expired. Retrying won't
/// help — check the key the client was configured with.
final class AuthenticationException extends TypeSafeApiException {
  const AuthenticationException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'AuthenticationException';
}

/// HTTP 403: the API key is valid but lacks access to this call. Retrying
/// won't help until the account is granted access.
final class PermissionDeniedException extends TypeSafeApiException {
  const PermissionDeniedException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'PermissionDeniedException';
}

/// HTTP 404: the resource doesn't exist. Retrying won't help — usually a
/// wrong base URL or path rather than anything transient.
final class NotFoundException extends TypeSafeApiException {
  const NotFoundException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'NotFoundException';
}

/// HTTP 422: well-formed JSON that failed server-side validation. Field
/// errors are joined into [message] as `path: reason`, separated by `; `.
final class UnprocessableEntityException extends TypeSafeApiException {
  const UnprocessableEntityException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'UnprocessableEntityException';
}

/// HTTP 429: rate limit exceeded. Retried by default, so this reaches the
/// caller only once retries are spent — wait at least [retryAfter].
final class RateLimitException extends TypeSafeApiException {
  const RateLimitException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
    this.retryAfter,
  });

  /// Wait the server asked for, from `retry-after-ms` or `retry-after`
  /// (seconds or HTTP date). Never negative; `null` if absent or unparsable.
  final Duration? retryAfter;

  @override
  String get _name => 'RateLimitException';
}

/// HTTP 500-599, including 529 when TypeSafe is overloaded. Retried by
/// default; the same request may well succeed later.
final class InternalServerException extends TypeSafeApiException {
  const InternalServerException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'InternalServerException';
}

/// A non-success status with no dedicated subclass, e.g. HTTP 408 — which
/// the default policy retries anyway.
final class UnknownApiException extends TypeSafeApiException {
  const UnknownApiException(
    super.message, {
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.endpoint,
    super.errorJson,
    super.requestId,
  });

  @override
  String get _name => 'UnknownApiException';
}

/// No complete response arrived: no connection, or one dropped mid-reply.
/// Retried by default; the server may have seen it, so retry only if safe.
class TypeSafeConnectionException extends TypeSafeException {
  const TypeSafeConnectionException(super.message, {this.cause});

  /// The underlying error, usually an `http.ClientException`.
  final Object? cause;

  @override
  String get _name => 'TypeSafeConnectionException';

  @override
  String toString() {
    final suffix = cause == null ? '' : ' (caused by $cause)';
    return '$_name: $message$suffix';
  }
}

/// An attempt exceeded its timeout, or the whole call its `totalTimeout`;
/// without the latter, retries can spend a multiple of [timeout].
final class TypeSafeTimeoutException extends TypeSafeConnectionException {
  const TypeSafeTimeoutException(super.message, {required this.timeout});

  /// The bound that ran out: the per-attempt timeout, or the call's
  /// `totalTimeout` when the budget for retries was spent.
  final Duration timeout;

  @override
  String get _name => 'TypeSafeTimeoutException';
}

/// The caller cancelled via `CancelToken`; no further attempt is made, but
/// a request already sent may still reach the server, its reply discarded.
final class TypeSafeCancelledException extends TypeSafeException {
  const TypeSafeCancelledException([this.reason])
    : super('Request cancelled by caller');

  /// The value passed to `CancelToken.cancel`, if any.
  final Object? reason;

  @override
  String get _name => 'TypeSafeCancelledException';
}

/// The SDK couldn't read an otherwise successful response — bad JSON, a
/// wrong field, or a mismatched answer type. Retrying won't change the outcome.
final class ResponseValidationException extends TypeSafeException {
  const ResponseValidationException(
    super.message, {
    required this.fieldPath,
    this.actual,
  });

  /// Dotted path to the offending value, e.g. `answers.tone.confidence`; `$`
  /// alone means the whole document, and list elements appear by index.
  final String fieldPath;

  /// The value found at [fieldPath]; `null` covers both a JSON `null` and a
  /// field that was absent altogether.
  final Object? actual;

  @override
  String get _name => 'ResponseValidationException';

  @override
  String toString() => '$_name at $fieldPath: $message';
}

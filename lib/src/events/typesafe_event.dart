/// What a `TypeSafeClient` reports to its `onEvent` callback: one event per
/// step of a call, for logging and metrics.
library;

import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/response/usage.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// One step of a call. Every event of a call shares its [callId], and each
/// prints as a one-line log, formatted only when `toString` is called.
@immutable
sealed class TypeSafeEvent {
  const TypeSafeEvent({required this.callId, required this.endpoint});

  /// Identifies the call this event belongs to; unique and increasing per
  /// client, so events of concurrent calls can be told apart.
  final int callId;

  /// The endpoint the call went to.
  final Endpoint endpoint;

  /// `#<callId> <METHOD> <path>`, the prefix of every log line.
  String get _tag => '#$callId $endpoint';
}

/// An attempt is about to be sent.
final class AttemptStarted extends TypeSafeEvent {
  const AttemptStarted({
    required super.callId,
    required super.endpoint,
    required this.attempt,
    required this.timeout,
  });

  /// Which attempt this is, counted from 1.
  final int attempt;

  /// Time this attempt gets, already clamped to what remains of the call's
  /// `totalTimeout`.
  final Duration timeout;

  @override
  String toString() =>
      '$_tag -> attempt $attempt, timeout ${timeout.inMilliseconds}ms';
}

/// An attempt got a complete response, whatever its status.
final class AttemptResponded extends TypeSafeEvent {
  const AttemptResponded({
    required super.callId,
    required super.endpoint,
    required this.attempt,
    required this.response,
    required this.elapsed,
  });

  /// Which attempt this is, counted from 1.
  final int attempt;

  /// The response as received: status, headers and body bytes.
  final RawResponse response;

  /// Time from sending the attempt to having its whole body.
  final Duration elapsed;

  /// HTTP status code of [response].
  int get statusCode => response.statusCode;

  /// Headers of [response], with lower-cased names.
  Map<String, String> get headers => response.headers;

  /// Value of the `x-typesafe-request-id` header, when present.
  String? get requestId => response.requestId;

  @override
  String toString() {
    final id = requestId == null ? '' : ', request $requestId';
    return '$_tag <- $statusCode in ${elapsed.inMilliseconds}ms '
        '(attempt $attempt$id)';
  }
}

/// An attempt ended without a response: it timed out, lost its connection
/// or was cancelled.
final class AttemptFailed extends TypeSafeEvent {
  const AttemptFailed({
    required super.callId,
    required super.endpoint,
    required this.attempt,
    required this.error,
    required this.elapsed,
  });

  /// Which attempt this is, counted from 1.
  final int attempt;

  /// Why the attempt failed.
  final TypeSafeException error;

  /// Time from sending the attempt to its failure.
  final Duration elapsed;

  @override
  String toString() =>
      '$_tag attempt $attempt failed in ${elapsed.inMilliseconds}ms: $error';
}

/// The call waits [delay], then retries. A cancel or `close()` during the
/// wait still ends the call without that retry.
final class RetryScheduled extends TypeSafeEvent {
  const RetryScheduled({
    required super.callId,
    required super.endpoint,
    required this.retry,
    required this.maxRetries,
    required this.delay,
    required this.reason,
  });

  /// Which retry this is, counted from 1; the attempt that failed had the
  /// same number.
  final int retry;

  /// Retries the policy allows for this call.
  final int maxRetries;

  /// How long the call waits before retrying.
  final Duration delay;

  /// The failure being retried: an API error or a connection error.
  final TypeSafeException reason;

  @override
  String toString() {
    final after = switch (reason) {
      TypeSafeApiException(:final statusCode) => 'HTTP $statusCode',
      TypeSafeTimeoutException() => 'a timeout',
      TypeSafeConnectionException() => 'a connection error',
      TypeSafeCancelledException() ||
      ResponseValidationException() => '$reason',
    };
    return '$_tag retrying in ${delay.inMilliseconds}ms '
        '(retry $retry/$maxRetries) after $after';
  }
}

/// The call is over, with a result or an [error]. Exactly one per call that
/// completes with a value or a `TypeSafeException`; the event to log for
/// one line per call, or to feed latency and token metrics.
final class CallFinished extends TypeSafeEvent {
  const CallFinished({
    required super.callId,
    required super.endpoint,
    required this.attempts,
    required this.elapsed,
    this.statusCode,
    this.requestId,
    this.usage,
    this.error,
  });

  /// Attempts sent, 0 when the call failed before sending any.
  final int attempts;

  /// Time for the whole call: attempts, backoff and decoding.
  final Duration elapsed;

  /// Status of the last response, or `null` when the last attempt got none.
  final int? statusCode;

  /// Request id of the last response, when it had one.
  final String? requestId;

  /// Token usage of a successful `systemOne` call; `null` otherwise.
  final Usage? usage;

  /// Why the call failed, or `null` when it succeeded.
  final TypeSafeException? error;

  /// Whether the call returned a result.
  bool get succeeded => error == null;

  @override
  String toString() {
    final ms = elapsed.inMilliseconds;
    final tries = attempts > 1 ? ' after $attempts attempts' : '';
    final error = this.error;
    if (error == null) {
      final id = requestId == null ? '' : ' (request $requestId)';
      return '$_tag <- $statusCode in ${ms}ms$tries$id';
    }
    if (attempts == 0) {
      return '$_tag failed before sending: $error';
    }
    return '$_tag failed in ${ms}ms$tries: $error';
  }
}

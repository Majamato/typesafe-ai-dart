// Retry defaults and behaviour are ported from `typesafe-sdk-js` to match
// the official SDK.

import 'dart:math';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';

/// When and how quickly the client retries a failed attempt. A policy only
/// decides *whether* and *how long*; the client owns the loop that applies it.
@immutable
final class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 2,
    this.backoffInitial = const Duration(milliseconds: 500),
    this.backoffMax = const Duration(seconds: 5),
    this.jitter = 0.25,
    this.respectRetryAfter = true,
    this.maxRetryAfter = const Duration(seconds: 60),
    this.retryOnStatuses = const {408, 429},
    this.retryOnServerErrors = true,
    this.retryOnConnectionError = true,
    this.retryOnTimeout = true,
  }) : assert(maxRetries >= 0, 'maxRetries must not be negative'),
       assert(jitter >= 0 && jitter <= 1, 'jitter must be within [0, 1]');

  /// A policy that makes the single initial attempt and never retries.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0);

  /// The number of retries allowed after the initial attempt, so a request
  /// is sent at most `maxRetries + 1` times.
  final int maxRetries;

  /// Delay before the first retry, doubled for each retry after it.
  final Duration backoffInitial;

  /// Upper bound the doubling is capped at, applied before [jitter], so the
  /// delay actually waited can be shorter but never longer.
  final Duration backoffMax;

  /// Largest fraction of a backoff delay that jitter may subtract, `0` to
  /// `1`; the actual delay lands somewhere in `(1 - jitter)` to `1` of it.
  final double jitter;

  /// Whether a server-provided `Retry-After` replaces the backoff delay.
  final bool respectRetryAfter;

  /// Longest server-provided delay to honour; anything longer is ignored in
  /// favour of the backoff delay.
  final Duration maxRetryAfter;

  /// Exact status codes that trigger a retry, whatever
  /// [retryOnServerErrors] says.
  final Set<int> retryOnStatuses;

  /// Whether every status in `500` to `599` triggers a retry.
  final bool retryOnServerErrors;

  /// Whether a request that never reached a response, such as a DNS or
  /// socket failure, triggers a retry.
  final bool retryOnConnectionError;

  /// Whether an attempt that ran out of time triggers a retry; checked
  /// instead of [retryOnConnectionError], though a timeout is one kind of it.
  final bool retryOnTimeout;

  /// Whether a failed response with [statusCode] should be retried.
  bool shouldRetryStatus(int statusCode) =>
      retryOnStatuses.contains(statusCode) ||
      (retryOnServerErrors && statusCode >= 500 && statusCode <= 599);

  /// Consults [retryOnTimeout] for a [TypeSafeTimeoutException], else
  /// [retryOnConnectionError].
  bool shouldRetryError(TypeSafeConnectionException error) =>
      error is TypeSafeTimeoutException
      ? retryOnTimeout
      : retryOnConnectionError;

  /// Jittered backoff delay before retry number [attempt] (from `0`). Pass
  /// [random] to make the jitter deterministic in tests.
  Duration backoffFor(int attempt, {Random? random}) {
    final initial = backoffInitial.inMicroseconds;
    final max = backoffMax.inMicroseconds;
    final capped = initial > (max >> attempt) ? max : initial << attempt;
    // Asserts are off in AOT, so an out-of-range jitter is clamped here.
    final spread = jitter.isNaN ? 0.0 : jitter.clamp(0.0, 1.0);
    final factor = 1 - (random ?? _random).nextDouble() * spread;

    return Duration(microseconds: (capped * factor).round());
  }

  /// Uses the server's [retryAfter] verbatim, without jitter, when within
  /// [maxRetryAfter]; otherwise falls back to [backoffFor].
  Duration delayFor(int attempt, {Duration? retryAfter, Random? random}) {
    if (respectRetryAfter &&
        retryAfter != null &&
        retryAfter <= maxRetryAfter) {
      return retryAfter;
    }
    return backoffFor(attempt, random: random);
  }

  /// Returns a copy with the given fields replaced, keeping this policy's
  /// value for every argument left `null`.
  RetryPolicy copyWith({
    int? maxRetries,
    Duration? backoffInitial,
    Duration? backoffMax,
    double? jitter,
    bool? respectRetryAfter,
    Duration? maxRetryAfter,
    Set<int>? retryOnStatuses,
    bool? retryOnServerErrors,
    bool? retryOnConnectionError,
    bool? retryOnTimeout,
  }) => RetryPolicy(
    maxRetries: maxRetries ?? this.maxRetries,
    backoffInitial: backoffInitial ?? this.backoffInitial,
    backoffMax: backoffMax ?? this.backoffMax,
    jitter: jitter ?? this.jitter,
    respectRetryAfter: respectRetryAfter ?? this.respectRetryAfter,
    maxRetryAfter: maxRetryAfter ?? this.maxRetryAfter,
    retryOnStatuses: retryOnStatuses ?? this.retryOnStatuses,
    retryOnServerErrors: retryOnServerErrors ?? this.retryOnServerErrors,
    retryOnConnectionError:
        retryOnConnectionError ?? this.retryOnConnectionError,
    retryOnTimeout: retryOnTimeout ?? this.retryOnTimeout,
  );

  @override
  bool operator ==(Object other) =>
      other is RetryPolicy &&
      other.maxRetries == maxRetries &&
      other.backoffInitial == backoffInitial &&
      other.backoffMax == backoffMax &&
      other.jitter == jitter &&
      other.respectRetryAfter == respectRetryAfter &&
      other.maxRetryAfter == maxRetryAfter &&
      other.retryOnServerErrors == retryOnServerErrors &&
      other.retryOnConnectionError == retryOnConnectionError &&
      other.retryOnTimeout == retryOnTimeout &&
      const SetEquality<int>().equals(other.retryOnStatuses, retryOnStatuses);

  @override
  int get hashCode => Object.hash(
    maxRetries,
    backoffInitial,
    backoffMax,
    jitter,
    respectRetryAfter,
    maxRetryAfter,
    retryOnServerErrors,
    retryOnConnectionError,
    retryOnTimeout,
    const SetEquality<int>().hash(retryOnStatuses),
  );

  /// Lists the timing fields only; the retry triggers are left out.
  @override
  String toString() =>
      'RetryPolicy(maxRetries: $maxRetries, backoffInitial: $backoffInitial, '
      'backoffMax: $backoffMax, jitter: $jitter)';

  static final Random _random = Random();
}

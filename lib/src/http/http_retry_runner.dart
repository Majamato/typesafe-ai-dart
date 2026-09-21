import 'dart:async';
import 'dart:math';

import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';
import 'package:typesafe_ai_dart/src/events/call_trace.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/http_error_mapper.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_after.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Signature of the function that performs attempt number [attempt], counted
/// from zero, giving up after [timeout].
typedef Attempt = Future<RawResponse> Function(int attempt, Duration timeout);

/// Signature of the function used to wait between attempts.
typedef Sleep = Future<void> Function(Duration delay);

/// Runs an attempt until it succeeds, the policy's retries run out, the call's
/// time budget is spent, or the caller cancels via a `CancelToken`.
final class RetryRunner {
  /// Without [sleep], backoff waits on a [Timer] that a cancel stops, so no
  /// timer outlives a cancelled call.
  RetryRunner({Sleep? sleep, Random? random, Duration Function()? clock})
    : _sleep = sleep,
      _random = random,
      _clock = clock ?? _monotonic;

  final Sleep? _sleep;
  final Random? _random;
  final Duration Function() _clock;

  /// The monotonic clock deadlines are measured on, shared with call traces.
  Duration Function() get clock => _clock;

  /// Runs [attempt] under [policy], each try bounded by [timeout] and the whole
  /// call by [totalTimeout]; once [closing] is cancelled, no attempt starts.
  /// Reports each step to [trace], from this call's own zone.
  Future<RawResponse> run({
    required RetryPolicy policy,
    required Endpoint endpoint,
    required Attempt attempt,
    required Duration timeout,
    Duration? totalTimeout,
    CancelToken? cancelToken,
    CancelToken? closing,
    CallTrace? trace,
  }) async {
    final deadline = totalTimeout == null ? null : _deadline(totalTimeout);
    var attemptNumber = 0;
    while (true) {
      cancelToken?.throwIfCancelled();
      if (closing != null && closing.isCancelled) {
        throw clientClosedException();
      }
      var attemptTimeout = timeout;
      if (deadline != null) {
        final remaining = deadline - _clock();
        if (remaining <= Duration.zero) {
          throw totalTimeoutException(totalTimeout!);
        }
        attemptTimeout = remaining < timeout ? remaining : timeout;
      }
      trace?.attemptStarted(attemptNumber, attemptTimeout);
      Duration delay;
      TypeSafeException error;
      try {
        final response = await attempt(attemptNumber, attemptTimeout);
        trace?.responded(response);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
        final headers = response.headers;
        error = mapErrorResponse(
          statusCode: response.statusCode,
          body: response.body,
          headers: headers,
          endpoint: endpoint,
        );
        if (!policy.shouldRetryStatus(response.statusCode) ||
            attemptNumber >= policy.maxRetries) {
          throw error;
        }
        delay = policy.delayFor(
          attemptNumber,
          retryAfter: parseRetryAfter(headers),
          random: _random,
        );
      } on TypeSafeConnectionException catch (e) {
        trace?.failed(e);
        // A clamped attempt that timed out spent the budget, not its own
        // timeout: report the budget and never consult the policy.
        if (e is TypeSafeTimeoutException &&
            deadline != null &&
            (attemptTimeout < timeout || _clock() >= deadline)) {
          throw totalTimeoutException(totalTimeout!);
        }
        if (!policy.shouldRetryError(e) || attemptNumber >= policy.maxRetries) {
          rethrow;
        }
        error = e;
        delay = policy.backoffFor(attemptNumber, random: _random);
      } on TypeSafeCancelledException catch (e) {
        trace?.failed(e);
        rethrow;
      }
      if (deadline != null && delay >= deadline - _clock()) {
        throw error;
      }
      trace?.retrying(delay, error, policy.maxRetries);
      await _wait(delay, cancelToken, closing);
      attemptNumber++;
    }
  }

  /// Sleeps for [delay], waking early if either token is cancelled.
  Future<void> _wait(
    Duration delay,
    CancelToken? cancelToken,
    CancelToken? closing,
  ) async {
    final sleep = _sleep;
    final woken = Completer<void>();
    final timer = sleep == null ? Timer(delay, woken.complete) : null;

    void wake() {
      timer?.cancel();
      if (!woken.isCompleted) {
        woken.complete();
      }
    }

    final unregister = [
      if (cancelToken != null) onCancel(cancelToken, wake),
      if (closing != null) onCancel(closing, wake),
    ];
    try {
      await (sleep == null
          ? woken.future
          : Future.any<void>([sleep(delay), woken.future]));
    } finally {
      for (final remove in unregister) {
        remove();
      }
    }
    cancelToken?.throwIfCancelled();
  }

  /// The instant [totalTimeout] from now, saturating instead of overflowing.
  Duration _deadline(Duration totalTimeout) {
    final now = _clock();
    return totalTimeout > _forever - now ? _forever : now + totalTimeout;
  }

  static const _forever = Duration(microseconds: 0x7fffffffffffffff);

  static final Stopwatch _epoch = Stopwatch()..start();

  static Duration _monotonic() => _epoch.elapsed;
}

/// The exception a call throws once its [totalTimeout] is spent.
TypeSafeTimeoutException totalTimeoutException(Duration totalTimeout) =>
    TypeSafeTimeoutException(
      'Call exceeded its total timeout of ${totalTimeout.inMilliseconds} ms',
      timeout: totalTimeout,
    );

/// The exception a call gets once its client is closed, instead of a retry.
TypeSafeConnectionException clientClosedException() =>
    const TypeSafeConnectionException('The TypeSafeClient is closed');

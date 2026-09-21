import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_runner.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Backoff of 1 s, doubling, without jitter, so every delay is exact.
const policy = RetryPolicy(
  backoffInitial: Duration(seconds: 1),
  backoffMax: Duration(seconds: 4),
  jitter: 0,
);

/// A runner over a fake clock: sleeping advances it, and so can an attempt.
final class Harness {
  Harness({Sleep? sleep}) : _sleep = sleep;

  final Sleep? _sleep;
  Duration elapsed = Duration.zero;

  /// Every delay the runner slept for, in order.
  final List<Duration> sleeps = [];

  /// The timeout each attempt was given, in order.
  final List<Duration> timeouts = [];

  late final RetryRunner runner = RetryRunner(
    clock: () => elapsed,
    sleep: (delay) {
      sleeps.add(delay);
      if (_sleep != null) {
        return _sleep(delay);
      }
      elapsed += delay;
      return Future.value();
    },
  );

  /// Runs [steps] in order, each taking [took] of fake time; the last repeats.
  Future<RawResponse> run(
    List<RawResponse Function()> steps, {
    required Duration timeout,
    Duration? totalTimeout,
    Duration took = const Duration(milliseconds: 500),
    RetryPolicy policy = policy,
    CancelToken? cancelToken,
  }) => runner.run(
    policy: policy,
    endpoint: Endpoint.systemOne,
    timeout: timeout,
    totalTimeout: totalTimeout,
    cancelToken: cancelToken,
    attempt: (attempt, attemptTimeout) async {
      timeouts.add(attemptTimeout);
      final step = steps[attempt.clamp(0, steps.length - 1)];
      elapsed += took < attemptTimeout ? took : attemptTimeout;
      return step();
    },
  );
}

RawResponse response(
  int statusCode, [
  String body = '',
  Map<String, String> headers = const {},
]) => RawResponse(
  statusCode: statusCode,
  headers: headers,
  bodyBytes: utf8.encode(body),
);

RawResponse ok() => response(200, '{}');
RawResponse unavailable() => response(503, 'down');
RawResponse throttled(String retryAfter) =>
    response(429, '', {'retry-after': retryAfter});

/// Fails the way `HttpTransport` does when an attempt runs out of time.
RawResponse timedOut() => throw const TypeSafeTimeoutException(
  'No response',
  timeout: Duration(seconds: 1),
);

Matcher throwsTimeoutOf(Duration timeout) => throwsA(
  isA<TypeSafeTimeoutException>().having((e) => e.timeout, 'timeout', timeout),
);

void main() {
  group('RetryRunner without a total timeout', () {
    test('gives every attempt the full timeout and sleeps between', () async {
      final h = Harness();
      await expectLater(
        h.run([unavailable], timeout: const Duration(seconds: 10)),
        throwsA(isA<InternalServerException>()),
      );
      expect(h.timeouts, List.filled(3, const Duration(seconds: 10)));
      expect(h.sleeps, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
    });
  });

  group('RetryRunner with a total timeout', () {
    test('clamps an attempt to the budget and reports the budget', () async {
      final h = Harness();
      await expectLater(
        h.run(
          [timedOut],
          timeout: const Duration(seconds: 10),
          totalTimeout: const Duration(seconds: 2),
        ),
        throwsTimeoutOf(const Duration(seconds: 2)),
      );
      expect(h.timeouts, [const Duration(seconds: 2)]);
      expect(h.sleeps, isEmpty);
    });

    test('skips a retry whose backoff would pass the deadline', () async {
      final h = Harness();
      await expectLater(
        h.run(
          [unavailable],
          timeout: const Duration(seconds: 1),
          totalTimeout: const Duration(milliseconds: 1400),
        ),
        throwsA(isA<InternalServerException>()),
      );
      expect(h.timeouts, [const Duration(seconds: 1)]);
      expect(h.sleeps, isEmpty);
    });

    test('skips a retry whose Retry-After would pass the deadline', () async {
      final h = Harness();
      await expectLater(
        h.run(
          [() => throttled('30')],
          timeout: const Duration(seconds: 1),
          totalTimeout: const Duration(seconds: 20),
        ),
        throwsA(isA<RateLimitException>()),
      );
      expect(h.timeouts, [const Duration(seconds: 1)]);
      expect(h.sleeps, isEmpty);
    });

    test('retries with the remaining budget as the timeout', () async {
      final h = Harness();
      final response = await h.run(
        [unavailable, ok],
        timeout: const Duration(seconds: 3),
        totalTimeout: const Duration(seconds: 3),
      );
      expect(response.statusCode, 200);
      expect(h.sleeps, [const Duration(seconds: 1)]);
      expect(h.timeouts, [
        const Duration(seconds: 3),
        const Duration(milliseconds: 1500),
      ]);
    });

    test('a clamped retry that times out is not retried again', () async {
      final h = Harness();
      await expectLater(
        h.run(
          [unavailable, timedOut],
          timeout: const Duration(seconds: 3),
          totalTimeout: const Duration(seconds: 3),
          policy: policy.copyWith(maxRetries: 5, retryOnTimeout: true),
        ),
        throwsTimeoutOf(const Duration(seconds: 3)),
      );
      expect(h.timeouts, hasLength(2));
      expect(h.sleeps, hasLength(1));
    });

    test('cancelling during backoff wins over the budget', () async {
      final h = Harness(sleep: (_) => Completer<void>().future);
      final token = CancelToken();
      final future = h.run(
        [unavailable],
        timeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 30),
        cancelToken: token,
      );
      await Future<void>.delayed(Duration.zero);
      expect(h.sleeps, hasLength(1));
      token.cancel('gone');
      await expectLater(
        future,
        throwsA(
          isA<TypeSafeCancelledException>().having(
            (e) => e.reason,
            'reason',
            'gone',
          ),
        ),
      );
      expect(h.timeouts, hasLength(1));
    });
  });
}

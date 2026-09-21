import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';

final class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final double value;
  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => value;
  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  group('RetryPolicy', () {
    const policy = RetryPolicy();

    test('defaults match the official SDKs', () {
      expect(policy.maxRetries, 2);
      expect(policy.backoffInitial, const Duration(milliseconds: 500));
      expect(policy.backoffMax, const Duration(seconds: 5));
      expect(policy.jitter, 0.25);
      expect(policy.maxRetryAfter, const Duration(seconds: 60));
      expect(RetryPolicy.none.maxRetries, 0);
    });

    test('status matrix', () {
      for (final status in [408, 429, 500, 503, 529, 599]) {
        expect(policy.shouldRetryStatus(status), isTrue, reason: '$status');
      }
      for (final status in [200, 400, 401, 404, 422, 600]) {
        expect(policy.shouldRetryStatus(status), isFalse, reason: '$status');
      }
      final noServer = policy.copyWith(retryOnServerErrors: false);
      expect(noServer.shouldRetryStatus(500), isFalse);
      expect(noServer.shouldRetryStatus(429), isTrue);
    });

    test('error matrix', () {
      const conn = TypeSafeConnectionException('x');
      const timeout = TypeSafeTimeoutException('x', timeout: Duration.zero);
      expect(policy.shouldRetryError(conn), isTrue);
      expect(policy.shouldRetryError(timeout), isTrue);
      expect(
        policy.copyWith(retryOnTimeout: false).shouldRetryError(timeout),
        isFalse,
      );
      expect(
        policy.copyWith(retryOnConnectionError: false).shouldRetryError(conn),
        isFalse,
      );
    });

    test('backoff doubles, caps and subtracts jitter', () {
      final none = _FixedRandom(0);
      expect(policy.backoffFor(0, random: none).inMilliseconds, 500);
      expect(policy.backoffFor(1, random: none).inMilliseconds, 1000);
      expect(policy.backoffFor(2, random: none).inMilliseconds, 2000);
      expect(policy.backoffFor(3, random: none).inMilliseconds, 4000);
      expect(policy.backoffFor(4, random: none).inMilliseconds, 5000);
      expect(policy.backoffFor(20, random: none).inMilliseconds, 5000);
      for (final attempt in [55, 64, 100]) {
        expect(policy.backoffFor(attempt, random: none).inMilliseconds, 5000);
      }
      final full = _FixedRandom(1);
      expect(policy.backoffFor(0, random: full).inMilliseconds, 375);
      expect(policy.backoffFor(4, random: full).inMilliseconds, 3750);
      for (var i = 0; i < 50; i++) {
        final ms = policy.backoffFor(1).inMilliseconds;
        expect(ms, inInclusiveRange(750, 1000));
      }
    });

    test('delayFor honours Retry-After within the cap', () {
      final none = _FixedRandom(0);
      expect(
        policy.delayFor(
          0,
          retryAfter: const Duration(seconds: 3),
          random: none,
        ),
        const Duration(seconds: 3),
      );
      expect(
        policy.delayFor(
          0,
          retryAfter: const Duration(minutes: 5),
          random: none,
        ),
        const Duration(milliseconds: 500),
      );
      expect(
        policy
            .copyWith(respectRetryAfter: false)
            .delayFor(0, retryAfter: const Duration(seconds: 3), random: none),
        const Duration(milliseconds: 500),
      );
      expect(policy.delayFor(1, random: none), const Duration(seconds: 1));
    });

    test('copyWith and equality', () {
      expect(policy.copyWith(), policy);
      expect(policy.copyWith(maxRetries: 5), isNot(policy));
      expect(policy.copyWith(retryOnStatuses: {408, 429}), policy);
      expect(policy.hashCode, policy.copyWith().hashCode);
    });
  });
}

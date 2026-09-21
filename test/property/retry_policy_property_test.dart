@Tags(['property'])
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/fuzz.dart';

/// A random policy in whole milliseconds, odd shapes included: a cap below
/// the initial delay, zero delays and multi-hour values.
RetryPolicy randomPolicy(Random random) {
  int ms() => switch (random.nextInt(5)) {
    0 => 0,
    1 => 1 + random.nextInt(10),
    2 => random.nextInt(10000),
    3 => random.nextInt(1 << 30),
    _ => 500,
  };
  return RetryPolicy(
    backoffInitial: Duration(milliseconds: ms()),
    backoffMax: Duration(milliseconds: ms()),
    jitter: random.nextBool() ? 0 : random.nextDouble(),
  );
}

/// The documented cap before jitter: the initial delay doubled per retry,
/// never above `backoffMax`.
int capMs(RetryPolicy policy, int attempt) {
  final initial = BigInt.from(policy.backoffInitial.inMilliseconds);
  final max = BigInt.from(policy.backoffMax.inMilliseconds);
  final doubled = initial << attempt;
  return (doubled < max ? doubled : max).toInt();
}

void main() {
  test('backoffFor stays within [(1 - jitter) · cap, cap]', () async {
    await forAll(
      (random) => (
        policy: randomPolicy(random),
        attempt: random.nextBool() ? random.nextInt(70) : random.nextInt(10001),
        seed: random.nextInt(1 << 32),
      ),
      (g) {
        final cap = capMs(g.policy, g.attempt);
        final delay = g.policy
            .backoffFor(g.attempt, random: Random(g.seed))
            .inMilliseconds;
        final floor = ((1 - g.policy.jitter) * cap).floor();
        expect(delay, inInclusiveRange(floor, cap));
      },
      runs: fuzzRuns(2000),
    );
  });

  test('without jitter the delay is exactly the cap, never decreasing', () {
    for (final (initial, max) in [(500, 5000), (1, 1 << 40), (700, 300)]) {
      final policy = RetryPolicy(
        backoffInitial: Duration(milliseconds: initial),
        backoffMax: Duration(milliseconds: max),
        jitter: 0,
      );
      var previous = 0;
      for (var attempt = 0; attempt < 200; attempt++) {
        final delay = policy.backoffFor(attempt).inMilliseconds;
        expect(delay, capMs(policy, attempt), reason: 'attempt $attempt');
        expect(delay, greaterThanOrEqualTo(previous));
        previous = delay;
      }
    }
  });

  test('delayFor uses a Retry-After within the cap verbatim', () async {
    await forAll(
      (random) => (
        respect: random.nextBool(),
        cap: Duration(seconds: random.nextInt(120)),
        after: random.nextBool()
            ? null
            : Duration(milliseconds: random.nextInt(200000)),
        attempt: random.nextInt(5),
      ),
      (g) {
        final policy = RetryPolicy(
          respectRetryAfter: g.respect,
          maxRetryAfter: g.cap,
          jitter: 0,
        );
        final delay = policy.delayFor(g.attempt, retryAfter: g.after);
        final honoured = g.respect && g.after != null && g.after! <= g.cap;
        expect(delay, honoured ? g.after : policy.backoffFor(g.attempt));
      },
    );
  });

  group('D11: sub-millisecond backoff', () {
    test('is not truncated to zero', () {
      const policy = RetryPolicy(
        backoffInitial: Duration(microseconds: 600),
        backoffMax: Duration(milliseconds: 5),
        jitter: 0,
      );
      expect(policy.backoffFor(0), const Duration(microseconds: 600));
      expect(policy.backoffFor(1), const Duration(microseconds: 1200));
      expect(policy.backoffFor(9), const Duration(milliseconds: 5));
    });

    test('a sub-millisecond cap still bounds the delay', () {
      const policy = RetryPolicy(
        backoffInitial: Duration(microseconds: 100),
        backoffMax: Duration(microseconds: 900),
        jitter: 0,
      );
      expect(policy.backoffFor(20), const Duration(microseconds: 900));
    });
  });
}

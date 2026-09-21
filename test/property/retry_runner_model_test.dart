@Tags(['property'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/events/call_trace.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_after.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_runner.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/fuzz.dart';

const ms = Duration(milliseconds: 1);
const statuses = [400, 401, 404, 408, 409, 422, 429, 500, 503, 529, 600];
const retryAfters = <String?>[null, '0', '1', '2.5', '30'];

/// What one attempt does: answer with `status` (`200` is success, `-1` a
/// connection error, `-2` a timeout) after `took`.
typedef Outcome = ({int status, String? retryAfter, Duration took});

typedef Scenario = ({
  List<Outcome> script,
  RetryPolicy policy,
  Duration timeout,
  Duration? totalTimeout,
  Duration? cancelAt,
  int seed,
});

Scenario randomScenario(Random random) {
  Duration upTo(int maxMs) => ms * random.nextInt(maxMs + 1);
  return (
    script: [
      for (var i = 1 + random.nextInt(6); i > 0; i--)
        (
          status: switch (random.nextInt(5)) {
            0 => 200,
            1 => -1,
            2 => -2,
            _ => statuses[random.nextInt(statuses.length)],
          },
          retryAfter: retryAfters[random.nextInt(retryAfters.length)],
          took: upTo(3000),
        ),
    ],
    policy: RetryPolicy(
      maxRetries: random.nextInt(5),
      backoffInitial: upTo(2000),
      backoffMax: upTo(3000),
      jitter: random.nextDouble(),
      respectRetryAfter: random.nextBool(),
      maxRetryAfter: upTo(10000),
      retryOnStatuses: {
        for (final s in const [408, 409, 429])
          if (random.nextBool()) s,
      },
      retryOnServerErrors: random.nextBool(),
      retryOnConnectionError: random.nextBool(),
      retryOnTimeout: random.nextBool(),
    ),
    timeout: ms * (1 + random.nextInt(5000)),
    totalTimeout: random.nextBool() ? null : ms * (1 + random.nextInt(20000)),
    cancelAt: random.nextInt(3) == 0 ? upTo(20000) : null,
    seed: random.nextInt(1 << 32),
  );
}

/// One attempt as the runner started it.
typedef Started = ({int number, Duration timeout, Duration at, Outcome did});

/// Whether [s] ran out of time instead of answering.
bool timedOut(Started s) => s.did.status == -2 || s.did.took >= s.timeout;

void main() {
  test('RetryRunner keeps every documented invariant', () async {
    await forAll(
      randomScenario,
      (sc) async {
        final token = CancelToken();
        var elapsed = Duration.zero;
        Duration? cancelledAt;
        final started = <Started>[];
        final sleeps = <Duration>[];

        void cancelNow(Duration at) {
          elapsed = at;
          cancelledAt = at;
          token.cancel('c');
        }

        final runner = RetryRunner(
          clock: () => elapsed,
          random: Random(sc.seed),
          sleep: (delay) {
            sleeps.add(delay);
            final cancelAt = sc.cancelAt;
            if (cancelAt != null &&
                cancelAt >= elapsed &&
                cancelAt < elapsed + delay) {
              cancelNow(cancelAt);
              return Completer<void>().future;
            }
            elapsed += delay;
            return Future.value();
          },
        );

        final events = <TypeSafeEvent>[];
        final trace = CallTrace(
          events.add,
          () => elapsed,
          callId: 1,
          endpoint: Endpoint.systemOne,
        );

        Object? error;
        RawResponse? response;
        try {
          response = await runner.run(
            policy: sc.policy,
            endpoint: Endpoint.systemOne,
            timeout: sc.timeout,
            totalTimeout: sc.totalTimeout,
            cancelToken: token,
            trace: trace,
            attempt: (number, timeout) async {
              final did = sc.script[min(number, sc.script.length - 1)];
              started.add((
                number: number,
                timeout: timeout,
                at: elapsed,
                did: did,
              ));
              final timesOut = did.status == -2 || did.took >= timeout;
              final took = timesOut ? timeout : did.took;
              final cancelAt = sc.cancelAt;
              if (cancelAt != null &&
                  cancelAt >= elapsed &&
                  cancelAt < elapsed + took) {
                cancelNow(cancelAt);
                throw TypeSafeCancelledException(token.reason);
              }
              elapsed += took;
              if (timesOut) {
                throw TypeSafeTimeoutException('t', timeout: timeout);
              }
              if (did.status == -1) {
                throw const TypeSafeConnectionException('refused');
              }
              return RawResponse(
                statusCode: did.status,
                headers: {'retry-after': ?did.retryAfter},
                bodyBytes: utf8.encode(''),
              );
            },
          );
        } on TypeSafeException catch (e) {
          error = e;
        }

        final policy = sc.policy;
        final budget = sc.totalTimeout;

        // Attempts: numbered in order, bounded by the policy.
        expect(started.length, inInclusiveRange(1, policy.maxRetries + 1));
        expect(
          [for (final s in started) s.number],
          [
            for (var i = 0; i < started.length; i++) i,
          ],
        );

        // Each attempt gets the full timeout, clamped to the budget left.
        for (final s in started) {
          final left = budget == null ? null : budget - s.at;
          final expected = left != null && left < sc.timeout
              ? left
              : sc.timeout;
          expect(s.timeout, expected, reason: 'attempt ${s.number}');
          expect(s.timeout, greaterThan(Duration.zero));
        }
        if (budget != null) {
          expect(elapsed, lessThanOrEqualTo(budget));
        }

        // One sleep between consecutive attempts, sized as documented.
        final gaps = cancelledAt != null && sleeps.length == started.length
            ? sleeps.sublist(0, sleeps.length - 1)
            : sleeps;
        expect(gaps, hasLength(started.length - 1));
        for (var i = 0; i < gaps.length; i++) {
          final did = started[i].did;
          final retryAfter = !timedOut(started[i]) && did.status >= 400
              ? parseRetryAfter({'retry-after': ?did.retryAfter})
              : null;
          if (policy.respectRetryAfter &&
              retryAfter != null &&
              retryAfter <= policy.maxRetryAfter) {
            expect(gaps[i], retryAfter);
          } else {
            final cap = policy.backoffFor(i, random: _Fixed(0));
            final floor = policy.backoffFor(i, random: _Fixed(1));
            expect(
              gaps[i],
              allOf(greaterThanOrEqualTo(floor - ms), lessThanOrEqualTo(cap)),
            );
          }
        }

        // Only a retryable failure is ever retried.
        for (final s in started.take(started.length - 1)) {
          final did = s.did;
          final retryable = timedOut(s)
              ? policy.retryOnTimeout
              : did.status == -1
              ? policy.retryOnConnectionError
              : did.status != 200 && policy.shouldRetryStatus(did.status);
          expect(retryable, isTrue, reason: 'attempt ${s.number} retried');
        }

        // Events follow the grammar S (R|F) (Q S (R|F))* [Q], one S per
        // attempt, numbered from 1, each timed on the attempt's own clock.
        final letters = events.map(
          (e) => switch (e) {
            AttemptStarted() => 'S',
            AttemptResponded() => 'R',
            AttemptFailed() => 'F',
            RetryScheduled() => 'Q',
            CallFinished() => 'C',
          },
        );
        expect(letters.join(), matches(RegExp(r'^S[RF](QS[RF])*Q?$')));
        expect(
          [for (final e in events.whereType<AttemptStarted>()) e.attempt],
          [for (var i = 1; i <= started.length; i++) i],
        );
        final ends = [
          for (final e in events)
            if (e
                case AttemptResponded(:final elapsed) ||
                    AttemptFailed(:final elapsed))
              elapsed,
        ];
        for (var i = 0; i < started.length; i++) {
          final s = started[i];
          final cancelled =
              cancelledAt != null &&
              ends[i] < s.timeout &&
              ends[i] == cancelledAt! - s.at;
          if (!cancelled) {
            expect(
              ends[i],
              timedOut(s) ? s.timeout : s.did.took,
              reason: 'attempt ${s.number} elapsed',
            );
          }
        }

        // How the call ended.
        final last = started.last;
        final lastTimedOut = timedOut(last);
        if (cancelledAt != null && response == null) {
          expect(
            error,
            isA<TypeSafeCancelledException>().having((e) => e.reason, 'r', 'c'),
          );
          expect(
            started.every((s) => s.at <= cancelledAt!),
            isTrue,
            reason: 'no attempt starts after a cancel',
          );
        } else if (response != null) {
          expect(response.statusCode, 200);
          expect(last.did.status, 200);
          expect(lastTimedOut, isFalse);
        } else if (error case TypeSafeTimeoutException(
          :final timeout,
        ) when budget != null && timeout == budget) {
          expect(
            elapsed,
            budget,
            reason: 'budget reported before it was spent',
          );
        } else if (error case TypeSafeApiException(:final statusCode)) {
          expect(statusCode, last.did.status);
          expect(lastTimedOut, isFalse);
        } else if (error case TypeSafeTimeoutException(:final timeout)) {
          expect(lastTimedOut, isTrue);
          expect(timeout, last.timeout);
        } else {
          expect(error, isA<TypeSafeConnectionException>());
          expect(last.did.status, -1);
        }
      },
      runs: fuzzRuns(3000),
      describe: (sc) => '$sc',
    );
  });
}

/// A [Random] whose `nextDouble` is always [value], to pin jitter.
final class _Fixed implements Random {
  _Fixed(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

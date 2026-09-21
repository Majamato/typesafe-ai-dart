import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_runner.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';
import 'fake_time.dart';

const ms = Duration(milliseconds: 1);
const s = Duration(seconds: 1);

final state = {'ticket': 'Charged twice'};
final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');

Future<SystemOneResponse> ask(TypeSafeClient client, {RequestOptions? o}) =>
    client.systemOne(state: state, questions: [billing], options: o);

/// Matches a duration in `[low, high]`.
Matcher within(Duration low, Duration high) => allOf(
  greaterThanOrEqualTo(low),
  lessThanOrEqualTo(high),
);

void main() {
  group('README worst-case timing, on a fake clock', () {
    test('a silent server fails after 3 × 10 s plus ≈1.5 s of backoff', () {
      fakeAsync((async) {
        final api = FakeTimeApi(async, [const Reply.never()]);
        final result = api.settle(ask);
        expect(
          result.error,
          isA<TypeSafeTimeoutException>().having(
            (e) => e.timeout,
            'timeout',
            s * 10,
          ),
        );
        expect(api.attemptTimes, hasLength(3));
        // Backoff 500 ms then 1 s, each minus up to 25 % jitter.
        expect(
          api.attemptTimes[1],
          within(s * 10 + ms * 375, s * 10 + ms * 501),
        );
        expect(result.at, within(s * 31 + ms * 125, s * 31 + ms * 503));
      });
    });

    test('429 with a 60 s Retry-After on every attempt takes ≈150 s', () {
      fakeAsync((async) {
        final api = FakeTimeApi(async, [
          const Reply(
            429,
            after: Duration(milliseconds: 9999),
            body: '',
            headers: {'retry-after': '60'},
          ),
        ]);
        final result = api.settle(ask);
        expect(result.error, isA<RateLimitException>());
        expect(api.attemptTimes, [
          Duration.zero,
          s * 69 + ms * 999,
          s * 139 + ms * 998,
        ]);
        expect(result.at, within(s * 149, s * 150));
      });
    });

    test('a default call retries 408, 429 and 5xx only', () {
      const retried = [408, 429, 500, 502, 503, 504, 529, 599];
      const final_ = [301, 400, 401, 403, 404, 409, 410, 418, 422, 600];
      for (final status in [...retried, ...final_]) {
        fakeAsync((async) {
          final api = FakeTimeApi(async, [Reply(status, body: '')]);
          final result = api.settle(ask);
          expect(result.error, isA<TypeSafeApiException>(), reason: '$status');
          expect(
            api.attemptTimes,
            hasLength(retried.contains(status) ? 3 : 1),
            reason: 'HTTP $status',
          );
        });
      }
    });

    test('backoff starts at 500 ms and doubles, minus ≤25 % jitter', () {
      fakeAsync((async) {
        final api = FakeTimeApi(async, [const Reply(503, body: '')])
          ..settle(ask);
        final [first, second, third] = api.attemptTimes;
        expect(second - first, within(ms * 375, ms * 500));
        expect(third - second, within(ms * 750, ms * 1000));
      });
    });

    test('a connection error is retried twice by default', () {
      fakeAsync((async) {
        var attempts = 0;
        final client = TypeSafeClient.testing(
          ClientConfig(
            apiKey: 'sk-test',
            baseUrl: Uri.parse('https://api.test'),
            defaultModel: 'jev-test',
          ),
          httpClient: MockClient((request) async {
            attempts++;
            throw http.ClientException('refused', request.url);
          }),
          clock: () => async.elapsed,
        );
        Object? error;
        unawaited(
          ask(client).then<void>((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(s * 10);
        expect(error, isA<TypeSafeConnectionException>());
        expect(attempts, 3);
      });
    });
  });

  group('Retry-After', () {
    Duration secondAttempt(Map<String, String> headers) {
      late Duration at;
      fakeAsync((async) {
        final api = FakeTimeApi(async, [
          Reply(503, body: '', headers: headers),
          const Reply(200),
        ]);
        expect(api.settle(ask).value, isNotNull);
        at = api.attemptTimes[1];
      });
      return at;
    }

    test('retry-after-ms wins over retry-after', () {
      expect(
        secondAttempt({'retry-after-ms': '1500', 'retry-after': '30'}),
        ms * 1500,
      );
    });

    test('seconds are honoured up to 60 s, beyond that backoff applies', () {
      expect(secondAttempt({'retry-after': '60'}), s * 60);
      expect(secondAttempt({'retry-after': '61'}), within(ms * 375, ms * 500));
    });

    test('an HTTP date is honoured relative to now', () {
      final date = HttpDate.format(DateTime.now().add(s * 30));
      expect(secondAttempt({'retry-after': date}), within(s * 28, s * 30));
    });
  });

  group('totalTimeout', () {
    test('clamps the last attempt and reports the budget', () {
      fakeAsync((async) {
        final api = FakeTimeApi(
          async,
          [const Reply.never()],
          totalTimeout: s * 15,
        );
        final result = api.settle(ask);
        expect(
          result.error,
          isA<TypeSafeTimeoutException>().having(
            (e) => e.timeout,
            'timeout',
            s * 15,
          ),
        );
        expect(api.attemptTimes, hasLength(2));
        expect(result.at, within(s * 15, s * 15 + ms * 2));
      });
    });

    test('skips a retry whose Retry-After overruns it, throwing the '
        'last error', () {
      fakeAsync((async) {
        final api = FakeTimeApi(
          async,
          [
            const Reply(503, body: 'down', headers: {'retry-after': '20'}),
          ],
          totalTimeout: s * 15,
        );
        final result = api.settle(ask);
        expect(result.error, isA<InternalServerException>());
        expect(api.attemptTimes, [Duration.zero]);
        expect(result.at, Duration.zero);
      });
    });

    test('per call, it overrides the client budget', () {
      fakeAsync((async) {
        final api = FakeTimeApi(
          async,
          [const Reply.never()],
          totalTimeout: s * 60,
        );
        final result = api.settle(
          (c) => ask(
            c,
            o: const RequestOptions(totalTimeout: Duration(seconds: 3)),
          ),
        );
        expect(
          result.error,
          isA<TypeSafeTimeoutException>().having((e) => e.timeout, 't', s * 3),
        );
        expect(result.at, within(s * 3, s * 3 + ms * 2));
      });
    });
  });

  test('x-typesafe-retry-count is absent, then 1, then 2', () {
    fakeAsync((async) {
      final api = FakeTimeApi(async, [
        const Reply(503, body: ''),
        const Reply(503, body: ''),
        const Reply(200),
      ]);
      expect(api.settle(ask).value, isNotNull);
      expect(
        [for (final r in api.requests) r.headers['x-typesafe-retry-count']],
        [null, '1', '2'],
      );
    });
  });

  test('one Timer serves every concurrent attempt', () async {
    final durations = <Duration>[];
    await runZoned(
      () async {
        final client = TypeSafeClient(
          apiKey: 'sk-test',
          baseUrl: 'https://api.test',
          httpClient: MockClient(
            (request) async => http.Response(successBody, 200),
          ),
        );
        await Future.wait([for (var i = 0; i < 1000; i++) ask(client)]);
        expect(client.pendingDeadlines, 0);
        client.close();
      },
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          durations.add(duration);
          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    expect(
      durations.where((d) => d >= const Duration(seconds: 9)),
      hasLength(1),
      reason: 'timers created: $durations',
    );
  });

  test(
    'D3: deadlines fire although the first call ran in another zone',
    () async {
      final client = TypeSafeClient(
        apiKey: 'sk-test',
        baseUrl: 'https://api.test',
        retryPolicy: RetryPolicy.none,
        httpClient: MockClient((request) async {
          if (request.headers['x-call'] == 'first') {
            return http.Response(successBody, 200);
          }
          return Completer<http.Response>().future;
        }),
      );
      addTearDown(client.close);
      // A zone whose timers never fire, such as an abandoned fake clock.
      fakeAsync((async) {
        unawaited(
          ask(
            client,
            o: const RequestOptions(
              headers: {'x-call': 'first'},
              timeout: Duration(milliseconds: 50),
            ),
          ),
        );
        async.flushMicrotasks();
      });
      await Future<void>.delayed(ms * 100);
      await expectLater(
        ask(
          client,
          o: const RequestOptions(timeout: Duration(milliseconds: 200)),
        ).timeout(const Duration(seconds: 3)),
        throwsA(isA<TypeSafeTimeoutException>()),
      );
    },
  );

  group('S5: cancelling during backoff leaves no timer behind', () {
    /// Runs [body] in a zone that records every timer it creates.
    Future<List<(Duration, Timer)>> recordingTimers(
      Future<void> Function() body,
    ) async {
      final timers = <(Duration, Timer)>[];
      await runZoned(
        body,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            timers.add((duration, timer));
            return timer;
          },
        ),
      );
      return timers;
    }

    test('in RetryRunner', () async {
      final token = CancelToken();
      final timers = await recordingTimers(() async {
        final call = RetryRunner().run(
          policy: const RetryPolicy(),
          endpoint: Endpoint.systemOne,
          timeout: s * 10,
          cancelToken: token,
          attempt: (attempt, timeout) async => RawResponse(
            statusCode: 503,
            headers: const {'retry-after': '30'},
            bodyBytes: utf8.encode('down'),
          ),
        );
        await Future<void>.delayed(ms * 20);
        token.cancel('shutdown');
        await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));
      });
      final sleeps = [
        for (final (duration, timer) in timers)
          if (duration == s * 30) timer,
      ];
      expect(sleeps, hasLength(1));
      expect(sleeps.single.isActive, isFalse);
    });

    test('through TypeSafeClient', () async {
      final token = CancelToken();
      final timers = await recordingTimers(() async {
        final client = TypeSafeClient(
          apiKey: 'sk-test',
          baseUrl: 'https://api.test',
          httpClient: MockClient(
            (request) async =>
                http.Response('', 429, headers: {'retry-after': '30'}),
          ),
        );
        final call = ask(client, o: RequestOptions(cancelToken: token));
        await Future<void>.delayed(ms * 20);
        token.cancel();
        await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));
        client.close();
      });
      expect(
        [
          for (final (_, timer) in timers)
            if (timer.isActive) timer,
        ],
        isEmpty,
        reason: 'no timer may outlive a cancelled, closed client',
      );
    });
  });

  group('per-call timeouts must be positive', () {
    for (final (name, options) in [
      ('zero timeout', const RequestOptions(timeout: Duration.zero)),
      (
        'negative timeout',
        const RequestOptions(timeout: Duration(seconds: -1)),
      ),
      ('zero totalTimeout', const RequestOptions(totalTimeout: Duration.zero)),
    ]) {
      test('Finding RO: a $name is an ArgumentError, not a retried '
          'timeout', () async {
        final scripted = ScriptedClient([const Step(200, body: successBody)]);
        await expectLater(
          ask(clientFor(scripted), o: options),
          throwsA(isA<ArgumentError>()),
        );
        expect(scripted.requests, isEmpty);
      });
    }
  });

  test('D5: a timeout near the largest Duration never fires early', () async {
    final scripted = ScriptedClient([
      const Step(200, body: successBody, delay: Duration(milliseconds: 50)),
    ]);
    final client = clientFor(scripted, retryPolicy: RetryPolicy.none);
    const forever = Duration(microseconds: 0x7fffffffffffffff);
    for (final options in [
      const RequestOptions(timeout: forever),
      const RequestOptions(totalTimeout: forever),
    ]) {
      await expectLater(ask(client, o: options), completes);
    }
  });
}

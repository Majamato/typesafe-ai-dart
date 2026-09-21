@Tags(['stress'])
library;

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/deadline_scheduler.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/zone_guard.dart';

const _body = '{"model":"jev-test","answers":{"q":{"type":"noul","noul":0.5}}}';
final _question = Noul(id: 'q', instructions: 'Is `x` true?');

/// A client over [handler] with fast retries and the given per-attempt
/// [timeout].
TypeSafeClient _client(
  MockClientStreamHandler handler, {
  Duration timeout = const Duration(seconds: 5),
  RetryPolicy retryPolicy = RetryPolicy.none,
}) => TypeSafeClient(
  apiKey: 'sk-test',
  baseUrl: 'https://api.test',
  timeout: timeout,
  retryPolicy: retryPolicy,
  httpClient: MockClient.streaming(handler),
);

/// A body that sends [_body] in [chunks] pieces, [gap] apart.
Stream<List<int>> _drip(int chunks, Duration gap) async* {
  final bytes = _body.codeUnits;
  final size = (bytes.length / chunks).ceil();
  for (var i = 0; i < bytes.length; i += size) {
    await Future<void>.delayed(gap);
    yield bytes.sublist(i, min(i + size, bytes.length));
  }
}

void main() {
  test('5 k concurrent calls time out on time, never early', () async {
    await expectNoUncaughtErrors(() async {
      final random = Random(1);
      final delays = <Duration>[];
      final client = _client((request, _) async {
        final delay = delays[int.parse(request.headers['x-call']!)];
        await Future<void>.delayed(delay);
        return http.StreamedResponse(Stream.value(_body.codeUnits), 200);
      });
      addTearDown(client.close);

      const calls = 5000;
      final lateness = <Duration>[];
      final futures = <Future<void>>[];
      for (var i = 0; i < calls; i++) {
        final timeout = Duration(milliseconds: 5 + random.nextInt(45));
        delays.add(Duration(milliseconds: random.nextInt(60)));
        final stopwatch = Stopwatch()..start();
        futures.add(
          client
              .systemOne(
                state: 'x',
                questions: [_question],
                options: RequestOptions(
                  timeout: timeout,
                  headers: {'x-call': '$i'},
                ),
              )
              .then<void>(
                (_) {},
                onError: (Object e) {
                  expect(e, isA<TypeSafeTimeoutException>());
                  final elapsed = stopwatch.elapsed;
                  expect(elapsed, greaterThanOrEqualTo(timeout));
                  lateness.add(elapsed - timeout);
                },
              ),
        );
      }
      await Future.wait(futures);
      expect(lateness, isNotEmpty);
      lateness.sort();
      expect(lateness.last, lessThan(const Duration(milliseconds: 750)));
      expect(client.pendingDeadlines, 0);
    });
  });

  test('a cancel storm across every phase never hangs or leaks', () async {
    await expectNoUncaughtErrors(() async {
      final random = Random(2);
      final client = _client(
        (request, _) async {
          switch (int.parse(request.headers['x-call']!) % 3) {
            case 0: // Waits before headers.
              await Future<void>.delayed(
                Duration(milliseconds: random.nextInt(30)),
              );
              return http.StreamedResponse(Stream.value(_body.codeUnits), 200);
            case 1: // Sends headers, then drips the body.
              return http.StreamedResponse(
                _drip(5, Duration(milliseconds: random.nextInt(8))),
                200,
              );
            default: // Rate limits, so the call sits in backoff.
              return http.StreamedResponse(
                Stream.value('{}'.codeUnits),
                429,
                headers: {'retry-after-ms': '${5 + random.nextInt(20)}'},
              );
          }
        },
        retryPolicy: const RetryPolicy(maxRetries: 3),
      );
      addTearDown(client.close);

      final tokens = <CancelToken>[];
      final outcomes = <Future<Object?>>[];
      for (var i = 0; i < 3000; i++) {
        final token = CancelToken();
        tokens.add(token);
        Timer(Duration(milliseconds: random.nextInt(40)), token.cancel);
        outcomes.add(
          client
              .systemOne(
                state: 'x',
                questions: [_question],
                options: RequestOptions(
                  cancelToken: token,
                  headers: {'x-call': '$i'},
                ),
              )
              .then<Object?>((r) => r, onError: (Object e) => e),
        );
      }
      final results = await Future.wait(
        outcomes,
      ).timeout(const Duration(seconds: 30));
      for (final result in results) {
        expect(
          result,
          anyOf(
            isA<SystemOneResponse>(),
            isA<TypeSafeCancelledException>(),
            isA<RateLimitException>(),
          ),
        );
      }
      expect(results.whereType<TypeSafeCancelledException>(), isNotEmpty);
      expect(tokens.map((t) => t.listenerCount), everyElement(0));
      expect(client.pendingDeadlines, 0);
    });
  });

  test('one shared token cancels every pending call and later ones', () async {
    await expectNoUncaughtErrors(() async {
      final client = _client((request, _) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        return http.StreamedResponse(Stream.value(_body.codeUnits), 200);
      });
      addTearDown(client.close);
      final token = CancelToken();
      final options = RequestOptions(cancelToken: token);
      final pending = [
        for (var i = 0; i < 1000; i++)
          client.systemOne(
            state: 'x',
            questions: [_question],
            options: options,
          ),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(token.listenerCount, 1000);
      token.cancel('shutdown');
      for (final call in pending) {
        await expectLater(
          call,
          throwsA(
            isA<TypeSafeCancelledException>().having(
              (e) => e.reason,
              'reason',
              'shutdown',
            ),
          ),
        );
      }
      await expectLater(
        client.systemOne(state: 'x', questions: [_question], options: options),
        throwsA(isA<TypeSafeCancelledException>()),
      );
      expect(token.listenerCount, 0);
      expect(client.pendingDeadlines, 0);
    });
  });

  test('S9: cancelled deadlines are retained only for one timeout', () {
    fakeAsync((async) {
      final scheduler = DeadlineScheduler(clock: () => async.elapsed);
      const timeout = Duration(seconds: 10);
      const perMillisecond = 5;
      var peak = 0;
      // 30 s of traffic: every attempt finishes at once and cancels its
      // deadline, the common case on a healthy API.
      for (var ms = 0; ms < 30000; ms++) {
        for (var i = 0; i < perMillisecond; i++) {
          scheduler.schedule(timeout, () => fail('cancelled')).cancel();
        }
        peak = max(peak, scheduler.queueLength);
        async.elapse(const Duration(milliseconds: 1));
      }
      expect(scheduler.pendingCount, 0);
      // One timeout's worth of entries, plus the timer's ms rounding.
      expect(peak, lessThanOrEqualTo(perMillisecond * (10000 + 2)));
      async.elapse(timeout * 2);
      expect(scheduler.queueLength, 0);
      expect(scheduler.isIdle, isTrue);
    });
  });
}

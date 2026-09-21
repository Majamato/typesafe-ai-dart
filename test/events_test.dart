import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import 'helpers/mock_transport.dart';
import 'helpers/zone_guard.dart';

final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');
const state = {'ticket': 'Charged twice'};

/// One letter per event, so a call's sequence reads like `SRQSRC`.
String letter(TypeSafeEvent event) => switch (event) {
  AttemptStarted() => 'S',
  AttemptResponded() => 'R',
  AttemptFailed() => 'F',
  RetryScheduled() => 'Q',
  CallFinished() => 'C',
};

/// Records every event a client reports.
final class Recorder {
  final List<TypeSafeEvent> events = [];

  void call(TypeSafeEvent event) => events.add(event);

  String get sequence => events.map(letter).join();

  CallFinished get finished => events.whereType<CallFinished>().single;
}

void main() {
  late Recorder recorder;
  setUp(() => recorder = Recorder());

  TypeSafeClient client(
    List<Step> steps, {
    RetryPolicy retryPolicy = fastRetry,
  }) => clientFor(
    ScriptedClient(steps),
    retryPolicy: retryPolicy,
    onEvent: recorder.call,
  );

  Future<SystemOneResponse> ask(TypeSafeClient c, {RequestOptions? o}) =>
      c.systemOne(state: state, questions: [billing], options: o);

  group('sequences', () {
    test('a success reports S R C with usage, status and request id', () async {
      final c = client([
        const Step(
          200,
          body: successBody,
          headers: {'x-typesafe-request-id': 'req_1'},
        ),
      ]);
      final result = await ask(c);

      expect(recorder.sequence, 'SRC');
      final started = recorder.events[0] as AttemptStarted;
      expect(started.attempt, 1);
      expect(started.timeout, const Duration(seconds: 5));
      final responded = recorder.events[1] as AttemptResponded;
      expect(responded.statusCode, 200);
      expect(responded.requestId, 'req_1');
      expect(identical(responded.response, result.raw), isTrue);
      final finished = recorder.finished;
      expect(finished.succeeded, isTrue);
      expect(finished.attempts, 1);
      expect(finished.statusCode, 200);
      expect(finished.requestId, 'req_1');
      expect(finished.usage, const Usage(inputTokens: 120, outputTokens: 0));
      expect(finished.endpoint, Endpoint.systemOne);
    });

    test('a retried 503 reports S R Q S R C', () async {
      final c = client([
        const Step(503, body: 'down'),
        const Step(200, body: successBody),
      ]);
      await ask(c);

      expect(recorder.sequence, 'SRQSRC');
      final retry = recorder.events[2] as RetryScheduled;
      expect(retry.retry, 1);
      expect(retry.maxRetries, 2);
      expect(retry.reason, isA<InternalServerException>());
      expect((recorder.events[3] as AttemptStarted).attempt, 2);
      expect(recorder.finished.attempts, 2);
      expect(recorder.finished.succeeded, isTrue);
    });

    test('a final 422 reports S R C with the error, and no retry', () async {
      final c = client([const Step(422, body: '{"detail":"bad"}')]);
      await expectLater(ask(c), throwsA(isA<UnprocessableEntityException>()));

      expect(recorder.sequence, 'SRC');
      expect(recorder.finished.error, isA<UnprocessableEntityException>());
      expect(recorder.finished.statusCode, 422);
      expect(recorder.finished.usage, isNull);
    });

    test('a connection error retried reports S F Q S R C', () async {
      final c = client([
        Step.failing(http.ClientException('refused')),
        const Step(200, body: successBody),
      ]);
      await ask(c);

      expect(recorder.sequence, 'SFQSRC');
      expect(
        (recorder.events[1] as AttemptFailed).error,
        isA<TypeSafeConnectionException>(),
      );
      expect(
        (recorder.events[2] as RetryScheduled).reason,
        isA<TypeSafeConnectionException>(),
      );
    });

    test(
      'an undecodable 200 reports S R C with the validation error',
      () async {
        final c = client([const Step(200, body: 'nope')]);
        await expectLater(ask(c), throwsA(isA<ResponseValidationException>()));

        expect(recorder.sequence, 'SRC');
        expect(recorder.finished.error, isA<ResponseValidationException>());
        expect(recorder.finished.statusCode, 200);
      },
    );

    test('a cancel during backoff reports S R Q C', () async {
      final token = CancelToken();
      final c = client([
        const Step(429, headers: {'retry-after-ms': '2000'}),
      ]);
      final call = ask(c, o: RequestOptions(cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel('stop');
      await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));

      expect(recorder.sequence, 'SRQC');
      expect(recorder.finished.statusCode, 429);
      expect(recorder.finished.attempts, 1);
    });

    test('a cancel during an attempt reports S F C', () async {
      final token = CancelToken();
      final c = client([
        const Step(200, body: successBody, delay: Duration(seconds: 2)),
      ]);
      final call = ask(c, o: RequestOptions(cancelToken: token));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));

      expect(recorder.sequence, 'SFC');
      expect(
        (recorder.events[1] as AttemptFailed).error,
        isA<TypeSafeCancelledException>(),
      );
    });

    test('a call that never sends reports only C, with 0 attempts', () async {
      final token = CancelToken()..cancel();
      final c = client([const Step(200, body: successBody)]);
      await expectLater(
        ask(c, o: RequestOptions(cancelToken: token)),
        throwsA(isA<TypeSafeCancelledException>()),
      );
      c.close();
      await expectLater(ask(c), throwsA(isA<TypeSafeConnectionException>()));

      expect(recorder.sequence, 'CC');
      for (final finished in recorder.events.cast<CallFinished>()) {
        expect(finished.attempts, 0);
        expect(finished.statusCode, isNull);
        expect(finished.toString(), contains('failed before sending'));
      }
    });

    test('listModels reports S R C without usage', () async {
      final c = client([const Step(200, body: modelsBody)]);
      await c.listModels();

      expect(recorder.sequence, 'SRC');
      expect(recorder.finished.endpoint, Endpoint.listModels);
      expect(recorder.finished.usage, isNull);
      expect(recorder.finished.succeeded, isTrue);
    });
  });

  test('bad arguments fail with ArgumentError and report nothing', () async {
    final c = client([const Step(200, body: successBody)]);
    await expectLater(
      ask(c, o: const RequestOptions(timeout: Duration.zero)),
      throwsArgumentError,
    );
    await expectLater(
      ask(c, o: const RequestOptions(headers: {'bad header': 'x'})),
      throwsArgumentError,
    );
    await expectLater(
      c.systemOne(state: {'at': DateTime(2026)}, questions: [billing]),
      throwsArgumentError,
    );
    expect(recorder.events, isEmpty);
  });

  test('concurrent calls get distinct, increasing ids', () async {
    final c = client([
      const Step(200, body: successBody, delay: Duration(milliseconds: 20)),
    ]);
    await Future.wait([ask(c), ask(c), ask(c)]);

    final byCall = <int, String>{};
    for (final event in recorder.events) {
      byCall[event.callId] = (byCall[event.callId] ?? '') + letter(event);
    }
    expect(byCall.keys.toList()..sort(), [1, 2, 3]);
    expect(byCall.values, everyElement('SRC'));
  });

  for (final thrown in <Object>[Exception('boom'), StateError('boom')]) {
    test('a callback throwing ${thrown.runtimeType} changes nothing', () async {
      var seen = 0;
      final c = clientFor(
        ScriptedClient([
          const Step(503, body: 'down'),
          const Step(200, body: successBody),
        ]),
        onEvent: (_) {
          seen++;
          // ignore: only_throw_errors, it is an Exception or an Error.
          throw thrown;
        },
      );
      final result = await expectNoUncaughtErrors(() => ask(c));

      expect(result.answer(billing).noul, 0.93);
      expect(seen, 6, reason: 'S R Q S R C, all delivered');
    });
  }

  test('raw holds the response as received', () async {
    final c = client([
      const Step(
        200,
        body: successBody,
        headers: {'X-TypeSafe-Request-Id': 'r'},
      ),
    ]);
    final raw = (await ask(c)).raw!;

    expect(raw.statusCode, 200);
    expect(raw.headers['x-typesafe-request-id'], 'r');
    expect(raw.requestId, 'r');
    expect(raw.bodyBytes, utf8.encode(successBody));
    expect(raw.body, successBody);
    expect(identical(raw.body, raw.body), isTrue, reason: 'decoded once');
  });

  group('toString', () {
    const e = Endpoint.systemOne;
    RawResponse raw(int status, [Map<String, String> headers = const {}]) =>
        RawResponse(
          statusCode: status,
          headers: headers,
          bodyBytes: utf8.encode(''),
        );

    test('prints one line per event', () {
      expect(
        const AttemptStarted(
          callId: 12,
          endpoint: e,
          attempt: 1,
          timeout: Duration(seconds: 10),
        ).toString(),
        '#12 POST /v1/systemone -> attempt 1, timeout 10000ms',
      );
      expect(
        AttemptResponded(
          callId: 12,
          endpoint: e,
          attempt: 1,
          response: raw(503, {'x-typesafe-request-id': 'req_abc'}),
          elapsed: const Duration(milliseconds: 40),
        ).toString(),
        '#12 POST /v1/systemone <- 503 in 40ms (attempt 1, request req_abc)',
      );
      expect(
        const AttemptFailed(
          callId: 12,
          endpoint: e,
          attempt: 2,
          error: TypeSafeConnectionException('refused'),
          elapsed: Duration(milliseconds: 3),
        ).toString(),
        '#12 POST /v1/systemone attempt 2 failed in 3ms: '
        'TypeSafeConnectionException: refused',
      );
      expect(
        const RetryScheduled(
          callId: 13,
          endpoint: e,
          retry: 1,
          maxRetries: 2,
          delay: Duration(milliseconds: 500),
          reason: RateLimitException(
            'slow down',
            statusCode: 429,
            body: '',
            headers: {},
            endpoint: e,
          ),
        ).toString(),
        '#13 POST /v1/systemone retrying in 500ms (retry 1/2) after HTTP 429',
      );
      expect(
        const RetryScheduled(
          callId: 13,
          endpoint: e,
          retry: 2,
          maxRetries: 2,
          delay: Duration(seconds: 1),
          reason: TypeSafeTimeoutException('t', timeout: Duration.zero),
        ).toString(),
        '#13 POST /v1/systemone retrying in 1000ms (retry 2/2) after a timeout',
      );
    });

    test('CallFinished reads as a one-line summary of the call', () {
      expect(
        const CallFinished(
          callId: 12,
          endpoint: e,
          attempts: 1,
          elapsed: Duration(milliseconds: 143),
          statusCode: 200,
          requestId: 'req_abc',
        ).toString(),
        '#12 POST /v1/systemone <- 200 in 143ms (request req_abc)',
      );
      expect(
        const CallFinished(
          callId: 12,
          endpoint: e,
          attempts: 2,
          elapsed: Duration(milliseconds: 643),
          statusCode: 200,
        ).toString(),
        '#12 POST /v1/systemone <- 200 in 643ms after 2 attempts',
      );
      expect(
        const CallFinished(
          callId: 12,
          endpoint: e,
          attempts: 3,
          elapsed: Duration(milliseconds: 31502),
          error: TypeSafeConnectionException('refused'),
        ).toString(),
        '#12 POST /v1/systemone failed in 31502ms after 3 attempts: '
        'TypeSafeConnectionException: refused',
      );
      expect(
        const CallFinished(
          callId: 12,
          endpoint: e,
          attempts: 0,
          elapsed: Duration.zero,
          error: TypeSafeCancelledException(),
        ).toString(),
        '#12 POST /v1/systemone failed before sending: '
        'TypeSafeCancelledException: Request cancelled by caller',
      );
    });
  });
}

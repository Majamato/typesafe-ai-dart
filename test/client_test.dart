import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import 'helpers/mock_transport.dart';

void main() {
  final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');
  final tone = Choice(
    id: 'tone',
    instructions: 'Tone of `ticket`',
    criteria: const {'calm': null, 'angry': null},
  );
  final urgency = Score(
    id: 'urgency',
    instructions: 'Urgency of `ticket`',
    criteria: const ['low', 'mid', 'high'],
  );
  const state = {'ticket': 'Charged twice, fix it now.'};

  group('TypeSafeClient.systemOne', () {
    test('sends the documented request and parses the response', () async {
      final scripted = ScriptedClient([
        const Step(
          200,
          body: successBody,
          headers: {'x-typesafe-request-id': 'req_42'},
        ),
      ]);
      final client = clientFor(scripted);
      final response = await client.systemOne(
        state: state,
        questions: [billing, tone, urgency],
      );

      final request = scripted.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.test/v1/systemone');
      expect(request.headers['authorization'], 'Bearer sk-test');
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(request.headers['accept'], 'application/json');
      expect(request.headers['user-agent'], 'typesafe_ai_dart/$packageVersion');
      expect(request.headers.containsKey('x-typesafe-retry-count'), isFalse);

      final body = jsonDecode(scripted.bodies.single) as Map<String, Object?>;
      expect(body['model'], 'jev-test');
      expect(body['state'], state);
      expect((body['questions']! as Map<String, Object?>).keys, [
        'billing',
        'tone',
        'urgency',
      ]);

      expect(response.model, 'jev-1.13.0');
      expect(response.requestId, 'req_42');
      expect(response.answer(billing).noul, 0.93);
      expect(response.answer(tone).choice, 'angry');
      expect(response.answer(urgency).score, 1.5);
      expect(response.usage.inputTokens, 120);
    });

    test('uses the explicit model and extra body fields', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await clientFor(scripted).systemOne(
        state: 'text',
        questions: [billing],
        model: 'jev-1.13.0',
        extra: const {'beam_width': 4},
      );
      final body = jsonDecode(scripted.bodies.single) as Map<String, Object?>;
      expect(body['model'], 'jev-1.13.0');
      expect(body['beam_width'], 4);
    });

    test('merges headers and never lets callers override auth', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      final client = clientFor(
        scripted,
        defaultHeaders: const {'x-app': 'default', 'x-env': 'prod'},
      );
      await client.systemOne(
        state: 'text',
        questions: [billing],
        options: const RequestOptions(
          headers: {'x-app': 'override', 'authorization': 'Bearer hacked'},
        ),
      );
      final headers = scripted.requests.single.headers;
      expect(headers['x-app'], 'override');
      expect(headers['x-env'], 'prod');
      expect(headers['authorization'], 'Bearer sk-test');
    });

    test('keeps a path prefix on the base URL', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await clientFor(
        scripted,
        baseUrl: 'https://proxy.test/typesafe/',
      ).systemOne(state: 'text', questions: [billing]);
      expect(
        scripted.requests.single.url.toString(),
        'https://proxy.test/typesafe/v1/systemone',
      );
    });

    test('retries 429 then succeeds, counting attempts', () async {
      final scripted = ScriptedClient([
        const Step(429, body: '{"error":"slow"}'),
        const Step(429),
        const Step(200, body: successBody),
      ]);
      final response = await clientFor(
        scripted,
      ).systemOne(state: 'text', questions: [billing]);
      expect(response.answer(billing).noul, 0.93);
      expect(scripted.requests, hasLength(3));
      expect(
        scripted.requests.map((r) => r.headers['x-typesafe-retry-count']),
        [null, '1', '2'],
      );
    });

    test('gives up after maxRetries and throws the last error', () async {
      final scripted = ScriptedClient([const Step(503, body: 'down')]);
      await expectLater(
        clientFor(scripted).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<InternalServerException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having((e) => e.message, 'message', 'down')
              .having((e) => e.endpoint, 'endpoint', Endpoint.systemOne),
        ),
      );
      expect(scripted.requests, hasLength(3));
    });

    test('does not retry client errors', () async {
      final scripted = ScriptedClient([
        const Step(422, body: '{"detail":"state is required"}'),
      ]);
      await expectLater(
        clientFor(scripted).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<UnprocessableEntityException>().having(
            (e) => e.message,
            'message',
            'state is required',
          ),
        ),
      );
      expect(scripted.requests, hasLength(1));
    });

    test('honours retry-after-ms within the cap', () async {
      final scripted = ScriptedClient([
        const Step(429, headers: {'retry-after-ms': '60'}),
        const Step(200, body: successBody),
      ]);
      final watch = Stopwatch()..start();
      await clientFor(scripted).systemOne(state: 'text', questions: [billing]);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(55));
      expect(scripted.requests, hasLength(2));
    });

    test('falls back to backoff when Retry-After exceeds the cap', () async {
      final scripted = ScriptedClient([
        const Step(429, headers: {'retry-after': '3600'}),
        const Step(200, body: successBody),
      ]);
      final watch = Stopwatch()..start();
      await clientFor(scripted).systemOne(state: 'text', questions: [billing]);
      expect(watch.elapsedMilliseconds, lessThan(1000));
      expect(scripted.requests, hasLength(2));
    });

    test('per-request retry policy overrides the client policy', () async {
      final scripted = ScriptedClient([const Step(500)]);
      await expectLater(
        clientFor(scripted).systemOne(
          state: 'text',
          questions: [billing],
          options: const RequestOptions(retryPolicy: RetryPolicy.none),
        ),
        throwsA(isA<InternalServerException>()),
      );
      expect(scripted.requests, hasLength(1));
    });

    test('times out per attempt and retries', () async {
      final scripted = ScriptedClient([
        const Step(200, body: successBody, delay: Duration(milliseconds: 200)),
      ]);
      await expectLater(
        clientFor(
          scripted,
          timeout: const Duration(milliseconds: 20),
        ).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<TypeSafeTimeoutException>().having(
            (e) => e.timeout,
            'timeout',
            const Duration(milliseconds: 20),
          ),
        ),
      );
      expect(scripted.requests, hasLength(3));
    });

    test('timeouts are not retried when the policy says so', () async {
      final scripted = ScriptedClient([
        const Step(200, body: successBody, delay: Duration(milliseconds: 200)),
      ]);
      await expectLater(
        clientFor(
          scripted,
          timeout: const Duration(milliseconds: 20),
          retryPolicy: fastRetry.copyWith(retryOnTimeout: false),
        ).systemOne(state: 'text', questions: [billing]),
        throwsA(isA<TypeSafeTimeoutException>()),
      );
      expect(scripted.requests, hasLength(1));
    });

    test('per-request totalTimeout overrides the client budget', () async {
      final scripted = ScriptedClient([
        const Step(200, body: successBody, delay: Duration(milliseconds: 200)),
      ]);
      await expectLater(
        clientFor(scripted, totalTimeout: const Duration(seconds: 5)).systemOne(
          state: 'text',
          questions: [billing],
          options: const RequestOptions(
            totalTimeout: Duration(milliseconds: 30),
          ),
        ),
        throwsA(
          isA<TypeSafeTimeoutException>().having(
            (e) => e.timeout,
            'timeout',
            const Duration(milliseconds: 30),
          ),
        ),
      );
      expect(scripted.requests, hasLength(1));
    });

    test('a call within its totalTimeout still retries', () async {
      final scripted = ScriptedClient([
        const Step(429),
        const Step(200, body: successBody),
      ]);
      final response = await clientFor(
        scripted,
        totalTimeout: const Duration(seconds: 2),
      ).systemOne(state: 'text', questions: [billing]);
      expect(response.answer(billing).noul, 0.93);
      expect(scripted.requests, hasLength(2));
    });

    test('wraps transport failures and retries them', () async {
      final scripted = ScriptedClient([
        Step.failing(http.ClientException('Connection refused')),
        const Step(200, body: successBody),
      ]);
      await clientFor(scripted).systemOne(state: 'text', questions: [billing]);
      expect(scripted.requests, hasLength(2));

      final always = ScriptedClient([
        Step.failing(http.ClientException('Connection refused')),
      ]);
      await expectLater(
        clientFor(always).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<TypeSafeConnectionException>()
              .having((e) => e.message, 'message', 'Connection refused')
              .having((e) => e.cause, 'cause', isA<http.ClientException>()),
        ),
      );
      expect(always.requests, hasLength(3));
    });

    test('cancels an in-flight attempt', () async {
      final scripted = ScriptedClient([
        const Step(200, body: successBody, delay: Duration(seconds: 2)),
      ]);
      final token = CancelToken();
      final future = clientFor(scripted).systemOne(
        state: 'text',
        questions: [billing],
        options: RequestOptions(cancelToken: token),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel('user left');
      await expectLater(
        future,
        throwsA(
          isA<TypeSafeCancelledException>().having(
            (e) => e.reason,
            'reason',
            'user left',
          ),
        ),
      );
      expect(scripted.requests, hasLength(1));
    });

    test(
      'cancels during the retry delay and before the first attempt',
      () async {
        final scripted = ScriptedClient([
          const Step(429, headers: {'retry-after-ms': '5000'}),
        ]);
        final token = CancelToken();
        final future =
            clientFor(
              scripted,
              retryPolicy: fastRetry.copyWith(
                maxRetryAfter: const Duration(hours: 1),
              ),
            ).systemOne(
              state: 'text',
              questions: [billing],
              options: RequestOptions(cancelToken: token),
            );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        token.cancel();
        await expectLater(future, throwsA(isA<TypeSafeCancelledException>()));
        expect(scripted.requests, hasLength(1));

        final cancelled = CancelToken()..cancel();
        await expectLater(
          clientFor(scripted).systemOne(
            state: 'text',
            questions: [billing],
            options: RequestOptions(cancelToken: cancelled),
          ),
          throwsA(isA<TypeSafeCancelledException>()),
        );
        expect(scripted.requests, hasLength(1));
      },
    );

    test('rejects non-JSON success bodies', () async {
      final scripted = ScriptedClient([const Step(200, body: '<html>')]);
      await expectLater(
        clientFor(scripted).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            r'$',
          ),
        ),
      );
    });

    test('propagates validation errors from answers', () async {
      final scripted = ScriptedClient([
        const Step(
          200,
          body: '{"model":"jev","answers":{"billing":{"type":"noul"}}}',
        ),
      ]);
      await expectLater(
        clientFor(scripted).systemOne(state: 'text', questions: [billing]),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            'answers.billing.noul',
          ),
        ),
      );
    });
  });

  group('TypeSafeClient.listModels', () {
    test('calls GET /v1/models without a body', () async {
      final scripted = ScriptedClient([const Step(200, body: modelsBody)]);
      final models = await clientFor(scripted).listModels();
      final request = scripted.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/models');
      expect(request.headers.containsKey('content-type'), isFalse);
      expect(models.map((m) => m.name), ['jev-1.13.0', 'jev-latest']);
      expect(models.first.releaseDate, '2026-05-01');
    });

    test('maps 401 to AuthenticationException', () async {
      final scripted = ScriptedClient([const Step(401)]);
      await expectLater(
        clientFor(scripted).listModels(),
        throwsA(
          isA<AuthenticationException>().having(
            (e) => e.endpoint,
            'endpoint',
            Endpoint.listModels,
          ),
        ),
      );
    });
  });

  group('TypeSafeClient lifecycle', () {
    test('closes only a client it created', () {
      final external = ClosableClient();
      TypeSafeClient(apiKey: 'k', httpClient: external).close();
      expect(external.closed, isFalse);

      final config = ClientConfig(
        apiKey: 'k',
        baseUrl: Uri.parse('https://api.test'),
        defaultModel: 'jev',
      );
      expect(TypeSafeClient.withConfig(config).close, returnsNormally);
    });

    test('exposes its resolved config without leaking the key', () {
      final client = TypeSafeClient(apiKey: 'sk-secret', baseUrl: 'https://x/');
      expect(client.config.baseUrl.toString(), 'https://x');
      expect(client.config.defaultModel, 'jev-latest');
      expect(client.config.toString(), isNot(contains('sk-secret')));
      client.close();
    });
  });
}

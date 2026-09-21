@Tags(['h1'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/h1_server.dart';
import '../../helpers/mock_transport.dart' show modelsBody, successBody;
import 'h1_support.dart';

Future<H1Server> serve(H1Handler handler) async {
  final server = await H1Server.start(handler);
  addTearDown(server.close);
  return server;
}

void main() {
  group('wire format', () {
    test('POST carries exact body bytes and the SDK headers once', () async {
      final server = await serve((_, res) => respondJson(res, successBody));
      final client = h1Client('${server.url}/api/');
      const extra = {'trace': 'abc', 'model': 'ignored'};

      final response = await client.systemOne(
        state: ticket,
        questions: [billing, tone, urgency],
        extra: extra,
      );

      final request = server.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/api/v1/systemone');
      final expected = SystemOneRequest(
        state: ticket,
        questions: [billing, tone, urgency],
        extra: extra,
      ).encode(defaultModelJson: utf8.encode('"jev-test"'));
      expect(request.body, expected);
      expect(request.header('content-length'), '${expected.length}');
      expect(request.header('authorization'), 'Bearer sk-test');
      expect(request.header('accept'), 'application/json');
      expect(request.header('content-type'), 'application/json');
      expect(request.header('user-agent'), 'typesafe_ai_dart/$packageVersion');
      expect(
        request.header('x-typesafe-sdk'),
        'typesafe_ai_dart/$packageVersion',
      );
      expect(request.headers, isNot(contains('x-typesafe-retry-count')));
      expect(
        request.headers.entries.where((e) => e.value.length > 1),
        isEmpty,
        reason: 'no header is sent twice',
      );
      expect(response.answer(billing).noul, 0.93);
    });

    test('GET /v1/models sends no body and no content type', () async {
      final server = await serve((_, res) => respondJson(res, modelsBody));
      final client = h1Client('${server.url}/api');

      final models = await client.listModels();

      final request = server.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/api/v1/models');
      expect(request.body, isEmpty);
      expect(request.headers, isNot(contains('content-type')));
      expect(request.header('authorization'), 'Bearer sk-test');
      expect(models.map((m) => m.name), ['jev-1.13.0', 'jev-latest']);
    });
  });

  group('connections', () {
    test('100 sequential calls reuse one keep-alive socket', () async {
      final server = await serve((_, res) => respondJson(res, noulBody(0.5)));
      final client = h1Client(server.url);

      for (var i = 0; i < 100; i++) {
        await client.systemOne(state: ticket, questions: [billing]);
      }

      expect(server.requests, hasLength(100));
      expect(server.remotePorts, hasLength(1));
    });

    test('200 concurrent calls each get their own answer back', () async {
      final random = Random(42);
      final server = await serve((request, res) async {
        final state = (request.json! as Map)['state'] as Map;
        final n = state['n'] as int;
        await Future<void>.delayed(Duration(milliseconds: random.nextInt(30)));
        await respondJson(
          res,
          noulBody(n / 1000),
          headers: {'x-typesafe-request-id': 'req-$n'},
        );
      });
      final client = h1Client(server.url);

      final responses = await Future.wait([
        for (var n = 0; n < 200; n++)
          client.systemOne(state: {'n': n}, questions: [billing]),
      ]);

      for (var n = 0; n < 200; n++) {
        expect(responses[n].answer(billing).noul, n / 1000);
        expect(responses[n].requestId, 'req-$n');
      }
      expect(server.requests, hasLength(200));
    });
  });

  group('retries on the wire', () {
    test('x-typesafe-retry-count is absent, then 1, then 2', () async {
      var calls = 0;
      final server = await serve((request, res) async {
        final ok = ++calls == 3;
        await respondJson(res, ok ? successBody : '{}', status: ok ? 200 : 503);
      });
      final client = h1Client(server.url, retryPolicy: quickRetry);

      await client.systemOne(state: ticket, questions: [billing]);

      expect(
        server.requests.map((r) => r.header('x-typesafe-retry-count')),
        [null, '1', '2'],
      );
    });

    for (final (header, value, wait) in [
      ('retry-after-ms', '200', 200),
      ('retry-after', '0.3', 300),
    ]) {
      test(
        '$header: $value holds the retry back ${wait}ms on the server clock',
        () async {
          var calls = 0;
          final server = await serve((request, res) async {
            final first = ++calls == 1;
            await respondJson(
              res,
              first ? '{"error":"slow down"}' : successBody,
              status: first ? 429 : 200,
              headers: first ? {header: value} : const {},
            );
          });
          final client = h1Client(
            server.url,
            retryPolicy: const RetryPolicy(maxRetries: 1),
          );

          await client.systemOne(state: ticket, questions: [billing]);

          final gap =
              server.requests[1].arrivedAt - server.requests[0].arrivedAt;
          expect(gap, greaterThanOrEqualTo(Duration(milliseconds: wait)));
          expect(gap, lessThan(Duration(milliseconds: wait + 400)));
        },
        tags: ['timing'],
      );
    }
  });

  group('bodies', () {
    test('a 16 MB response decodes', () async {
      final padding = 'x' * (16 << 20);
      final body = jsonEncode({
        ...(jsonDecode(successBody) as Map<String, Object?>),
        'padding': padding,
      });
      final server = await serve((_, res) => respondJson(res, body));
      final client = h1Client(server.url, timeout: const Duration(seconds: 30));

      final response = await client.systemOne(
        state: ticket,
        questions: [billing],
      );

      expect(response.answer(billing).noul, 0.93);
    });

    test('a 5 MB state arrives intact', () async {
      final blob = 'y€' * (5 << 19);
      final server = await serve((_, res) => respondJson(res, noulBody(1)));
      final client = h1Client(server.url, timeout: const Duration(seconds: 30));

      await client.systemOne(state: {'blob': blob}, questions: [billing]);

      final sent = server.requests.single.json! as Map<String, Object?>;
      expect((sent['state']! as Map)['blob'], blob);
    });

    test('a gzip-encoded response is decoded transparently', () async {
      final server = await serve((_, res) async {
        res.headers
          ..contentType = ContentType.json
          ..set('content-encoding', 'gzip');
        res.add(gzip.encode(utf8.encode(successBody)));
      });
      final client = h1Client(server.url);

      final response = await client.systemOne(
        state: ticket,
        questions: [billing],
      );

      expect(response.answer(billing).noul, 0.93);
      expect(
        server.requests.single.header('accept-encoding'),
        contains('gzip'),
        reason: 'dart:io asks for gzip on its own',
      );
    });
  });

  group('redirects (dart:io rules, pinned)', () {
    test('303 on POST is followed as a GET to the new location', () async {
      final server = await serve((request, res) async {
        if (request.path == '/v1/systemone') {
          res
            ..statusCode = 303
            ..headers.set('location', '/v1/elsewhere');
          return;
        }
        await respondJson(res, successBody);
      });
      final client = h1Client(server.url);

      final response = await client.systemOne(
        state: ticket,
        questions: [billing],
      );

      expect(response.answer(billing).noul, 0.93);
      expect(server.requests.map((r) => '${r.method} ${r.path}'), [
        'POST /v1/systemone',
        'GET /v1/elsewhere',
      ]);
    });

    for (final status in [301, 302, 307, 308]) {
      test('$status on POST is not followed', () async {
        final server = await serve((request, res) async {
          res
            ..statusCode = status
            ..headers.set('location', '/v1/elsewhere');
        });
        final client = h1Client(server.url);

        await expectLater(
          client.systemOne(state: ticket, questions: [billing]),
          throwsA(
            isA<UnknownApiException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
        expect(server.requests, hasLength(1));
      });

      test('$status on GET /v1/models is followed', () async {
        final server = await serve((request, res) async {
          if (request.path == '/v1/models') {
            res
              ..statusCode = status
              ..headers.set('location', '/v1/models-moved');
            return;
          }
          await respondJson(res, modelsBody);
        });
        final client = h1Client(server.url);

        final models = await client.listModels();

        expect(models, hasLength(2));
        expect(server.requests.map((r) => r.path), [
          '/v1/models',
          '/v1/models-moved',
        ]);
      });
    }
  });
}

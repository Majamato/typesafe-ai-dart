@Tags(['stress', 'h2'])
library;

import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/certs.dart';
import '../helpers/h1_server.dart' show eventually;
import '../helpers/h2_server.dart';
import '../helpers/zone_guard.dart';

final _question = Noul(id: h2QuestionId, instructions: 'Is `x` true?');

const _quickRetry = RetryPolicy(
  maxRetries: 3,
  backoffInitial: Duration(milliseconds: 1),
  backoffMax: Duration(milliseconds: 1),
  jitter: 0,
);

void main() {
  setUpAll(trustTestCa);

  test('2 k multiplexed calls through 429s, 5xx and stream resets', () async {
    await expectNoUncaughtErrors(() async {
      final random = Random(4);
      final server = await H2TestServer.start(
        handler: (exchange) async {
          final body = await exchange.body;
          final attempt = int.parse(
            exchange.headers['x-typesafe-retry-count'] ?? '0',
          );
          switch (attempt < 2 ? random.nextInt(5) : 4) {
            case 0:
              exchange.respond(
                429,
                body: '{"error":"slow down"}',
                headers: {'retry-after-ms': '${random.nextInt(5)}'},
              );
            case 1:
              exchange.respond(503, body: '{"error":"busy"}');
            case 2:
              exchange.reset();
            default:
              exchange.respond(200, body: answerBody(model: stateOf(body)!));
          }
        },
      );
      addTearDown(server.close);
      final client = TypeSafeClient(
        apiKey: 'sk-test',
        baseUrl: server.baseUrl,
        http2: true,
        retryPolicy: _quickRetry,
      );
      addTearDown(client.close);

      const calls = 2000;
      const wave = 200;
      for (var start = 0; start < calls; start += wave) {
        final responses = await Future.wait([
          for (var i = start; i < start + wave; i++)
            client.systemOne(state: 'call-$i', questions: [_question]),
        ]);
        for (var i = 0; i < wave; i++) {
          expect(responses[i].model, 'call-${start + i}');
        }
      }
      expect(client.pendingDeadlines, 0);
      await eventually(
        () => server.openStreams == 0,
        reason: 'streams left open on the server',
      );
    });
  });

  test('500 calls cancelled mid-body reset their streams, none leak', () async {
    await expectNoUncaughtErrors(() async {
      final random = Random(5);
      final server = await H2TestServer.start(
        handler: (exchange) async {
          await exchange.body;
          exchange
            ..sendHeaders(200)
            ..sendData('{"model":'.codeUnits);
        },
      );
      addTearDown(server.close);
      final client = TypeSafeClient(
        apiKey: 'sk-test',
        baseUrl: server.baseUrl,
        http2: true,
      );
      addTearDown(client.close);

      final calls = <Future<Object?>>[];
      for (var i = 0; i < 500; i++) {
        final token = CancelToken();
        Timer(Duration(milliseconds: 20 + random.nextInt(80)), token.cancel);
        calls.add(
          client
              .systemOne(
                state: 'x',
                questions: [_question],
                options: RequestOptions(cancelToken: token),
              )
              .then<Object?>((r) => r, onError: (Object e) => e),
        );
      }
      final outcomes = await Future.wait(
        calls,
      ).timeout(const Duration(seconds: 30));
      expect(outcomes, everyElement(isA<TypeSafeCancelledException>()));
      expect(client.pendingDeadlines, 0);
      await eventually(
        () => server.openStreams == 0,
        reason: 'cancelled streams were not reset',
      );
      expect(server.connections, hasLength(lessThanOrEqualTo(5)));
    });
  });
}

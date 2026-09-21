@Tags(['h2'])
library;

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/certs.dart';
import '../../helpers/h2_server.dart';

final _question = Noul(id: h2QuestionId, instructions: 'Is `x` true?');

void main() {
  setUpAll(trustTestCa);

  late H2TestServer server;
  late TypeSafeClient client;

  Future<void> startWith({
    H2Handler? handler,
    bool ignoreClientClose = false,
    RetryPolicy retryPolicy = RetryPolicy.none,
  }) async {
    server = await H2TestServer.start(
      handler: handler,
      ignoreClientClose: ignoreClientClose,
    );
    client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: server.baseUrl,
      http2: true,
      defaultModel: 'jev-test',
      retryPolicy: retryPolicy,
    );
  }

  tearDown(() async {
    client.close();
    await server.close();
  });

  Future<SystemOneResponse> call(String state) =>
      client.systemOne(state: state, questions: [_question]);

  Future<void> expectClosedSoon(H2Connection connection, String why) =>
      connection.done.timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail(why),
      );

  test('close() closes an idle connection', () async {
    await startWith();
    await call('x');
    client.close();
    await expectClosedSoon(
      server.connections.single,
      'the idle connection stayed open after close()',
    );
  });

  test('close() lets calls in flight finish, then closes', () async {
    await startWith(handler: answer(delay: const Duration(milliseconds: 300)));
    await call('warm-up');

    final states = [for (var i = 0; i < 10; i++) 'call-$i'];
    final pending = Future.wait(states.map(call));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    client.close();

    final responses = await pending;
    expect([for (final r in responses) r.model], states);
    await expectClosedSoon(
      server.connections.single,
      'the connection stayed open after its last call finished',
    );
    expect(client.pendingDeadlines, 0);
  });

  test("close() doesn't wait on a server that ignores GOAWAY", () async {
    await startWith(ignoreClientClose: true);
    await call('x');
    client.close();
    await expectClosedSoon(
      server.connections.single,
      'the client kept its socket open waiting on the server',
    );
  });

  test('D12: a call made after close() fails fast, without retrying', () async {
    await startWith(retryPolicy: const RetryPolicy());
    await call('warm-up');
    client.close();

    final stopwatch = Stopwatch()..start();
    await expectLater(call('late'), throwsA(isA<TypeSafeException>()));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 250)),
      reason: 'the closed client was retried with backoff',
    );
  });

  test(
    'D12: close() stops a call waiting in backoff from retrying',
    () async {
      await startWith(
        retryPolicy: const RetryPolicy(),
        handler: (exchange) => exchange.respond(503, body: 'busy'),
      );
      final pending = call('x').then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      // Let the first attempt fail and the call enter its 500 ms backoff.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.exchanges, hasLength(1));

      client.close();
      final stopwatch = Stopwatch()..start();
      final error = await pending;
      expect(error, isA<TypeSafeException>());
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(milliseconds: 250)),
        reason: 'the call sat out its backoff and retried a closed client',
      );
      expect(server.exchanges, hasLength(1));
    },
  );
}

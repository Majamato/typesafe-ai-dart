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

  Future<void> startWith({H2Handler? handler, int? streamLimit}) async {
    server = await H2TestServer.start(
      handler: handler,
      concurrentStreamLimit: streamLimit,
    );
    client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: server.baseUrl,
      http2: true,
      defaultModel: 'jev-test',
    );
  }

  tearDown(() async {
    client.close();
    await server.close();
  });

  Future<SystemOneResponse> call(String state) =>
      client.systemOne(state: state, questions: [_question]);

  test('http2: true speaks HTTP/2 to the server', () async {
    await startWith();
    final response = await call('hello');

    expect(response.model, 'hello');
    expect(response.answer(_question).noul, 0.5);
    expect(server.connections.single.protocol, 'h2');
    final exchange = server.exchanges.single;
    expect(exchange.method, 'POST');
    expect(exchange.path, '/v1/systemone');
    expect(exchange.headers[':scheme'], 'https');
    expect(exchange.headers['authorization'], 'Bearer sk-test');
    expect(exchange.headers['content-type'], 'application/json');
    expect(client.pendingDeadlines, 0);
  });

  test('sequential calls reuse one connection', () async {
    await startWith();
    for (var i = 0; i < 20; i++) {
      expect((await call('s$i')).model, 's$i');
    }
    expect(server.accepted, 1);
    expect(server.connections.single.exchanges, hasLength(20));
  });

  test('100 concurrent calls multiplex over one TCP connection', () async {
    await startWith(handler: answer(delay: const Duration(milliseconds: 50)));
    final states = [for (var i = 0; i < 100; i++) 'call-$i'];
    final responses = await Future.wait(states.map(call));

    expect([for (final r in responses) r.model], states, reason: 'crosstalk');
    expect(server.accepted, 1);
    expect(server.connections.single.peakOpenStreams, greaterThan(50));
    expect(client.pendingDeadlines, 0);
  });

  test('150 concurrent calls need a second connection', () async {
    await startWith(handler: answer(delay: const Duration(milliseconds: 100)));
    final states = [for (var i = 0; i < 150; i++) 'call-$i'];
    final responses = await Future.wait(states.map(call));

    expect([for (final r in responses) r.model], states);
    expect(server.accepted, 2, reason: 'Http2Client caps a connection at 100');
    for (final connection in server.connections) {
      expect(connection.peakOpenStreams, lessThanOrEqualTo(100));
    }
  });

  test("the server's advertised stream limit is respected", () async {
    await startWith(
      handler: answer(delay: const Duration(milliseconds: 50)),
      streamLimit: 10,
    );
    // Warm up so the client knows the limit before the burst.
    await call('warm-up');
    final states = [for (var i = 0; i < 30; i++) 'call-$i'];
    final responses = await Future.wait(states.map(call));

    expect([for (final r in responses) r.model], states);
    for (final connection in server.connections) {
      expect(connection.peakOpenStreams, lessThanOrEqualTo(10));
    }
    expect(server.accepted, greaterThanOrEqualTo(3));
  });
}

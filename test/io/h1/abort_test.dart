@Tags(['h1'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/h1_server.dart';
import 'h1_support.dart';

Future<RawH1Server> serveRaw(RawHandler handler) async {
  final server = await RawH1Server.start(handler);
  addTearDown(server.close);
  return server;
}

/// Waits for the client to hang up [connection] on its own.
Future<void> expectClosedByClient(RawConnection connection) async {
  await connection.closed.timeout(const Duration(seconds: 2));
  expect(connection.closedByClient, isTrue, reason: 'client closed it');
}

void main() {
  const timeout = Duration(milliseconds: 200);
  final timesOut = throwsA(isA<TypeSafeTimeoutException>());

  test('a timeout before headers closes the socket on time', () async {
    final server = await serveRaw((connection) => connection.nextRequest());
    final client = h1Client(server.url, timeout: timeout);

    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.systemOne(state: ticket, questions: [billing]),
      timesOut,
    );
    expect(stopwatch.elapsed, greaterThanOrEqualTo(timeout));
    expect(stopwatch.elapsed, lessThan(timeout + _slack), reason: 'timing');

    await expectClosedByClient(server.connections.single);
  }, tags: ['timing']);

  test('a timeout bounds a body that drips in byte by byte', () async {
    final server = await serveRaw((connection) async {
      await connection.nextRequest();
      connection.write(
        'HTTP/1.1 200 OK\r\n'
        'content-type: application/json\r\n'
        'content-length: 300\r\n\r\n',
      );
      for (var i = 0; i < 300; i++) {
        if (connection.closedByClient) {
          return;
        }
        connection.write(' ');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final client = h1Client(server.url, timeout: timeout);

    final stopwatch = Stopwatch()..start();
    await expectLater(
      client.systemOne(state: ticket, questions: [billing]),
      timesOut,
    );
    expect(stopwatch.elapsed, greaterThanOrEqualTo(timeout));
    expect(stopwatch.elapsed, lessThan(timeout + _slack));

    await expectClosedByClient(server.connections.single);
  }, tags: ['timing']);

  for (final phase in ['awaiting headers', 'mid-body']) {
    test('a cancel $phase closes the socket and frees the token', () async {
      final ready = Completer<void>();
      final server = await serveRaw((connection) async {
        await connection.nextRequest();
        if (phase == 'mid-body') {
          connection.write(
            'HTTP/1.1 200 OK\r\n'
            'content-type: application/json\r\n'
            'content-length: 500\r\n\r\n{"model":',
          );
          await connection.socket.flush();
        }
        ready.complete();
      });
      final client = h1Client(server.url);
      final token = CancelToken();

      final call = client.systemOne(
        state: ticket,
        questions: [billing],
        options: RequestOptions(cancelToken: token),
      );
      await ready.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel('shutdown');

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
      expect(token.listenerCount, 0);
      await expectClosedByClient(server.connections.single);
    });
  }

  test('a finished call leaves a shared token with no listeners', () async {
    final server = await serveRaw((connection) async {
      while (true) {
        await connection.nextRequest();
        connection.respond(200, noulBody(0.5));
      }
    });
    final client = h1Client(server.url);
    final token = CancelToken();

    for (var i = 0; i < 50; i++) {
      await client.systemOne(
        state: ticket,
        questions: [billing],
        options: RequestOptions(cancelToken: token),
      );
    }

    expect(token.listenerCount, 0);
    expect(server.connections, hasLength(1));
  });
}

/// Upper-bound headroom for a machine busy with other test runs.
const _slack = Duration(milliseconds: 300);

@Tags(['h1'])
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/h1_server.dart';
import '../../helpers/mock_transport.dart' show successBody;
import 'h1_support.dart';

/// Ways the first connection misbehaves after reading the request.
final Map<String, Future<void> Function(RawConnection)> misbehaviours = {
  'resets before headers': (connection) async => connection.destroy(),
  'resets after headers': (connection) async {
    connection.write(
      'HTTP/1.1 200 OK\r\n'
      'content-type: application/json\r\n'
      'content-length: 500\r\n\r\n{"model":"j',
    );
    await connection.socket.flush();
    connection.destroy();
  },
  'truncates a valid JSON body short of content-length': (connection) async {
    connection.respond(
      200,
      successBody,
      contentLength: utf8.encode(successBody).length + 50,
    );
    await connection.socket.flush();
    connection.destroy();
  },
  'sends a garbage status line': (connection) async {
    connection.write('garbage\r\n\r\n');
    await connection.socket.flush();
    connection.destroy();
  },
};

void main() {
  for (final MapEntry(key: name, value: misbehave) in misbehaviours.entries) {
    group('a server that $name', () {
      late RawH1Server server;

      setUp(() async {
        server = await RawH1Server.start((connection) async {
          await connection.nextRequest();
          if (connection.index == 0) {
            await misbehave(connection);
            return;
          }
          connection.respond(200, successBody);
        });
        addTearDown(server.close);
      });

      test('fails with a connection error, never a parse error', () async {
        final client = h1Client(server.url);

        await expectLater(
          client.systemOne(state: ticket, questions: [billing]),
          throwsA(
            isA<TypeSafeConnectionException>().having(
              (e) => e,
              'kind',
              isNot(isA<TypeSafeTimeoutException>()),
            ),
          ),
        );
      });

      test('is retried on a fresh socket and succeeds', () async {
        final client = h1Client(server.url, retryPolicy: quickRetry);

        final response = await client.systemOne(
          state: ticket,
          questions: [billing],
        );

        expect(response.answer(billing).noul, 0.93);
        expect(server.connections, hasLength(2));
      });
    });
  }
}

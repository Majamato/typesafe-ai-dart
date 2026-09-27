@Tags(['h2'])
library;

import 'package:http2/transport.dart' show ErrorCode;
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/certs.dart';
import '../../helpers/h2_server.dart';

final _question = Noul(id: h2QuestionId, instructions: 'Is `x` true?');
const _timeout = Duration(milliseconds: 200);

/// How late a deadline may fire on a loaded machine before a test fails.
const _slack = Duration(seconds: 1);

void main() {
  setUpAll(trustTestCa);

  late H2TestServer server;
  late TypeSafeClient client;

  setUp(() async {
    server = await H2TestServer.start();
    client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: server.baseUrl,
      http2: true,
      defaultModel: 'jev-test',
      timeout: _timeout,
      retryPolicy: RetryPolicy.none,
    );
    // Dial and warm the connection so timings below exclude the handshake.
    // The handshake gets its own budget: on a loaded machine it can take
    // longer than _timeout.
    await client.systemOne(
      state: 'warm-up',
      questions: [_question],
      options: const RequestOptions(timeout: Duration(seconds: 5)),
    );
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  Future<SystemOneResponse> call({String state = 'x', CancelToken? token}) =>
      client.systemOne(
        state: state,
        questions: [_question],
        options: RequestOptions(cancelToken: token),
      );

  /// Waits for the server to see the client reset [exchange], or fails.
  Future<int?> resetCodeOf(H2Exchange exchange) => exchange.terminated.timeout(
    const Duration(seconds: 3),
    onTimeout: () => fail('the client never reset stream ${exchange.path}'),
  );

  group('after response headers', () {
    test(
      'a timeout resets the stream on time and keeps the connection',
      () async {
        server.handler = (exchange) => exchange.sendHeaders(200);
        final stopwatch = Stopwatch()..start();

        await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));
        expect(stopwatch.elapsed, greaterThanOrEqualTo(_timeout));
        expect(stopwatch.elapsed, lessThan(_timeout + _slack));

        final stalled = server.exchanges.last;
        expect(await resetCodeOf(stalled), ErrorCode.CANCEL);
        expect(server.openStreams, 0);

        server.handler = answer();
        expect((await call(state: 'after')).model, 'after');
        expect(server.accepted, 1, reason: 'the connection is reused');
        expect(client.pendingDeadlines, 0);
      },
      tags: ['timing'],
    );

    test('a cancel resets the stream and keeps the connection', () async {
      server.handler = (exchange) => exchange.sendHeaders(200);
      final token = CancelToken();
      final pending = call(token: token);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel('shutdown');

      await expectLater(
        pending,
        throwsA(
          isA<TypeSafeCancelledException>().having(
            (e) => e.reason,
            'reason',
            'shutdown',
          ),
        ),
      );
      expect(await resetCodeOf(server.exchanges.last), ErrorCode.CANCEL);
      expect(token.listenerCount, 0);

      server.handler = answer();
      expect((await call(state: 'after')).model, 'after');
      expect(server.accepted, 1);
      expect(client.pendingDeadlines, 0);
    });

    test('a timeout while the body drips resets the stream', () async {
      server.handler = (exchange) async {
        exchange.sendHeaders(200);
        for (var i = 0; i < 100 && exchange.isOpen; i++) {
          exchange.sendData([0x20]);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      };

      await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));
      expect(await resetCodeOf(server.exchanges.last), ErrorCode.CANCEL);
    });
  });

  group('before response headers', () {
    test(
      'a timeout fails on time and resets the stream once headers arrive',
      () async {
        server.handler = (exchange) async {
          await Future<void>.delayed(_timeout * 2);
          exchange.sendHeaders(200);
        };
        final stopwatch = Stopwatch()..start();

        await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));
        expect(stopwatch.elapsed, greaterThanOrEqualTo(_timeout));
        expect(stopwatch.elapsed, lessThan(_timeout + _slack));

        expect(await resetCodeOf(server.exchanges.last), ErrorCode.CANCEL);
        expect(server.openStreams, 0);
        expect(client.pendingDeadlines, 0);
      },
      tags: ['timing'],
    );

    test(
      'a call to a server that never answers fails on time, and later '
      'calls still work',
      () async {
        server.handler = (_) {};
        final stopwatch = Stopwatch()..start();

        await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));
        expect(stopwatch.elapsed, lessThan(_timeout + _slack));

        server.handler = answer();
        expect((await call(state: 'after')).model, 'after');
        expect(client.pendingDeadlines, 0);
      },
      tags: ['timing'],
    );

    // Known issue D4 lives in package:http2's Http2Client, which can't abort
    // a stream before headers; "Known limitations" in doc/design.md documents
    // it. These tests pin today's behaviour, so an upstream fix shows up as a
    // failure.
    test(
      'known issue D4: a timed-out call to a server that never sends headers '
      'leaves its stream open',
      () async {
        server.handler = (_) {};
        await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));

        final silent = server.exchanges.last;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          silent.isOpen,
          isTrue,
          reason: 'fixed upstream? See doc/design.md "Known limitations"',
        );
      },
    );

    test(
      'known issue D4: a cancelled call to a server that never sends headers '
      'leaves its stream open',
      () async {
        server.handler = (_) {};
        final token = CancelToken();
        final pending = call(token: token);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        token.cancel();
        await expectLater(pending, throwsA(isA<TypeSafeCancelledException>()));

        final silent = server.exchanges.last;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(silent.isOpen, isTrue);
      },
    );

    test(
      'known issue D4: close() leaves the connection open after a call the '
      'server never answered',
      () async {
        server.handler = (_) {};
        await expectLater(call(), throwsA(isA<TypeSafeTimeoutException>()));

        client.close();
        final connection = server.connections.single;
        final closed = await connection.done
            .then((_) => true)
            .timeout(const Duration(milliseconds: 500), onTimeout: () => false);
        expect(
          closed,
          isFalse,
          reason: 'fixed upstream? See doc/design.md "Known limitations"',
        );
      },
    );

    test(
      'known issue D4: a silently dead connection is abandoned only after '
      '100 calls leak a stream on it',
      () async {
        // Only the first connection is a black hole, as when a NAT drops it.
        server.handler = (exchange) async {
          if (exchange.connection != server.connections.first) {
            await answer()(exchange);
          }
        };
        final outcomes = await Future.wait([
          for (var i = 0; i < 100; i++)
            call().then<Object?>((r) => r, onError: (Object e) => e),
        ]);
        expect(outcomes, everyElement(isA<TypeSafeTimeoutException>()));
        expect(server.connections, hasLength(1));

        expect((await call(state: 'after')).model, 'after');
        expect(server.connections, hasLength(2));
      },
    );
  });
}

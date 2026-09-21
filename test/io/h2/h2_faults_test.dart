@Tags(['h2'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/certs.dart';
import '../../helpers/h2_server.dart';

final _question = Noul(id: h2QuestionId, instructions: 'Is `x` true?');

/// Retries quickly so fault tests don't sit in backoff.
const _quickRetry = RetryPolicy(
  backoffInitial: Duration(milliseconds: 10),
  backoffMax: Duration(milliseconds: 10),
  jitter: 0,
);

void main() {
  setUpAll(trustTestCa);

  late H2TestServer server;
  TypeSafeClient? client;

  TypeSafeClient clientFor(
    H2TestServer server, {
    String apiKey = 'sk-test',
    RetryPolicy retryPolicy = _quickRetry,
    Map<String, String> defaultHeaders = const {},
  }) => client = TypeSafeClient(
    apiKey: apiKey,
    baseUrl: server.baseUrl,
    http2: true,
    defaultModel: 'jev-test',
    defaultHeaders: defaultHeaders,
    timeout: const Duration(seconds: 5),
    retryPolicy: retryPolicy,
  );

  tearDown(() async {
    client?.close();
    client = null;
    await server.close();
  });

  Future<SystemOneResponse> call(
    TypeSafeClient client,
    String state, {
    Map<String, String> headers = const {},
  }) => client.systemOne(
    state: state,
    questions: [_question],
    options: RequestOptions(headers: headers),
  );

  test(
    'after a GOAWAY the next call dials a new connection, no SDK retry spent',
    () async {
      server = await H2TestServer.start();
      final client = clientFor(server, retryPolicy: RetryPolicy.none);
      expect((await call(client, 'first')).model, 'first');

      await server.connections.single.goAway();
      await server.connections.single.done.timeout(const Duration(seconds: 3));
      // Let the client read the GOAWAY and the close before calling again.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect((await call(client, 'second')).model, 'second');
      expect(server.accepted, 2);
      expect(client.pendingDeadlines, 0);
    },
  );

  // Known issue N2: Http2Client doesn't retry a stream a GOAWAY refused, so
  // the call spends one of the SDK's retries; see doc/design.md "Known
  // limitations".
  test(
    'known issue N2: a call racing a graceful GOAWAY succeeds on a retry',
    () async {
      server = await H2TestServer.start();
      final client = clientFor(server);
      expect((await call(client, 'first')).model, 'first');

      await server.connections.single.goAway();
      await server.connections.single.done.timeout(const Duration(seconds: 3));

      // Sent before the client has read the close: the dying connection
      // refuses the stream as "not processed, can be retried".
      expect((await call(client, 'second')).model, 'second');
    },
  );

  test('a GOAWAY with calls in flight lets them finish', () async {
    server = await H2TestServer.start(
      handler: answer(delay: const Duration(milliseconds: 200)),
    );
    final client = clientFor(server, retryPolicy: RetryPolicy.none);
    await call(client, 'warm-up');

    final states = [for (var i = 0; i < 10; i++) 'call-$i'];
    final pending = Future.wait(states.map((s) => call(client, s)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    unawaited(server.connections.single.goAway());

    final responses = await pending;
    expect([for (final r in responses) r.model], states);
  });

  test('a stream the server resets does not break its siblings', () async {
    server = await H2TestServer.start(
      handler: (exchange) async {
        final body = await exchange.body;
        final firstTry = !exchange.headers.containsKey(
          'x-typesafe-retry-count',
        );
        if (stateOf(body) == 'victim' && firstTry) {
          exchange.reset();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        exchange.respond(200, body: answerBody(model: stateOf(body)!));
      },
    );
    final client = clientFor(server);
    await call(client, 'warm-up');

    final siblings = [for (var i = 0; i < 20; i++) 'sibling-$i'];
    final pendingSiblings = Future.wait(siblings.map((s) => call(client, s)));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final victim = await call(client, 'victim');

    expect(victim.model, 'victim', reason: 'the reset attempt is retried');
    final responses = await pendingSiblings;
    expect([for (final r in responses) r.model], siblings);
    expect(client.pendingDeadlines, 0);
  });

  test(
    'a connection killed with 50 calls in flight: all are retried onto a new '
    'connection and succeed',
    () async {
      final arrived = Completer<void>();
      server = await H2TestServer.start(
        handler: (exchange) async {
          final body = await exchange.body;
          final state = stateOf(body)!;
          final first = exchange.connection.index == 0;
          if (first && state != 'warm-up') {
            if (exchange.connection.exchanges.length == 51 &&
                !arrived.isCompleted) {
              arrived.complete();
            }
            return; // Held until the connection dies.
          }
          exchange.respond(200, body: answerBody(model: state));
        },
      );
      final client = clientFor(server);
      await call(client, 'warm-up');

      final states = [for (var i = 0; i < 50; i++) 'call-$i'];
      final pending = Future.wait(states.map((s) => call(client, s)));
      await arrived.future.timeout(const Duration(seconds: 5));
      server.connections.first.destroy();

      final responses = await pending.timeout(const Duration(seconds: 10));
      expect([for (final r in responses) r.model], states);
      expect(server.accepted, 2, reason: 'every retry shares one new dial');
      expect(client.pendingDeadlines, 0);
    },
  );

  test('a server without ALPN h2 is a connection error', () async {
    server = await H2TestServer.start(tls: H2Tls.withoutH2);
    final client = clientFor(server);

    // The message comes from Http2Client and varies with how the handshake
    // ends, so only the classification is pinned.
    await expectLater(
      call(client, 'x'),
      throwsA(
        isA<TypeSafeConnectionException>().having(
          (e) => e,
          'type',
          isNot(isA<TypeSafeTimeoutException>()),
        ),
      ),
    );
    expect(
      server.accepted,
      _quickRetry.maxRetries + 1,
      reason: 'one dial per attempt, no more',
    );
  });

  test('an untrusted certificate is rejected, one dial per attempt', () async {
    server = await H2TestServer.start(tls: H2Tls.untrusted);
    final client = clientFor(server);

    await expectLater(
      call(client, 'x'),
      throwsA(
        isA<TypeSafeConnectionException>().having(
          (e) => '$e',
          'text',
          contains('CERTIFICATE_VERIFY_FAILED'),
        ),
      ),
    );
    expect(server.accepted, _quickRetry.maxRetries + 1);
    expect(server.exchanges, isEmpty);
  });

  group('D2: bad header values', () {
    test('D2: an API key with a newline is rejected at construction', () async {
      server = await H2TestServer.start();
      expect(
        () => clientFor(server, apiKey: 'sk-secret-123\n'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            isNot(contains('sk-secret-123')),
          ),
        ),
      );
    });

    test(
      'D2: an API key with non-ASCII characters is rejected at construction',
      () async {
        server = await H2TestServer.start();
        expect(
          () => clientFor(server, apiKey: 'sk-sécret-123'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'text',
              isNot(contains('sk-sécret-123')),
            ),
          ),
        );
      },
    );

    test(
      'D2: a failure caused by a bad API key never echoes the key',
      () async {
        server = await H2TestServer.start();
        final TypeSafeClient client;
        try {
          client = clientFor(server, apiKey: 'sk-sécret-123');
          // ignore: avoid_catching_errors, rejecting the key is the D2 fix.
        } on ArgumentError {
          return;
        }
        final error = await call(
          client,
          'x',
        ).then<Object?>((_) => null, onError: (Object e) => e);
        expect(error, isA<TypeSafeException>());
        expect('$error', isNot(contains('sk-sécret-123')));
      },
    );

    Future<(Object?, Duration)> callWithBadHeader(TypeSafeClient client) async {
      final stopwatch = Stopwatch()..start();
      final error = await call(
        client,
        'bad',
        headers: {'x-note': 'café'},
      ).then<Object?>((_) => null, onError: (Object e) => e);
      return (error, stopwatch.elapsed);
    }

    test('D2: a non-ASCII per-call header is an ArgumentError', () async {
      server = await H2TestServer.start();
      final client = clientFor(server);
      final (error, _) = await callWithBadHeader(client);
      expect(error, isA<ArgumentError>());
    });

    test('D2: a non-ASCII per-call header is not retried', () async {
      server = await H2TestServer.start();
      final client = clientFor(server, retryPolicy: const RetryPolicy());
      await call(client, 'warm-up');
      final (error, elapsed) = await callWithBadHeader(client);
      expect(error, isNotNull);
      expect(
        elapsed,
        lessThan(const Duration(milliseconds: 300)),
        reason: 'a request that can never be sent waited out retry backoff',
      );
    });

    test(
      'D2: a non-ASCII per-call header does not retire the shared connection',
      () async {
        server = await H2TestServer.start(
          handler: answer(delay: const Duration(milliseconds: 200)),
        );
        final client = clientFor(server, retryPolicy: RetryPolicy.none);
        await call(client, 'warm-up');

        final sibling = call(client, 'sibling');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final (error, _) = await callWithBadHeader(client);
        expect(error, isNotNull);
        expect((await sibling).model, 'sibling', reason: 'sibling unaffected');
        expect((await call(client, 'after')).model, 'after');
        expect(
          server.accepted,
          1,
          reason: 'one bad request retired the connection, forcing a redial',
        );
      },
    );
  });
}

@Tags(['h1'])
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/h1_server.dart';
import '../../helpers/mock_transport.dart' show modelsBody, successBody;
import 'h1_support.dart';

// Each test here asserts the behaviour the plan's findings table asks for,
// named by finding id, so it fails until that finding is fixed.

Future<H1Server> serve([H1Handler? handler]) async {
  final server = await H1Server.start(
    handler ?? (_, res) => respondJson(res, successBody),
  );
  addTearDown(server.close);
  return server;
}

/// Runs [call] and returns what it threw, synchronously or through its
/// future, or `null` when it succeeded.
Future<Object?> failureOf(FutureOr<Object?> Function() call) async {
  try {
    await call();
    return null;
  } on Object catch (error) {
    return error;
  }
}

/// A failure an invalid argument should produce: an [ArgumentError], or a
/// [TypeSafeException] that is neither retried nor a network error.
final Matcher rejectsArgument = anyOf(
  isA<ArgumentError>(),
  isA<TypeSafeException>().having(
    (e) => e,
    'kind',
    isNot(isA<TypeSafeConnectionException>()),
  ),
);

/// Headroom before the default policy's first backoff (at least 375 ms).
const failFast = Duration(milliseconds: 300);

void main() {
  group('D2: an API key with a trailing newline', () {
    const key = 'sk-secret-4242';

    Future<(Object?, Duration, H1Server)> attempt() async {
      final server = await serve();
      final stopwatch = Stopwatch()..start();
      final error = await failureOf(() {
        final client = h1Client(
          '${server.url}/',
          apiKey: '$key\n',
          retryPolicy: const RetryPolicy(),
        );
        return client.systemOne(state: ticket, questions: [billing]);
      });
      return (error, stopwatch.elapsed, server);
    }

    test('is rejected as a bad argument', () async {
      final (error, _, server) = await attempt();
      expect(error, rejectsArgument);
      expect(server.requests, isEmpty);
    });

    test('never appears in the error or its cause', () async {
      final (error, _, _) = await attempt();
      expect(error, isNotNull);
      expect('$error', isNot(contains(key)));
      if (error is TypeSafeConnectionException) {
        expect('${error.cause}', isNot(contains(key)));
      }
    });

    test('fails fast instead of being retried', () async {
      final (_, elapsed, _) = await attempt();
      expect(elapsed, lessThan(failFast));
    });

    test('leaves no socket open on the server', () async {
      final (_, _, server) = await attempt();
      await eventually(
        () => server.openConnections == 0,
        within: const Duration(seconds: 1),
        reason: '${server.openConnections} orphaned connection(s)',
      );
    });
  });

  group('S6: an unsendable header value is a fast argument error', () {
    for (final (what, headers) in [
      ('CR/LF injection', {'x-note': 'a\r\nx-evil: 1'}),
      ('a non-ASCII value', {'x-note': 'café'}),
      ('an invalid header name', {'bad name': 'v'}),
    ]) {
      test('per call: $what', () async {
        final server = await serve();
        final client = h1Client(server.url, retryPolicy: const RetryPolicy());

        final stopwatch = Stopwatch()..start();
        final error = await failureOf(
          () => client.systemOne(
            state: ticket,
            questions: [billing],
            options: RequestOptions(headers: headers),
          ),
        );

        expect(error, rejectsArgument);
        expect(stopwatch.elapsed, lessThan(failFast));
        expect(server.requests, isEmpty);
      });

      test('in defaultHeaders: $what, at construction', () async {
        final server = await serve();
        expect(
          () => TypeSafeClient(
            apiKey: 'sk-test',
            baseUrl: server.url,
            defaultHeaders: headers,
          ),
          throwsArgumentError,
        );
      });
    }
  });

  group('S3: caller headers never override what the SDK owns', () {
    test('per-call x-typesafe-retry-count is not sent on attempt 0', () async {
      var calls = 0;
      final server = await serve((_, res) async {
        final ok = ++calls > 1;
        await respondJson(res, ok ? successBody : '{}', status: ok ? 200 : 503);
      });
      final client = h1Client(server.url, retryPolicy: quickRetry);

      await client.systemOne(
        state: ticket,
        questions: [billing],
        options: const RequestOptions(
          headers: {'x-typesafe-retry-count': '99'},
        ),
      );

      expect(
        server.requests.map((r) => r.header('x-typesafe-retry-count')),
        [null, '1'],
      );
    });

    test('a default X-TypeSafe-Retry-Count in any case is dropped', () async {
      final server = await serve();
      final client = h1Client(
        server.url,
        defaultHeaders: {'X-TypeSafe-Retry-Count': '7'},
      );

      await client.systemOne(state: ticket, questions: [billing]);

      expect(
        server.requests.single.headers,
        isNot(contains('x-typesafe-retry-count')),
      );
    });

    test('a caller content-type is not sent on GET', () async {
      final server = await serve((_, res) => respondJson(res, modelsBody));
      final client = h1Client(server.url);

      await client.listModels(
        options: const RequestOptions(headers: {'content-type': 'text/evil'}),
      );

      expect(server.requests.single.headers, isNot(contains('content-type')));
    });

    test('a caller host header does not redirect the virtual host', () async {
      final server = await serve();
      final client = h1Client(server.url);

      await client.systemOne(
        state: ticket,
        questions: [billing],
        options: const RequestOptions(headers: {'host': 'evil.example'}),
      );

      expect(
        server.requests.single.header('host'),
        '127.0.0.1:${server.port}',
      );
    });

    test('a caller content-length cannot truncate the body', () async {
      final server = await serve();
      final client = h1Client(server.url);

      final error = await failureOf(
        () => client.systemOne(
          state: ticket,
          questions: [billing],
          options: const RequestOptions(headers: {'content-length': '5'}),
        ),
      );

      expect(error, isNull);
      expect(server.requests.single.json, isA<Map<String, Object?>>());
    });
  });

  group('D12: close() with calls in flight', () {
    test(
      'lets them finish, without retrying on a closed client',
      () async {
        const serverDelay = Duration(milliseconds: 300);
        final server = await serve((_, res) async {
          await Future<void>.delayed(serverDelay);
          await respondJson(res, successBody);
        });
        final client = h1Client(server.url, retryPolicy: const RetryPolicy());

        final calls = [
          for (var i = 0; i < 3; i++)
            failureOf(
              () => client.systemOne(state: ticket, questions: [billing]),
            ),
        ];
        await eventually(() => server.requests.length == 3);
        client.close();
        final outcomes = await Future.wait(calls);

        // Graceful: each attempt already on the wire completes, and none is
        // killed and then retried against the closed client.
        expect(outcomes, everyElement(isNull));
        expect(server.requests, hasLength(3));
      },
    );
  });

  group('S8: a call after close()', () {
    test('fails fast without being retried', () async {
      final server = await serve();
      final client = h1Client(server.url, retryPolicy: const RetryPolicy())
        ..close();

      final stopwatch = Stopwatch()..start();
      final error = await failureOf(
        () => client.systemOne(state: ticket, questions: [billing]),
      );

      expect(error, anyOf(isA<TypeSafeException>(), isA<StateError>()));
      expect(stopwatch.elapsed, lessThan(failFast));
      expect(server.requests, isEmpty);
    });
  });
}

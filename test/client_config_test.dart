import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart' show onCancel;
import 'package:typesafe_ai_dart/src/env/env.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

void main() {
  group('ClientConfig.resolve', () {
    test('explicit values win and defaults fill the rest', () {
      final config = ClientConfig.resolve(apiKey: 'k');
      expect(config.apiKey, 'k');
      expect(config.defaultModel, anyOf('jev-latest', isNotEmpty));
      expect(config.timeout, const Duration(seconds: 10));
      expect(config.retryPolicy, const RetryPolicy());
      expect(config.defaultHeaders, isEmpty);
    });

    test('strips trailing slashes from the base URL', () {
      final config = ClientConfig.resolve(
        apiKey: 'k',
        baseUrl: 'https://proxy.test/api///',
      );
      expect(config.baseUrl.toString(), 'https://proxy.test/api');
    });

    test(
      'throws without an API key',
      () {
        expect(ClientConfig.resolve, throwsArgumentError);
        expect(() => ClientConfig.resolve(apiKey: ''), throwsArgumentError);
      },
      skip: readEnv(ClientConfig.apiKeyVariable) != null
          ? 'TYPESAFE_API_KEY is set in this environment'
          : false,
    );

    test('validates fields', () {
      expect(
        () => ClientConfig.resolve(apiKey: 'k', baseUrl: 'not a url'),
        throwsArgumentError,
      );
      expect(
        () => ClientConfig.resolve(apiKey: 'k', baseUrl: 'ftp://x'),
        throwsArgumentError,
      );
      expect(
        () => ClientConfig.resolve(apiKey: 'k', timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => ClientConfig.resolve(apiKey: 'k', totalTimeout: Duration.zero),
        throwsArgumentError,
      );
      expect(ClientConfig.resolve(apiKey: 'k').totalTimeout, isNull);
    });

    test('totalTimeout is kept and shows in toString', () {
      const total = Duration(seconds: 15);
      final a = ClientConfig.resolve(apiKey: 'k', totalTimeout: total);
      expect(a.totalTimeout, total);
      expect(a.toString(), contains('totalTimeout: 0:00:15.000000'));
    });

    test('http2 is off by default, needs https and shows in toString', () {
      expect(ClientConfig.resolve(apiKey: 'k').http2, isFalse);
      final on = ClientConfig.resolve(
        apiKey: 'k',
        baseUrl: 'https://x',
        http2: true,
      );
      expect(on.http2, isTrue);
      expect(on.toString(), contains('http2: true'));
      expect(
        () => ClientConfig.resolve(
          apiKey: 'k',
          baseUrl: 'http://localhost:8080',
          http2: true,
        ),
        throwsArgumentError,
      );
    });

    test('http2 with an injected httpClient is rejected', () {
      expect(
        () => TypeSafeClient(
          apiKey: 'k',
          baseUrl: 'https://x',
          http2: true,
          httpClient: MockClient((_) async => http.Response('', 200)),
        ),
        throwsArgumentError,
      );
    });

    test('default headers are unmodifiable', () {
      final a = ClientConfig.resolve(apiKey: 'k', baseUrl: 'https://x');
      expect(() => a.defaultHeaders['x'] = 'y', throwsUnsupportedError);
    });
  });

  group('CancelToken', () {
    test('cancels once and reports the reason', () {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      expect(token.throwIfCancelled, returnsNormally);
      token
        ..cancel('first')
        ..cancel('second');
      expect(token.isCancelled, isTrue);
      expect(token.reason, 'first');
      expect(token.whenCancelled, completes);
      expect(
        token.throwIfCancelled,
        throwsA(isA<TypeSafeCancelledException>()),
      );
    });

    test('onCancel runs listeners once and can unregister them', () {
      final token = CancelToken();
      final calls = <String>[];
      onCancel(token, () => calls.add('kept'));
      onCancel(token, () => calls.add('dropped'))();
      token
        ..cancel()
        ..cancel();
      expect(calls, ['kept']);
      onCancel(token, () => calls.add('late'));
      expect(calls, ['kept', 'late']);
    });
  });
}

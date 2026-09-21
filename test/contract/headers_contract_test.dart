import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');

Future<SystemOneResponse> ask(TypeSafeClient client, {RequestOptions? o}) =>
    client.systemOne(state: 'text', questions: [billing], options: o);

void main() {
  group('request headers', () {
    test('SDK headers beat default and per-call ones, in any case', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      final client = clientFor(
        scripted,
        defaultHeaders: {
          'Authorization': 'Bearer evil',
          'User-Agent': 'spoof',
          'X-App': 'default',
          'X-Keep': 'kept',
        },
      );
      await ask(
        client,
        o: const RequestOptions(
          headers: {
            'x-app': 'call',
            'ACCEPT': 'text/html',
            'X-TypeSafe-SDK': 'spoof',
          },
        ),
      );
      final headers = scripted.requests.single.headers;
      expect(headers['authorization'], 'Bearer sk-test');
      expect(headers['user-agent'], 'typesafe_ai_dart/$packageVersion');
      expect(headers['x-typesafe-sdk'], 'typesafe_ai_dart/$packageVersion');
      expect(headers['accept'], 'application/json');
      expect(headers['x-app'], 'call');
      expect(headers['x-keep'], 'kept');
    });

    test('N5: SDK headers win when a default and a per-call header differ '
        'only in case', () async {
      final scripted = ScriptedClient([
        const Step(503),
        const Step(200, body: successBody),
      ]);
      await ask(
        clientFor(
          scripted,
          defaultHeaders: {
            'authorization': 'Bearer default',
            'x-typesafe-retry-count': '7',
          },
        ),
        o: const RequestOptions(
          headers: {
            'Authorization': 'Bearer caller',
            'X-TypeSafe-Retry-Count': '9',
          },
        ),
      );
      expect(
        [for (final r in scripted.requests) r.headers['authorization']],
        ['Bearer sk-test', 'Bearer sk-test'],
      );
      expect(scripted.requests.last.headers['x-typesafe-retry-count'], '1');
    });

    test('per-call headers never reach another concurrent call', () async {
      final scripted = ScriptedClient([
        const Step(200, body: successBody, delay: Duration(milliseconds: 5)),
      ]);
      final client = clientFor(scripted);
      await Future.wait([
        for (var i = 0; i < 50; i++)
          ask(
            client,
            o: i.isEven ? RequestOptions(headers: {'x-call': '$i'}) : null,
          ),
      ]);
      final seen = [for (final r in scripted.requests) r.headers['x-call']];
      expect(seen.whereType<String>().toSet(), hasLength(25));
      expect(seen.where((v) => v == null), hasLength(25));
    });

    test('S3: a caller cannot send x-typesafe-retry-count on the first '
        'attempt', () async {
      final scripted = ScriptedClient([
        const Step(503),
        const Step(200, body: successBody),
      ]);
      await ask(
        clientFor(scripted, defaultHeaders: {'x-typesafe-retry-count': '7'}),
        o: const RequestOptions(headers: {'X-TypeSafe-Retry-Count': '9'}),
      );
      expect(
        [
          for (final r in scripted.requests)
            r.headers['x-typesafe-retry-count'],
        ],
        [null, '1'],
      );
    });

    test('S3: a caller cannot send content-type on a GET', () async {
      final scripted = ScriptedClient([const Step(200, body: modelsBody)]);
      await clientFor(scripted).listModels(
        options: const RequestOptions(headers: {'content-type': 'text/xml'}),
      );
      expect(scripted.requests.single.headers['content-type'], isNull);
    });

    test(
      'S3: framing and hop-by-hop headers from callers are dropped',
      () async {
        const framing = {
          'host': 'evil.test',
          'content-length': '1',
          'connection': 'close',
          'transfer-encoding': 'chunked',
          'accept-encoding': 'gzip',
        };
        final scripted = ScriptedClient([const Step(200, body: successBody)]);
        await ask(
          clientFor(scripted, defaultHeaders: framing),
          o: const RequestOptions(headers: framing),
        );
        final headers = scripted.requests.single.headers;
        for (final name in framing.keys) {
          expect(headers[name], isNull, reason: name);
        }
      },
    );
  });

  group('Finding LC: response header names are matched in any case', () {
    test('the request id of a success', () async {
      final scripted = ScriptedClient([
        const Step(
          200,
          body: successBody,
          headers: {'X-TypeSafe-Request-Id': 'req_1'},
        ),
      ]);
      expect((await ask(clientFor(scripted))).requestId, 'req_1');
    });

    test('the request id, Retry-After and headers of an error', () async {
      final scripted = ScriptedClient([
        const Step(
          429,
          headers: {'X-TypeSafe-Request-Id': 'req_2', 'Retry-After-Ms': '1234'},
        ),
      ]);
      await expectLater(
        ask(clientFor(scripted, retryPolicy: RetryPolicy.none)),
        throwsA(
          isA<RateLimitException>()
              .having((e) => e.requestId, 'requestId', 'req_2')
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(milliseconds: 1234),
              )
              .having(
                (e) => e.headers.keys,
                'header names',
                everyElement(matches(RegExp(r'^[^A-Z]*$'))),
              ),
        ),
      );
    });
  });

  group('D2: the API key never leaks', () {
    const key = 'sk-secret-4242';

    test('not through ClientConfig.toString', () {
      final config = ClientConfig(
        apiKey: key,
        baseUrl: Uri.parse('https://api.test'),
        defaultModel: 'jev',
        defaultHeaders: const {'x-token': key},
      );
      expect('$config', isNot(contains(key)));
    });

    test('not through any failure a call can raise', () async {
      final steps = [
        const Step(401, body: '{"error":"bad key"}'),
        const Step(500, body: 'boom'),
        Step.failing(http.ClientException('refused')),
        const Step(200, body: '{"model":1}'),
        const Step(200, body: 'not json'),
      ];
      for (final step in steps) {
        final client = TypeSafeClient(
          apiKey: key,
          baseUrl: 'https://api.test',
          retryPolicy: RetryPolicy.none,
          httpClient: ScriptedClient([step]).client,
        );
        final error = await ask(
          client,
        ).then<Object?>((_) => null, onError: (Object e) => e);
        expect(error, isA<TypeSafeException>());
        expect('$error', isNot(contains(key)));
      }
    });

    for (final (name, bad) in [
      ('a line break', '$key\n'),
      ('CR/LF injection', '$key\r\nx-evil: 1'),
      ('a non-ASCII character', 'sk-sécret-4242'),
    ]) {
      test('an API key with $name is rejected up front, unechoed', () {
        expect(
          () => ClientConfig(
            apiKey: bad,
            baseUrl: Uri.parse('https://api.test'),
            defaultModel: 'jev',
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'toString',
              allOf(isNot(contains('secret')), isNot(contains('sécret'))),
            ),
          ),
        );
      });
    }

    test('a bad default header name or value is an ArgumentError', () {
      for (final headers in [
        {'x-a': 'v\r\nx-evil: 1'},
        {'x-a': 'café'},
        {'bad name': 'v'},
        {'': 'v'},
      ]) {
        expect(
          () => ClientConfig(
            apiKey: 'k',
            baseUrl: Uri.parse('https://api.test'),
            defaultModel: 'jev',
            defaultHeaders: headers,
          ),
          throwsArgumentError,
          reason: '$headers',
        );
      }
    });

    test('a bad per-call header fails the call before sending', () async {
      var sent = 0;
      final client = TypeSafeClient(
        apiKey: 'k',
        baseUrl: 'https://api.test',
        httpClient: MockClient((request) async {
          sent++;
          return http.Response(successBody, 200);
        }),
      );
      await expectLater(
        ask(client, o: const RequestOptions(headers: {'x-a': 'v\nx-b: 1'})),
        throwsArgumentError,
      );
      expect(sent, 0);
    });
  });

  group('Finding HOST: an unusable base URL is an ArgumentError', () {
    for (final url in [
      'https://',
      'https:///v1',
      'https://[x',
      'ftp://h',
      'h',
    ]) {
      test(url, () {
        expect(
          () => ClientConfig.resolve(apiKey: 'k', baseUrl: url),
          throwsArgumentError,
        );
      });
    }
  });
}

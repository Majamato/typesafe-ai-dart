import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/env/env.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_runner.dart';
import 'package:typesafe_ai_dart/src/http/http_transport.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

final _noul = Noul(id: 'n', instructions: 'x');

void main() {
  group('every exception names its class and message in toString', () {
    const endpoint = Endpoint.systemOne;
    final cases = <TypeSafeException, String>{
      const TypeSafeConnectionException('down'): 'TypeSafeConnectionException',
      const TypeSafeTimeoutException('slow', timeout: Duration(seconds: 1)):
          'TypeSafeTimeoutException',
      const TypeSafeCancelledException('bye'): 'TypeSafeCancelledException',
      const ResponseValidationException('bad', fieldPath: 'a.b'):
          'ResponseValidationException at a.b',
      const NotFoundException(
        'gone',
        statusCode: 404,
        body: '',
        headers: {},
        endpoint: endpoint,
        requestId: 'req_1',
      ): 'NotFoundException: HTTP 404 from POST /v1/systemone, request req_1',
    };
    for (final MapEntry(key: error, value: expected) in cases.entries) {
      test(expected.split(' ').first, () {
        expect('$error', startsWith(expected));
        expect('$error', contains(error.message));
      });
    }
  });

  test('ModelCard round-trips through toJson and prints its name', () {
    const card = ModelCard(
      name: 'jev-1',
      description: 'd',
      releaseDate: '2026-01-01',
    );
    expect(ModelCard.fromJson(card.toJson()), card);
    expect('$card', allOf(contains('jev-1'), contains('2026-01-01')));
  });

  test('questions and requests print their kind, ids and model', () {
    expect('$_noul', 'noul(n)');
    final request = SystemOneRequest(
      state: 's',
      questions: [_noul],
      model: 'jev-9',
    );
    expect('$request', 'SystemOneRequest(model: jev-9, questions: [n])');
  });

  test('ClientConfig rejects an empty key or default model', () {
    ClientConfig build({String apiKey = 'k', String model = 'm'}) =>
        ClientConfig(
          apiKey: apiKey,
          baseUrl: Uri.parse('https://api.test'),
          defaultModel: model,
        );
    expect(() => build(apiKey: ''), throwsArgumentError);
    expect(() => build(model: ''), throwsArgumentError);
    expect(build, returnsNormally);
  });

  test('a top-level state of the wrong type names the type, not the value', () {
    expect(
      () => SystemOneRequest(state: 42, questions: [_noul]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '$e',
          'text',
          allOf(contains('int'), isNot(contains('42'))),
        ),
      ),
    );
  });

  test('a JsonEncodable whose toJson holds non-JSON names the inner type', () {
    expect(
      () => SystemOneRequest(state: [_BadEncodable()], questions: [_noul]),
      throwsA(
        isA<ArgumentError>().having((e) => '$e', 'text', contains('DateTime')),
      ),
    );
  });

  test('readEnv returns set variables and null for unset ones', () {
    expect(readEnv('PATH'), Platform.environment['PATH']);
    expect(readEnv('TYPESAFE_TEST_SURELY_UNSET_7F3A'), isNull);
  });

  test('onCancel on a cancelled token runs at once and unregisters as a '
      'no-op', () {
    final token = CancelToken()..cancel();
    var runs = 0;
    final unregister = onCancel(token, () => runs++);
    expect(runs, 1);
    unregister();
    expect(token.listenerCount, 0);
  });

  test('a backoff that overshoots the budget ends the call with it', () async {
    var now = Duration.zero;
    final runner = RetryRunner(
      clock: () => now,
      // A sleep that wakes late, as a busy event loop can.
      sleep: (delay) async => now += delay * 3,
    );
    const budget = Duration(seconds: 1);
    await expectLater(
      runner.run(
        policy: const RetryPolicy(
          backoffInitial: Duration(milliseconds: 400),
          jitter: 0,
        ),
        endpoint: Endpoint.systemOne,
        timeout: const Duration(seconds: 10),
        totalTimeout: budget,
        attempt: (attempt, timeout) async => RawResponse(
          statusCode: 503,
          headers: const <String, String>{},
          bodyBytes: successBody.codeUnits.toList().asUint8List(),
        ),
      ),
      throwsA(
        isA<TypeSafeTimeoutException>().having(
          (e) => e.timeout,
          'timeout',
          budget,
        ),
      ),
    );
  });

  test('a client throwing a raw socket error is a connection error', () async {
    final transport = HttpTransport(
      client: _SocketFailingClient(),
      baseUrl: Uri.parse('https://api.test'),
    );
    addTearDown(transport.close);
    await expectLater(
      transport.send(
        endpoint: Endpoint.systemOne,
        headers: const {},
        timeout: const Duration(seconds: 1),
      ),
      throwsA(
        isA<TypeSafeConnectionException>().having(
          (e) => e.cause,
          'cause',
          isA<SocketException>(),
        ),
      ),
    );
  });
}

extension on List<int> {
  Uint8List asUint8List() => Uint8List.fromList(this);
}

/// A helper whose JSON form holds a value JSON can't carry.
final class _BadEncodable implements JsonEncodable {
  @override
  Object? toJson() => {'at': DateTime.utc(2026)};
}

final class _SocketFailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(const SocketException('Connection refused'));
}

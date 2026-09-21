import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

/// Answers per request number: every fourth call fails once with 503, every
/// fourth answers too late for its timeout, and the rest succeed at once.
final class RecordingClient extends http.BaseClient {
  /// Every request as the transport built it, abort trigger included.
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final call = request.headers['x-call']!;
    final n = int.parse(call);
    final retry = request.headers['x-typesafe-retry-count'];
    if (n % 4 == 1) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    final status = n % 4 == 2 && retry == null ? 503 : 200;
    return http.StreamedResponse(
      Stream.value(successBody.codeUnits),
      status,
      request: request,
    );
  }
}

final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');

void main() {
  test('a token shared by 10 k finished calls keeps no listener', () async {
    final token = CancelToken();
    final recorder = RecordingClient();
    final client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: 'https://api.test',
      retryPolicy: fastRetry.copyWith(retryOnTimeout: false),
      httpClient: recorder,
    );
    final outcomes = <String, int>{};
    for (var batch = 0; batch < 20; batch++) {
      await Future.wait([
        for (var i = batch * 500; i < (batch + 1) * 500; i++)
          client
              .systemOne(
                state: 's',
                questions: [billing],
                options: RequestOptions(
                  cancelToken: token,
                  headers: {'x-call': '$i'},
                  timeout: i % 4 == 1
                      ? const Duration(milliseconds: 5)
                      : const Duration(seconds: 5),
                ),
              )
              .then<String>(
                (_) => 'ok',
                onError: (Object e) => e.runtimeType.toString(),
              )
              .then(
                (kind) =>
                    outcomes.update(kind, (n) => n + 1, ifAbsent: () => 1),
              ),
      ]);
    }
    expect(outcomes, {'ok': 7500, 'TypeSafeTimeoutException': 2500});
    expect(recorder.requests, hasLength(12500));
    expect(token.listenerCount, 0);
    expect(client.pendingDeadlines, 0);

    final triggers = [
      for (final request in recorder.requests)
        (request as http.Abortable).abortTrigger!,
    ];
    var fired = 0;
    for (final trigger in triggers) {
      unawaited(trigger.then((_) => fired++));
    }
    await pumpEventQueue();
    final firedBefore = fired;
    token.cancel('late');
    await pumpEventQueue();
    expect(fired, firedBefore, reason: 'a late cancel reached a settled call');
    client.close();
  });

  test(
    'the first cancel reason wins and later calls fail before sending',
    () async {
      final token = CancelToken()
        ..cancel('first')
        ..cancel('second');
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await expectLater(
        clientFor(scripted).systemOne(
          state: 's',
          questions: [billing],
          options: RequestOptions(cancelToken: token),
        ),
        throwsA(
          isA<TypeSafeCancelledException>().having(
            (e) => e.reason,
            'r',
            'first',
          ),
        ),
      );
      expect(scripted.requests, isEmpty);
      expect(token.listenerCount, 0);
    },
  );

  test('a cancel mid-call stops further retries', () async {
    final token = CancelToken();
    final scripted = ScriptedClient([
      const Step(503, delay: Duration(milliseconds: 20)),
    ]);
    final call = clientFor(scripted).systemOne(
      state: 's',
      questions: [billing],
      options: RequestOptions(cancelToken: token),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    token.cancel();
    await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(scripted.requests, hasLength(1));
    expect(token.listenerCount, 0);
  });
}

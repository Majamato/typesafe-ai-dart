import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http2/client.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/default_client.dart';
import 'package:typesafe_ai_dart/src/http/http_transport.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// How [StallingClient] behaves once a request arrives.
enum Stall {
  /// Never answers; aborting fails the send, as `IOClient` does.
  beforeHeaders,

  /// Answers at once, then never finishes the body.
  duringBody,

  /// Ignores the abort trigger and answers after [StallingClient.lateBy].
  ignoresAbort,
}

/// A client that stalls a request so a test can abort it, recording what
/// the abort reached.
final class StallingClient extends http.BaseClient {
  StallingClient(this.stall);

  final Stall stall;
  static const lateBy = Duration(milliseconds: 60);

  /// Whether the request's `abortTrigger` fired.
  bool aborted = false;

  /// Whether the response body stream was cancelled.
  bool bodyCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final trigger = (request as http.Abortable).abortTrigger!;
    unawaited(trigger.then((_) => aborted = true));
    final body = StreamController<List<int>>(
      onCancel: () => bodyCancelled = true,
    )..add([0x7B]);
    http.StreamedResponse respond() =>
        http.StreamedResponse(body.stream, 200, request: request);
    switch (stall) {
      case Stall.beforeHeaders:
        await trigger;
        throw http.RequestAbortedException(request.url);
      case Stall.duringBody:
        return respond();
      case Stall.ignoresAbort:
        await Future<void>.delayed(lateBy);
        return respond();
    }
  }
}

void main() {
  final baseUrl = Uri.parse('https://api.test/v1/');

  Future<RawResponse> send(
    http.Client client, {
    Duration timeout = const Duration(milliseconds: 20),
    CancelToken? cancelToken,
  }) => HttpTransport(client: client, baseUrl: baseUrl).send(
    endpoint: Endpoint.systemOne,
    headers: const {},
    timeout: timeout,
    cancelToken: cancelToken,
  );

  final timesOut = throwsA(isA<TypeSafeTimeoutException>());

  test('resolves each endpoint once under the base path', () {
    final transport = HttpTransport(client: http.Client(), baseUrl: baseUrl);
    expect(
      transport.uriFor(Endpoint.systemOne).toString(),
      'https://api.test/v1/v1/systemone',
    );
    expect(
      transport.uriFor(Endpoint.listModels),
      same(transport.uriFor(Endpoint.listModels)),
    );
  });

  test('a timeout before headers aborts the request', () async {
    final client = StallingClient(Stall.beforeHeaders);
    await expectLater(send(client), timesOut);
    await pumpEventQueue();
    expect(client.aborted, isTrue);
  });

  test('a timeout while reading the body cancels the stream', () async {
    final client = StallingClient(Stall.duringBody);
    await expectLater(send(client), timesOut);
    expect(client.aborted, isTrue);
    expect(client.bodyCancelled, isTrue);
  });

  test('a cancel aborts the request and carries its reason', () async {
    final client = StallingClient(Stall.duringBody);
    final token = CancelToken();
    final future = send(
      client,
      timeout: const Duration(seconds: 5),
      cancelToken: token,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    token.cancel('shutdown');
    await expectLater(
      future,
      throwsA(
        isA<TypeSafeCancelledException>().having(
          (e) => e.reason,
          'reason',
          'shutdown',
        ),
      ),
    );
    expect(client.bodyCancelled, isTrue);
  });

  test('a client that ignores the abort still times out on time', () async {
    final client = StallingClient(Stall.ignoresAbort);
    final stopwatch = Stopwatch()..start();
    await expectLater(send(client), timesOut);
    expect(stopwatch.elapsed, lessThan(StallingClient.lateBy));
    await Future<void>.delayed(StallingClient.lateBy * 2);
    expect(client.bodyCancelled, isTrue, reason: 'late body is discarded');
  });

  test('client failures become connection exceptions', () async {
    final client = _FailingClient();
    await expectLater(
      send(client),
      throwsA(
        isA<TypeSafeConnectionException>()
            .having((e) => e, 'type', isNot(isA<TypeSafeTimeoutException>()))
            .having((e) => e.cause, 'cause', isA<http.ClientException>()),
      ),
    );
  });

  test('a client that throws synchronously is wrapped too', () async {
    await expectLater(
      send(_ThrowingClient()),
      throwsA(isA<TypeSafeConnectionException>()),
    );
  });

  test('the default is HTTP/1.1, and http2 opts into pooled HTTP/2', () {
    final h1 = defaultHttpClient(http2: false);
    final h2 = defaultHttpClient(http2: true);
    expect(h1.client, isA<IOClient>());
    // Checks the opt-in builds the experimental upstream client.
    // ignore: experimental_member_use
    expect(h2.client, isA<Http2Client>());
    h1.close();
    h2.close();
  });
}

final class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw http.ClientException('no route', request.url);
}

final class _FailingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Future.error(http.ClientException('refused', request.url));
}

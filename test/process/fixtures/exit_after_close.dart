// Runs one lifecycle scenario, closes the client, prints `closed` and
// returns from main; the parent times how long the VM then takes to exit.
// Arguments: <scenario> [port].
import 'dart:async';
import 'dart:io';

import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

Future<void> main(List<String> args) async {
  final scenario = args[0];
  final port = args.length > 1 ? args[1] : '0';
  if (scenario.startsWith('h2')) {
    SecurityContext.defaultContext.setTrustedCertificatesBytes(
      File('test/io/support/certs/ca.pem').readAsBytesSync(),
    );
  }
  final question = Noul(id: 'billing', instructions: 'Is `t` billing?');
  TypeSafeClient client(String scheme, {Duration? timeout}) => TypeSafeClient(
    apiKey: 'sk-test',
    baseUrl: scheme == 'https'
        ? 'https://localhost:$port'
        : 'http://127.0.0.1:$port',
    http2: scheme == 'https',
    timeout: timeout ?? const Duration(seconds: 5),
  );
  Future<void> call(
    TypeSafeClient c, {
    RequestOptions? options,
  }) async {
    try {
      await c.systemOne(state: 'x', questions: [question], options: options);
    } on TypeSafeException catch (e) {
      stdout.writeln('failed: ${e.runtimeType}');
    }
  }

  switch (scenario) {
    case 'idle':
      TypeSafeClient(apiKey: 'sk-test').close();
    case 'h1_calls' || 'h2_calls':
      final c = client(scenario == 'h1_calls' ? 'http' : 'https');
      for (var i = 0; i < 5; i++) {
        await call(c);
      }
      c.close();
    case 'h1_timeout' || 'h2_timeout':
      final c = client(
        scenario == 'h1_timeout' ? 'http' : 'https',
        timeout: const Duration(milliseconds: 200),
      );
      await call(
        c,
        options: const RequestOptions(retryPolicy: RetryPolicy.none),
      );
      c.close();
    case 'h1_cancel_in_backoff':
      final c = client('http');
      final token = CancelToken();
      Timer(const Duration(milliseconds: 300), token.cancel);
      await call(c, options: RequestOptions(cancelToken: token));
      c.close();
    default:
      throw ArgumentError.value(scenario, 'scenario');
  }
  stdout.writeln('closed');
}

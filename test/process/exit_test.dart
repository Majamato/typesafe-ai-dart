@Tags(['subprocess'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../helpers/h2_server.dart';
import '../helpers/mock_transport.dart';
import 'support.dart';

/// How long the VM may take to exit once the fixture has closed its client.
const _exitBudget = Duration(seconds: 2);

/// Starts scenario [scenario] of the `exit_after_close` fixture and returns
/// how long the VM took to exit after printing `closed`.
Future<Duration> _timeToExit(String scenario, {int? port}) async {
  final process = await startFixture(
    'exit_after_close',
    args: [scenario, if (port != null) '$port'],
  );
  final closed = Completer<Stopwatch>();
  final output = StringBuffer();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      output.writeln(line);
      if (line == 'closed' && !closed.isCompleted) {
        closed.complete(Stopwatch()..start());
      }
    },
  );
  process.stderr.transform(utf8.decoder).listen(output.write);
  final stopwatch = await closed.future.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      fail('scenario never closed its client:\n$output');
    },
  );
  final exitCode = await process.exitCode.timeout(
    const Duration(seconds: 45),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  expect(exitCode, 0, reason: '$output');
  return stopwatch.elapsed;
}

void main() {
  late HttpServer server;
  late void Function(HttpRequest request) handler;
  final held = <HttpRequest>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((request) => handler(request));
  });

  tearDown(() async {
    held.clear();
    await server.close(force: true);
  });

  void respond(
    HttpRequest request,
    int status,
    String body, [
    Map<String, String> headers = const {},
  ]) {
    request.response.statusCode = status;
    headers.forEach(request.response.headers.set);
    request.response
      ..write(body)
      ..close().ignore();
  }

  test('an idle client lets the VM exit at once', () async {
    expect(await _timeToExit('idle'), lessThan(_exitBudget));
  });

  test('a client that made HTTP/1.1 calls lets the VM exit', () async {
    handler = (request) => respond(request, 200, successBody);
    expect(
      await _timeToExit('h1_calls', port: server.port),
      lessThan(_exitBudget),
    );
  });

  test('a client whose call timed out lets the VM exit', () async {
    handler = held.add;
    expect(
      await _timeToExit('h1_timeout', port: server.port),
      lessThan(_exitBudget),
    );
  });

  test(
    'S5: a cancel during a long Retry-After backoff lets the VM exit',
    () async {
      handler = (request) => respond(
        request,
        429,
        '{"error":"slow down"}',
        {'retry-after': '30'},
      );
      expect(
        await _timeToExit('h1_cancel_in_backoff', port: server.port),
        lessThan(_exitBudget),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('over HTTP/2', () {
    test('a client that made calls lets the VM exit', () async {
      final h2 = await H2TestServer.start();
      addTearDown(h2.close);
      expect(
        await _timeToExit('h2_calls', port: h2.port),
        lessThan(_exitBudget),
      );
    });

    test(
      'known issue D4: a call that timed out before headers lets the VM '
      'exit',
      () async {
        final h2 = await H2TestServer.start(handler: (_) {});
        addTearDown(h2.close);
        expect(
          await _timeToExit('h2_timeout', port: h2.port),
          lessThan(_exitBudget),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip:
          "Known issue D4 (Http2Client can't abort before headers): the VM "
          'stays alive; see doc/design.md "Known limitations"',
    );
  });
}

@Tags(['h2'])
library;

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/certs.dart';
import '../../helpers/h2_server.dart';

final _question = Noul(id: h2QuestionId, instructions: 'Is `x` true?');
const _timeout = Duration(milliseconds: 300);
const _slack = Duration(seconds: 1);

void main() {
  setUpAll(trustTestCa);

  late H2TestServer server;
  late TypeSafeClient client;

  setUp(() async {
    server = await H2TestServer.start()
      ..stallHandshakes = true;
    client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: server.baseUrl,
      http2: true,
      defaultModel: 'jev-test',
      timeout: _timeout,
      retryPolicy: RetryPolicy.none,
    );
  });

  tearDown(() async {
    await server.close();
    client.close();
  });

  Future<SystemOneResponse> call(String state) =>
      client.systemOne(state: state, questions: [_question]);

  final timesOut = throwsA(isA<TypeSafeTimeoutException>());

  test('a stalled TLS handshake makes a call time out on time', () async {
    final stopwatch = Stopwatch()..start();
    await expectLater(call('first'), timesOut);
    expect(stopwatch.elapsed, greaterThanOrEqualTo(_timeout));
    expect(stopwatch.elapsed, lessThan(_timeout + _slack));
    expect(server.stalledCount, 1);
    expect(client.pendingDeadlines, 0);
  }, tags: ['timing']);

  test('calls recover once a stalled handshake completes', () async {
    await expectLater(call('first'), timesOut);

    server
      ..stallHandshakes = false
      ..releaseStalled();
    expect((await call('second')).model, 'second');
  });

  // Known issues N3 and S10 live in package:http2's Http2Client, which the
  // SDK can't reach into; "Known limitations" in doc/design.md documents
  // them. These tests pin today's behaviour, so an upstream fix shows up as a
  // failure.
  test(
    'known issue N3: a call that timed out during a slow handshake is still '
    'sent once the handshake completes',
    () async {
      await expectLater(call('first'), timesOut);

      server
        ..stallHandshakes = false
        ..releaseStalled();
      await call('second');
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final states = [
        for (final exchange in server.exchanges) stateOf(await exchange.body),
      ];
      expect(
        states,
        contains('first'),
        reason: 'fixed upstream? See doc/design.md "Known limitations"',
      );
    },
  );

  test(
    'known issue S10: a handshake that never completes blocks later calls',
    () async {
      await expectLater(call('first'), timesOut);

      // New connections are served normally; the first stays stuck.
      server.stallHandshakes = false;
      final response = await call('second').then<Object>(
        (r) => r,
        onError: (Object e) => e,
      );
      expect(
        response,
        isA<TypeSafeTimeoutException>(),
        reason: 'fixed upstream? See doc/design.md "Known limitations"',
      );
    },
  );

  group('with 50 handshakes stalled', () {
    Future<List<Object?>> burst(String prefix, int count) => Future.wait([
      for (var i = 0; i < count; i++)
        call('$prefix-$i').then<Object?>((r) => r, onError: (Object e) => e),
    ]);

    // Http2Client queues up to 100 calls on a connection still dialing and
    // dials at most 50 at once. Burst until no burst dials anything new.
    Future<void> stallFiftyDials() async {
      var before = -1;
      for (var i = 0; i < 10 && server.accepted != before; i++) {
        before = server.accepted;
        final outcomes = await burst('stuck-$i', 1000);
        expect(outcomes, everyElement(isA<TypeSafeTimeoutException>()));
      }
      expect(server.accepted, before, reason: 'dialing stopped');
      expect(server.stalledCount, greaterThanOrEqualTo(50));
    }

    test('calls still fail within their timeout', () async {
      await stallFiftyDials();

      final stopwatch = Stopwatch()..start();
      await expectLater(call('late'), timesOut);
      expect(stopwatch.elapsed, lessThan(_timeout + _slack));
      expect(client.pendingDeadlines, 0);
    }, tags: ['timing']);

    test(
      'known issue S10: calls never recover, even once the server '
      'handshakes new connections',
      () async {
        await stallFiftyDials();
        final stuck = server.accepted;

        server.stallHandshakes = false;
        final outcomes = [
          ...await burst('after', 300),
          ...await burst('later', 300),
        ];
        // The 50 stuck handshakes hold Http2Client's whole handshake gate.
        expect(
          server.accepted,
          stuck,
          reason: 'fixed upstream? See doc/design.md "Known limitations"',
        );
        expect(outcomes, everyElement(isA<TypeSafeTimeoutException>()));
      },
    );
  });
}

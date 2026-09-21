import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';
import 'fake_time.dart';

const ms = Duration(milliseconds: 1);
const s = Duration(seconds: 1);

final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');
const state = {'ticket': 'Charged twice'};

Future<SystemOneResponse> ask(TypeSafeClient client, {RequestOptions? o}) =>
    client.systemOne(state: state, questions: [billing], options: o);

String letters(List<TypeSafeEvent> events) => events
    .map(
      (e) => switch (e) {
        AttemptStarted() => 'S',
        AttemptResponded() => 'R',
        AttemptFailed() => 'F',
        RetryScheduled() => 'Q',
        CallFinished() => 'C',
      },
    )
    .join();

void main() {
  group('timing on a fake clock', () {
    test('elapsed, delay and usage are exact', () {
      fakeAsync((async) {
        final events = <TypeSafeEvent>[];
        final api = FakeTimeApi(
          async,
          [
            const Reply(503, after: Duration(milliseconds: 100), body: ''),
            const Reply(200, after: Duration(milliseconds: 100)),
          ],
          retryPolicy: const RetryPolicy(jitter: 0),
          onEvent: events.add,
        );
        final result = api.settle(ask);
        expect(result.value, isNotNull);

        expect(letters(events), 'SRQSRC');
        expect((events[0] as AttemptStarted).timeout, s * 10);
        expect((events[1] as AttemptResponded).elapsed, ms * 100);
        expect((events[2] as RetryScheduled).delay, ms * 500);
        expect((events[4] as AttemptResponded).elapsed, ms * 100);
        final finished = events[5] as CallFinished;
        expect(finished.elapsed, ms * 700);
        expect(finished.usage, const Usage(inputTokens: 120, outputTokens: 0));
      });
    });

    test('a clamped attempt reports its clamped timeout, the call the '
        'budget', () {
      fakeAsync((async) {
        final events = <TypeSafeEvent>[];
        final api = FakeTimeApi(
          async,
          [const Reply.never()],
          totalTimeout: s * 15,
          retryPolicy: const RetryPolicy(jitter: 0),
          onEvent: events.add,
        );
        final result = api.settle(ask);
        expect(result.error, isA<TypeSafeTimeoutException>());

        expect(letters(events), 'SFQSFC');
        expect((events[0] as AttemptStarted).timeout, s * 10);
        expect((events[1] as AttemptFailed).elapsed, s * 10);
        expect((events[2] as RetryScheduled).delay, ms * 500);
        expect((events[3] as AttemptStarted).timeout, s * 4 + ms * 500);
        final failed = events[4] as AttemptFailed;
        expect(failed.elapsed, s * 4 + ms * 500);
        expect(
          (failed.error as TypeSafeTimeoutException).timeout,
          s * 4 + ms * 500,
        );
        final finished = events[5] as CallFinished;
        expect(finished.attempts, 2);
        expect(finished.elapsed, s * 15);
        expect(finished.statusCode, isNull);
        expect((finished.error! as TypeSafeTimeoutException).timeout, s * 15);
      });
    });
  });

  group("events run in the caller's zone", () {
    /// Runs [call] in a zone carrying `#req: 'abc'` and returns the value
    /// of `#req` each event saw.
    Future<List<Object?>> zonesSeen(
      List<Step> steps,
      Future<void> Function(TypeSafeClient client) call, {
      Duration timeout = const Duration(seconds: 5),
    }) async {
      final seen = <Object?>[];
      final client = clientFor(
        ScriptedClient(steps),
        timeout: timeout,
        onEvent: (_) => seen.add(Zone.current[#req]),
      );
      await runZoned(
        () => call(client).then<void>((_) {}, onError: (Object _) {}),
        zoneValues: {#req: 'abc'},
      );
      return seen;
    }

    test('for a timeout, fired from the timer zone', () async {
      final seen = await zonesSeen(
        [const Step(200, body: successBody, delay: Duration(seconds: 1))],
        (c) => ask(c, o: const RequestOptions(retryPolicy: RetryPolicy.none)),
        timeout: ms * 20,
      );
      expect(seen, ['abc', 'abc', 'abc']);
    });

    test('for a cancel issued from another zone', () async {
      final token = CancelToken();
      unawaited(
        runZoned(
          () => Future<void>.delayed(ms * 20, token.cancel),
          zoneValues: {#req: 'other'},
        ),
      );
      final seen = await zonesSeen(
        [const Step(200, body: successBody, delay: Duration(seconds: 1))],
        (c) => ask(c, o: RequestOptions(cancelToken: token)),
      );
      expect(seen, ['abc', 'abc', 'abc']);
    });

    test('for a retry after backoff', () async {
      final seen = await zonesSeen([
        const Step(503, body: 'down'),
        const Step(200, body: successBody),
      ], ask);
      expect(seen, List.filled(6, 'abc'));
    });
  });
}

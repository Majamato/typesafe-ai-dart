import 'dart:async';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/deadline_scheduler.dart';

void main() {
  const ms = Duration(milliseconds: 1);

  test('runs callbacks in deadline order, then goes idle', () async {
    final scheduler = DeadlineScheduler();
    final fired = <int>[];
    for (final n in [30, 10, 20]) {
      scheduler.schedule(ms * n, () => fired.add(n));
    }
    expect(scheduler.isIdle, isFalse);
    await Future<void>.delayed(ms * 60);
    expect(fired, [10, 20, 30]);
    expect(scheduler.isIdle, isTrue);
  });

  test('a cancelled callback never runs', () async {
    final scheduler = DeadlineScheduler();
    final fired = <String>[];
    scheduler.schedule(ms * 10, () => fired.add('cancelled')).cancel();
    final done = scheduler.schedule(ms * 20, () => fired.add('kept'));
    await Future<void>.delayed(ms * 50);
    done.cancel();
    expect(fired, ['kept']);
    expect(scheduler.isIdle, isTrue);
  });

  test('an earlier deadline re-arms the timer', () async {
    final scheduler = DeadlineScheduler();
    final fired = <String>[];
    final late = scheduler.schedule(
      const Duration(seconds: 30),
      () => fired.add('late'),
    );
    scheduler.schedule(ms * 10, () => fired.add('early'));
    await Future<void>.delayed(ms * 50);
    expect(fired, ['early']);
    late.cancel();
  });

  test('wakes once for a deadline between whole milliseconds', () async {
    for (final micros in [900, 1500]) {
      var timers = 0;
      var fired = false;
      // The scheduler times from the zone it was created in.
      runZoned(
        () => DeadlineScheduler().schedule(
          Duration(microseconds: micros),
          () => fired = true,
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            timers++;
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      await Future<void>.delayed(ms * 20);
      expect(fired, isTrue);
      expect(timers, 1, reason: 'an early wake re-arms a zero-length timer');
    }
  });

  test('close stops the timer once pending deadlines settle', () async {
    final scheduler = DeadlineScheduler();
    scheduler.schedule(const Duration(seconds: 30), () {}).cancel();
    expect(scheduler.isIdle, isFalse, reason: 'cancelling keeps the timer');
    final inFlight = scheduler.schedule(const Duration(seconds: 30), () {});
    scheduler.close();
    expect(scheduler.isIdle, isFalse, reason: 'a call is still in flight');
    inFlight.cancel();
    expect(scheduler.isIdle, isTrue);
  });
}

@Tags(['property'])
library;

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/deadline_scheduler.dart';

import '../helpers/fuzz.dart';

const us = Duration(microseconds: 1);

/// One scheduled callback as the reference model tracks it.
final class Entry {
  Entry(this.id, this.due, this.deadline);

  final int id;
  final Duration due;
  final Deadline deadline;
  bool cancelled = false;
  Duration? firedAt;
}

/// A random step: schedule (with a delay), cancel (an entry index), advance
/// (fake time) or close.
typedef Op = (String kind, int value);

List<Op> randomOps(Random random) => [
  for (var i = 10 + random.nextInt(60); i > 0; i--)
    switch (random.nextInt(10)) {
      < 4 => (
        'schedule',
        switch (random.nextInt(4)) {
          0 => 0,
          1 => random.nextInt(1000),
          2 => random.nextInt(50000),
          _ => 1000 * random.nextInt(100),
        },
      ),
      < 6 => ('cancel', random.nextInt(1 << 20)),
      < 9 => (
        'advance',
        random.nextBool() ? random.nextInt(2000) : random.nextInt(60000),
      ),
      _ => ('close', 0),
    },
];

void main() {
  test(
    'callbacks run once, in due order, never early and within 1 ms',
    () async {
      await forAll(randomOps, (ops) {
        fakeAsync((async) {
          final scheduler = DeadlineScheduler(clock: () => async.elapsed);
          final entries = <Entry>[];
          final order = <int>[];
          for (final (kind, value) in ops) {
            switch (kind) {
              case 'schedule':
                final id = entries.length;
                late final Entry entry;
                entry = Entry(
                  id,
                  async.elapsed + us * value,
                  scheduler.schedule(us * value, () {
                    expect(entry.firedAt, isNull, reason: 'ran twice');
                    entry.firedAt = async.elapsed;
                    order.add(id);
                  }),
                );
                entries.add(entry);
              case 'cancel' when entries.isNotEmpty:
                final entry = entries[value % entries.length];
                entry.deadline.cancel();
                if (entry.firedAt == null) {
                  entry.cancelled = true;
                }
              case 'advance':
                async.elapse(us * value);
              case 'close':
                scheduler.close();
            }
            for (final e in entries) {
              final firedAt = e.firedAt;
              if (e.cancelled) {
                expect(firedAt, isNull, reason: 'cancelled #${e.id} ran');
              } else if (firedAt != null) {
                expect(firedAt, greaterThanOrEqualTo(e.due), reason: 'early');
                expect(firedAt - e.due, lessThanOrEqualTo(us * 1000));
              } else {
                expect(
                  async.elapsed - e.due,
                  lessThan(us * 1000),
                  reason: '#${e.id} overdue',
                );
              }
            }
            expect(
              scheduler.pendingCount,
              entries.where((e) => !e.cancelled && e.firedAt == null).length,
            );
          }
          async.elapse(const Duration(seconds: 1));
          final dueOrder = [
            for (final e in entries)
              if (!e.cancelled) e,
          ]..sort((a, b) => a.due.compareTo(b.due));
          expect(
            [for (final id in order) entries[id].due],
            [for (final e in dueOrder) e.due],
            reason: 'ran out of due order',
          );
          expect(scheduler.pendingCount, 0);
          expect(scheduler.isIdle, isTrue);
        });
      }, describe: (ops) => '$ops');
    },
  );

  test('closing with nothing pending stops the timer at once', () {
    fakeAsync((async) {
      final scheduler = DeadlineScheduler(clock: () => async.elapsed);
      scheduler.schedule(const Duration(seconds: 5), () {}).cancel();
      scheduler.close();
      expect(scheduler.isIdle, isTrue);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('cancelled deadlines keep the timer until it fires or close()', () {
    for (final close in [false, true]) {
      fakeAsync((async) {
        final scheduler = DeadlineScheduler(clock: () => async.elapsed);
        final deadlines = [
          for (var i = 1; i <= 3; i++)
            scheduler.schedule(Duration(seconds: i), () {}),
        ];
        for (final deadline in deadlines) {
          deadline.cancel();
        }
        expect(scheduler.pendingCount, 0);
        if (close) {
          scheduler.close();
        } else {
          expect(scheduler.isIdle, isFalse, reason: 'kept armed on purpose');
          async.elapse(const Duration(seconds: 1));
        }
        expect(scheduler.isIdle, isTrue);
        expect(scheduler.queueLength, 0);
        expect(async.pendingTimers, isEmpty);
      });
    }
  });

  group('D5: a deadline near the largest Duration', () {
    const forever = Duration(microseconds: 0x7fffffffffffffff);

    /// Schedules [forever] at fake time [at] in a zone that fails once more
    /// than a handful of timers are armed, rather than spinning forever.
    void check(Duration at) {
      fakeAsync((async) {
        async.elapse(at);
        var timers = 0;
        var fired = false;
        runZoned(
          () {
            DeadlineScheduler(
              clock: () => async.elapsed,
            ).schedule(forever, () => fired = true);
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (++timers > 100) {
                throw StateError('busy loop: $timers timers re-armed');
              }
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
        async.elapse(const Duration(days: 1));
        expect(fired, isFalse);
      });
    }

    test(
      'never fires when scheduled at clock zero',
      () => check(Duration.zero),
    );
    test(
      'never fires when scheduled later',
      () => check(const Duration(seconds: 1)),
    );
  });

  test('D3: timers follow the zone the scheduler was built in', () {
    fakeAsync((async) {
      final scheduler = DeadlineScheduler(clock: () => async.elapsed);
      final fired = <String>[];
      // A zone whose timers never fire, as an abandoned fake clock.
      runZoned(
        () => scheduler.schedule(
          const Duration(milliseconds: 10),
          () => fired.add('first'),
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              parent.createTimer(zone, const Duration(days: 999), () {}),
        ),
      );
      scheduler.schedule(
        const Duration(milliseconds: 20),
        () => fired.add('second'),
      );
      async.elapse(const Duration(milliseconds: 50));
      expect(fired, ['first', 'second']);
    });
  });
}

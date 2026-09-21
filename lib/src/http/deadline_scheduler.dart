import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Runs callbacks at their deadlines using one [Timer] for all of them. The
/// timer lives in the zone that created the scheduler, not a caller's zone.
final class DeadlineScheduler {
  DeadlineScheduler({Duration Function()? clock})
    : _clock = clock ?? _monotonic,
      _zone = Zone.current;

  final Duration Function() _clock;

  /// Zone the timer is created in, so one caller's short-lived or fake zone
  /// can't strand deadlines that later callers schedule.
  final Zone _zone;

  /// Pending entries, earliest first. A cancelled one stays until its time
  /// comes, holding no callback, so cancelling never touches the timer.
  final PriorityQueue<Deadline> _queue = HeapPriorityQueue(Deadline._compare);

  Timer? _timer;
  int _timerAt = 0;

  /// Deadlines neither run nor cancelled yet.
  int _pending = 0;
  bool _closed = false;

  /// Whether no timer is armed. Cancelling leaves the timer armed until it
  /// next fires (re-arming per call is slower); [close] disarms it at once.
  @visibleForTesting
  bool get isIdle => _timer == null;

  /// Deadlines neither run nor cancelled yet.
  int get pendingCount => _pending;

  /// Entries still queued, cancelled ones included until their time comes.
  @visibleForTesting
  int get queueLength => _queue.length;

  /// Runs [callback] once [delay] has passed, unless the returned deadline is
  /// cancelled first.
  Deadline schedule(Duration delay, void Function() callback) {
    final now = _now();
    final micros = delay.inMicroseconds;
    // Saturates rather than wrapping, so a huge delay means "never".
    final at = micros > _never - now ? _never : now + micros;
    final entry = Deadline._(this, at, callback);
    _pending++;
    _queue.add(entry);
    if (_timer == null || entry._at < _timerAt) {
      _arm(entry._at);
    }
    return entry;
  }

  /// Stops the timer once every pending deadline has run or been cancelled,
  /// so it no longer keeps the process alive.
  void close() {
    _closed = true;
    if (_pending == 0) {
      _stop();
    }
  }

  void _settled() {
    _pending--;
    if (_closed && _pending == 0) {
      _stop();
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _queue.clear();
  }

  void _arm(int at) {
    _timer?.cancel();
    _timerAt = at;
    // A far deadline wakes early and re-arms, which keeps the rounding below
    // and Duration's microsecond range clear of overflow.
    final wait = min(at - _now(), _maxWait);
    final ms = wait <= 0 ? 0 : wait ~/ 1000 + (wait % 1000 == 0 ? 0 : 1);
    _timer = _zone.createTimer(
      Duration(milliseconds: ms),
      _zone.bindCallbackGuarded(_fire),
    );
  }

  void _fire() {
    _timer = null;
    final now = _now();
    while (_queue.isNotEmpty) {
      final next = _queue.first;
      if (next._at > now && !next._isCancelled) {
        _arm(next._at);
        return;
      }
      _queue.removeFirst()._run();
    }
  }

  int _now() => _clock().inMicroseconds;

  /// A deadline this far out never fires: the largest `int`, in µs.
  static const int _never = 0x7fffffffffffffff;

  /// Longest single timer wait, in µs; one day.
  static const int _maxWait = 24 * 60 * 60 * 1000 * 1000;

  static final Stopwatch _epoch = Stopwatch()..start();

  static Duration _monotonic() => _epoch.elapsed;
}

/// A callback waiting for its deadline, as returned by
/// [DeadlineScheduler.schedule].
final class Deadline {
  Deadline._(this._scheduler, this._at, this._callback);

  final DeadlineScheduler _scheduler;

  /// When to run, in microseconds on the scheduler's clock.
  final int _at;

  /// Dropped once run or cancelled, releasing whatever it captured.
  void Function()? _callback;

  bool get _isCancelled => _callback == null;

  /// Stops the callback from running; a no-op once it has run.
  void cancel() {
    if (_callback != null) {
      _callback = null;
      _scheduler._settled();
    }
  }

  void _run() {
    final callback = _callback;
    if (callback != null) {
      _callback = null;
      _scheduler._settled();
      callback();
    }
  }

  static int _compare(Deadline a, Deadline b) => a._at.compareTo(b._at);
}

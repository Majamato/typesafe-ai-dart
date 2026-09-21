import 'dart:async';

import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';

/// Lets a caller abandon an in-flight request, closing its connection or
/// stream where the HTTP client supports it. One-shot, and safe to share.
final class CancelToken {
  CancelToken();

  final Completer<void> _completer = Completer<void>();
  final Set<void Function()> _listeners = {};
  Object? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// The value passed to [cancel], or `null` while the token is still live or
  /// when it was cancelled without one.
  Object? get reason => _reason;

  /// Completes when [cancel] is called. Never completes if never cancelled —
  /// race it against the work, don't await it alone.
  Future<void> get whenCancelled => _completer.future;

  /// Listeners registered by calls still in flight; 0 once they all settle.
  @visibleForTesting
  int get listenerCount => _listeners.length;

  /// Cancels every call using this token; the first [reason] given wins.
  void cancel([Object? reason]) {
    if (_completer.isCompleted) {
      return;
    }
    _reason = reason;
    _completer.complete();
    final listeners = _listeners.toList(growable: false);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  /// Checked before each attempt and after each backoff wait, so a cancel
  /// that lands between them still stops the call.
  void throwIfCancelled() {
    if (isCancelled) {
      throw TypeSafeCancelledException(_reason);
    }
  }
}

/// Runs [listener] when [token] is cancelled, or at once if it already is.
/// Returns a function that unregisters it. Not exported from the package.
void Function() onCancel(CancelToken token, void Function() listener) {
  if (token.isCancelled) {
    listener();
    return _noop;
  }
  token._listeners.add(listener);
  return () => token._listeners.remove(listener);
}

void _noop() {}

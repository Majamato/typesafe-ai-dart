import 'package:typesafe_ai_dart/src/events/typesafe_event.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/response/usage.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Tracks one call and reports its steps to an `onEvent` callback. The
/// client builds one only when a callback is set, so a call without one
/// allocates nothing and reads no clock for events. Not exported.
final class CallTrace {
  CallTrace(
    this._onEvent,
    this._clock, {
    required this.callId,
    required this.endpoint,
  }) : _startedAt = _clock();

  final void Function(TypeSafeEvent event) _onEvent;
  final Duration Function() _clock;
  final int callId;
  final Endpoint endpoint;
  final Duration _startedAt;

  /// Attempts started so far, which numbers the current one from 1.
  int _attempt = 0;
  Duration _attemptStartedAt = Duration.zero;

  /// Status and request id of the current attempt's response, if any.
  int? _statusCode;
  String? _requestId;

  /// Attempt [attemptNumber], counted from 0, starts with [timeout].
  void attemptStarted(int attemptNumber, Duration timeout) {
    _attempt = attemptNumber + 1;
    _statusCode = null;
    _requestId = null;
    _attemptStartedAt = _clock();
    _emit(
      AttemptStarted(
        callId: callId,
        endpoint: endpoint,
        attempt: _attempt,
        timeout: timeout,
      ),
    );
  }

  void responded(RawResponse response) {
    _statusCode = response.statusCode;
    _requestId = response.requestId;
    _emit(
      AttemptResponded(
        callId: callId,
        endpoint: endpoint,
        attempt: _attempt,
        response: response,
        elapsed: _clock() - _attemptStartedAt,
      ),
    );
  }

  void failed(TypeSafeException error) => _emit(
    AttemptFailed(
      callId: callId,
      endpoint: endpoint,
      attempt: _attempt,
      error: error,
      elapsed: _clock() - _attemptStartedAt,
    ),
  );

  void retrying(Duration delay, TypeSafeException reason, int maxRetries) =>
      _emit(
        RetryScheduled(
          callId: callId,
          endpoint: endpoint,
          retry: _attempt,
          maxRetries: maxRetries,
          delay: delay,
          reason: reason,
        ),
      );

  void finished({Usage? usage, TypeSafeException? error}) => _emit(
    CallFinished(
      callId: callId,
      endpoint: endpoint,
      attempts: _attempt,
      elapsed: _clock() - _startedAt,
      statusCode: _statusCode,
      requestId: _requestId,
      usage: usage,
      error: error,
    ),
  );

  void _emit(TypeSafeEvent event) {
    try {
      _onEvent(event);
      // An observer must never change a call's outcome, and reporting the
      // error to the zone would kill the isolate in the root zone.
    } on Object {
      // Ignored on purpose; wrap the callback to see its errors.
    }
  }
}

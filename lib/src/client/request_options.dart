import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';

/// Per-call overrides of the client settings.
///
/// Each field that is `null`, or an empty [headers] map, leaves the
/// corresponding client setting untouched.
@immutable
final class RequestOptions {
  /// Creates options that override only the settings given.
  const RequestOptions({
    this.headers = const {},
    this.timeout,
    this.totalTimeout,
    this.retryPolicy,
    this.cancelToken,
  });

  /// Extra headers merged over the client's default headers; the six the SDK
  /// sets itself, every `x-typesafe-*` one included, always win.
  final Map<String, String> headers;

  /// Timeout for each attempt of this call, or `null` to keep the client's;
  /// each retry gets the full timeout. [totalTimeout] bounds the whole call.
  final Duration? timeout;

  /// Budget for this whole call, retries and backoff included, or `null` to
  /// keep the client's. See `ClientConfig.totalTimeout`.
  final Duration? totalTimeout;

  /// Retry behaviour for this call, or `null` to keep the client's.
  final RetryPolicy? retryPolicy;

  /// Token that abandons this call when cancelled, or `null` for a call that
  /// cannot be cancelled.
  final CancelToken? cancelToken;
}

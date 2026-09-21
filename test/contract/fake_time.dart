import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

/// One scripted server reply: [statusCode] after [after], or no reply at all
/// when [never] is set.
final class Reply {
  const Reply(
    this.statusCode, {
    this.after = Duration.zero,
    this.body = successBody,
    this.headers = const {},
  }) : never = false;

  const Reply.never()
    : statusCode = 0,
      after = Duration.zero,
      body = '',
      headers = const {},
      never = true;

  final int statusCode;
  final Duration after;
  final String body;
  final Map<String, String> headers;
  final bool never;
}

/// A server and client that both run on [async]'s fake clock; replies are
/// replayed in order and the last one repeats.
final class FakeTimeApi {
  FakeTimeApi(
    this.async,
    this.replies, {
    Duration timeout = ClientConfig.defaultTimeout,
    Duration? totalTimeout,
    RetryPolicy retryPolicy = const RetryPolicy(),
    void Function(TypeSafeEvent event)? onEvent,
  }) {
    client = TypeSafeClient.testing(
      ClientConfig(
        apiKey: 'sk-test',
        baseUrl: Uri.parse('https://api.test'),
        defaultModel: 'jev-test',
        timeout: timeout,
        totalTimeout: totalTimeout,
        retryPolicy: retryPolicy,
      ),
      httpClient: MockClient(_handle),
      clock: () => async.elapsed,
      onEvent: onEvent,
    );
  }

  final FakeAsync async;
  final List<Reply> replies;
  late final TypeSafeClient client;

  /// When each attempt reached the server, on the fake clock.
  final List<Duration> attemptTimes = [];

  /// Every request the server saw, in order.
  final List<http.Request> requests = [];

  Future<http.Response> _handle(http.Request request) async {
    attemptTimes.add(async.elapsed);
    requests.add(request);
    final reply = replies[(requests.length - 1).clamp(0, replies.length - 1)];
    if (reply.never) {
      return Completer<http.Response>().future;
    }
    await Future<void>.delayed(reply.after);
    return http.Response(reply.body, reply.statusCode, headers: reply.headers);
  }

  /// Starts [call], runs fake time until it settles (or [limit] passes) and
  /// returns how it ended and when.
  Settled<T> settle<T>(
    Future<T> Function(TypeSafeClient client) call, {
    Duration limit = const Duration(minutes: 10),
  }) {
    final settled = Settled<T>();
    unawaited(
      call(client).then(
        (value) => settled
          ..value = value
          ..at = async.elapsed,
        onError: (Object error) => settled
          ..error = error
          ..at = async.elapsed,
      ),
    );
    final end = async.elapsed + limit;
    while (settled.at == null && async.elapsed < end) {
      async.elapse(const Duration(milliseconds: 100));
    }
    return settled;
  }
}

/// How a call ended: [value] or [error], at fake time [at] (`null` if it
/// never settled).
final class Settled<T> {
  T? value;
  Object? error;
  Duration? at;
}

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

/// Body of a successful System One response with one answer per primitive.
const successBody = '''
{"model":"jev-1.13.0",
 "answers":{
   "billing":{"type":"noul","noul":0.93},
   "tone":{"type":"choice","choice":"angry",
           "probabilities":{"calm":0.2,"angry":0.8},"confidence":0.7},
   "urgency":{"type":"score","score":1.5,
              "legend":{"0":"low","1":"mid","2":"high"},
              "probabilities":{"0":0.1,"1":0.3,"2":0.6},"confidence":0.5}},
 "usage":{"input_tokens":120,"output_tokens":0}}
''';

/// Body of a successful models listing.
const modelsBody = '''
{"models":[
  {"name":"jev-1.13.0","description":"Flagship","release_date":"2026-05-01"},
  {"name":"jev-latest","description":"Alias","release_date":"2026-05-01"}]}
''';

/// A scripted step for [ScriptedClient]: a response or a thrown error.
final class Step {
  /// Returns an HTTP response after [delay].
  const Step(
    this.statusCode, {
    this.body = '',
    this.headers = const {},
    this.delay = Duration.zero,
  }) : error = null;

  /// Throws [error] after [delay].
  const Step.failing(Exception this.error, {this.delay = Duration.zero})
    : statusCode = 0,
      body = '',
      headers = const {};

  /// Status code to return.
  final int statusCode;

  /// Body to return.
  final String body;

  /// Headers to return.
  final Map<String, String> headers;

  /// Delay before responding or throwing.
  final Duration delay;

  /// Error to throw instead of responding.
  final Exception? error;
}

/// A mock HTTP client that replays [steps] in order and records requests.
final class ScriptedClient {
  /// Creates a scripted client. The last step repeats once exhausted.
  ScriptedClient(this.steps);

  /// Steps to replay.
  final List<Step> steps;

  /// Every request received, in order.
  final List<http.Request> requests = [];

  /// Bodies of every request received, in order.
  final List<String> bodies = [];

  /// The underlying mock client to pass to `TypeSafeClient`.
  late final MockClient client = MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    requests.add(request);
    bodies.add(request.body);
    final step = steps[(requests.length - 1).clamp(0, steps.length - 1)];
    if (step.delay > Duration.zero) {
      await Future<void>.delayed(step.delay);
    }
    final error = step.error;
    if (error != null) {
      throw error;
    }
    return http.Response(
      step.body,
      step.statusCode,
      headers: step.headers,
      request: request,
    );
  }
}

/// A policy with negligible backoff so retry tests run fast.
const fastRetry = RetryPolicy(
  backoffInitial: Duration(milliseconds: 1),
  backoffMax: Duration(milliseconds: 1),
  jitter: 0,
);

/// Builds a client over [scripted] with [fastRetry] unless overridden.
TypeSafeClient clientFor(
  ScriptedClient scripted, {
  RetryPolicy retryPolicy = fastRetry,
  Duration timeout = const Duration(seconds: 5),
  Duration? totalTimeout,
  Map<String, String> defaultHeaders = const {},
  String baseUrl = 'https://api.test',
  void Function(TypeSafeEvent event)? onEvent,
}) => TypeSafeClient(
  apiKey: 'sk-test',
  baseUrl: baseUrl,
  defaultModel: 'jev-test',
  defaultHeaders: defaultHeaders,
  retryPolicy: retryPolicy,
  timeout: timeout,
  totalTimeout: totalTimeout,
  httpClient: scripted.client,
  onEvent: onEvent,
);

/// A client that records whether [close] was called.
final class ClosableClient extends http.BaseClient {
  /// Whether [close] has been called.
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();

  @override
  void close() {
    closed = true;
  }
}

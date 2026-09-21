import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/client/client_config.dart';
import 'package:typesafe_ai_dart/src/client/request_options.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';
import 'package:typesafe_ai_dart/src/events/call_trace.dart';
import 'package:typesafe_ai_dart/src/events/typesafe_event.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/default_client.dart';
import 'package:typesafe_ai_dart/src/http/http_headers.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_runner.dart';
import 'package:typesafe_ai_dart/src/http/http_transport.dart';
import 'package:typesafe_ai_dart/src/json/json_codec.dart';
import 'package:typesafe_ai_dart/src/json/json_fields.dart';
import 'package:typesafe_ai_dart/src/json/json_value_kind.dart';
import 'package:typesafe_ai_dart/src/models/model_card.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';
import 'package:typesafe_ai_dart/src/request/system_one_request.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/response/system_one_response.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';
import 'package:typesafe_ai_dart/src/version.dart';

/// Client for the TypeSafe AI HTTP API; it holds no per-call state, so share
/// one per process and [close] it on shutdown. Calls go over HTTP/1.1 unless
/// `http2` is set.
///
/// Every constructor takes an optional `onEvent` callback that receives a
/// [TypeSafeEvent] for each step of every call, for logging and metrics.
final class TypeSafeClient {
  TypeSafeClient({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Map<String, String> defaultHeaders = const {},
    Duration timeout = ClientConfig.defaultTimeout,
    Duration? totalTimeout,
    RetryPolicy retryPolicy = const RetryPolicy(),
    bool http2 = false,
    http.Client? httpClient,
    void Function(TypeSafeEvent event)? onEvent,
  }) : this.withConfig(
         ClientConfig.resolve(
           apiKey: apiKey,
           baseUrl: baseUrl,
           defaultModel: defaultModel,
           defaultHeaders: defaultHeaders,
           timeout: timeout,
           totalTimeout: totalTimeout,
           retryPolicy: retryPolicy,
           http2: http2,
         ),
         httpClient: httpClient,
         onEvent: onEvent,
       );

  /// Creates a client from an already resolved [config], consulting neither
  /// the environment nor the built-in defaults.
  TypeSafeClient.withConfig(
    ClientConfig config, {
    http.Client? httpClient,
    void Function(TypeSafeEvent event)? onEvent,
  }) : this._(config, httpClient: httpClient, onEvent: onEvent);

  /// Like [TypeSafeClient.withConfig], but times deadlines and retry budgets
  /// by [clock], a monotonic time source a test drives, e.g. under fake_async.
  @visibleForTesting
  TypeSafeClient.testing(
    ClientConfig config, {
    http.Client? httpClient,
    Duration Function()? clock,
    void Function(TypeSafeEvent event)? onEvent,
  }) : this._(
         config,
         httpClient: httpClient,
         clock: clock,
         onEvent: onEvent,
       );

  TypeSafeClient._(
    this.config, {
    http.Client? httpClient,
    Duration Function()? clock,
    void Function(TypeSafeEvent event)? onEvent,
  }) : _onEvent = onEvent,
       _http = httpClient == null
           ? defaultHttpClient(http2: config.http2)
           : config.http2
           ? throw ArgumentError(
               'pass either httpClient or http2: true, not both',
               'http2',
             )
           : (client: httpClient, close: null),
       _runner = RetryRunner(clock: clock),
       _defaultHeaders = _callerHeaders(
         config.defaultHeaders,
         argument: 'defaultHeaders',
       ),
       _defaultModelJson = jsonUtf8Encoder.convert(config.defaultModel),
       _sdkGetHeaders = _sdkHeaders(config, hasBody: false),
       _sdkPostHeaders = _sdkHeaders(config, hasBody: true) {
    _transport = HttpTransport(
      client: _http.client,
      baseUrl: config.baseUrl,
      clock: clock,
    );
    _getHeaders = Map.unmodifiable({..._defaultHeaders, ..._sdkGetHeaders});
    _postHeaders = Map.unmodifiable({..._defaultHeaders, ..._sdkPostHeaders});
  }

  /// The resolved settings this client uses for every call, except where
  /// [RequestOptions] overrides them.
  final ClientConfig config;

  /// The HTTP client, and how to close it when this client created it.
  final ({http.Client client, void Function()? close}) _http;
  late final HttpTransport _transport;
  final RetryRunner _runner;

  /// Receives every call's events, or `null` for none.
  final void Function(TypeSafeEvent event)? _onEvent;

  /// The id of the last traced call; see [TypeSafeEvent.callId].
  int _lastCallId = 0;

  /// Cancelled by [close], which fails new calls and pending retries at once.
  final CancelToken _closing = CancelToken();

  /// [ClientConfig.defaultModel] as JSON, spliced into every request body
  /// that names no model.
  final List<int> _defaultModelJson;

  /// [ClientConfig.defaultHeaders] keyed lower-case, minus the SDK's own.
  final Map<String, String> _defaultHeaders;

  /// The headers the SDK sets itself, which win over any caller's.
  final Map<String, String> _sdkGetHeaders;
  final Map<String, String> _sdkPostHeaders;

  /// Default plus SDK headers: everything a first attempt without per-call
  /// headers sends, built once.
  late final Map<String, String> _getHeaders;
  late final Map<String, String> _postHeaders;

  /// Attempt deadlines still armed; 0 once every call has settled.
  @visibleForTesting
  int get pendingDeadlines => _transport.pendingDeadlines;

  /// Lets attempts in flight finish, but fails new calls and retries at once;
  /// closes the `http.Client` only if this client created it.
  void close() {
    _closing.cancel();
    _transport.close();
    _http.close?.call();
  }

  /// List available models.
  Future<List<ModelCard>> listModels({RequestOptions? options}) async {
    final trace = _trace(Endpoint.listModels);
    try {
      final response = await _call(
        endpoint: Endpoint.listModels,
        options: options,
        trace: trace,
      );
      final models = readList(_decode(response), 'models');
      final cards = List.generate(
        models.length,
        (i) => _modelAt(models[i], i),
        growable: false,
      );
      trace?.finished();
      return cards;
    } on TypeSafeException catch (e) {
      trace?.finished(error: e);
      rethrow;
    }
  }

  /// Sends [request], retrying under the effective policy.
  Future<SystemOneResponse> send(
    SystemOneRequest request, {
    RequestOptions? options,
  }) async {
    final trace = _trace(Endpoint.systemOne);
    try {
      final response = await _call(
        endpoint: Endpoint.systemOne,
        body: request.encode(defaultModelJson: _defaultModelJson),
        options: options,
        trace: trace,
      );
      final result = SystemOneResponse.fromJson(
        _decode(response),
        requestId: response.headers[requestIdHeader],
        raw: response,
      );
      trace?.finished(usage: result.usage);
      return result;
    } on TypeSafeException catch (e) {
      trace?.finished(error: e);
      rethrow;
    }
  }

  /// [state]/[questions]/[model] as usual; [extra] adds body fields but the
  /// documented fields always win.
  Future<SystemOneResponse> systemOne({
    required Object state,
    required List<Question<Answer>> questions,
    String? model,
    Map<String, Object?> extra = const {},
    RequestOptions? options,
  }) {
    final SystemOneRequest request;
    try {
      request = SystemOneRequest(
        state: state,
        questions: questions,
        model: model,
        extra: extra,
      );
      // ignore: avoid_catching_errors, it is rethrown as a failed Future.
    } on ArgumentError catch (error, stackTrace) {
      return Future.error(error, stackTrace);
    }
    return send(request, options: options);
  }

  /// The body is encoded once and resent as-is on every retry.
  Future<RawResponse> _call({
    required Endpoint endpoint,
    required RequestOptions? options,
    required CallTrace? trace,
    Uint8List? body,
  }) {
    final timeout = options?.timeout ?? config.timeout;
    final totalTimeout = options?.totalTimeout ?? config.totalTimeout;
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    if (totalTimeout != null && totalTimeout <= Duration.zero) {
      throw ArgumentError.value(
        totalTimeout,
        'totalTimeout',
        'must be positive',
      );
    }
    final extra = options?.headers;
    final callerHeaders = extra == null || extra.isEmpty
        ? null
        : _callerHeaders(extra, argument: 'headers');
    final cancelToken = options?.cancelToken;
    return _runner.run(
      policy: options?.retryPolicy ?? config.retryPolicy,
      endpoint: endpoint,
      timeout: timeout,
      totalTimeout: totalTimeout,
      cancelToken: cancelToken,
      closing: _closing,
      trace: trace,
      attempt: (attempt, attemptTimeout) => _transport.send(
        endpoint: endpoint,
        headers: _headers(
          callerHeaders,
          attempt: attempt,
          hasBody: body != null,
        ),
        body: body,
        timeout: attemptTimeout,
        cancelToken: cancelToken,
      ),
    );
  }

  /// A trace reporting to [_onEvent], or `null` when there is no callback,
  /// so an untraced call allocates nothing and reads no clock for events.
  CallTrace? _trace(Endpoint endpoint) {
    final onEvent = _onEvent;
    if (onEvent == null) {
      return null;
    }
    return CallTrace(
      onEvent,
      _runner.clock,
      callId: ++_lastCallId,
      endpoint: endpoint,
    );
  }

  static Map<String, Object?> _decode(RawResponse response) {
    final Object? decoded;
    try {
      decoded = jsonUtf8Decoder.convert(response.bodyBytes);
    } on FormatException catch (e) {
      throw ResponseValidationException(
        'Response body is not valid JSON: ${e.message}',
        fieldPath: r'$',
        actual: response.body,
      );
    }
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    invalidValue(decoded, r'$', JsonValueKind.object);
  }

  static ModelCard _modelAt(Object? value, int index) {
    try {
      return switch (value) {
        final Map<String, Object?> json => ModelCard.fromJson(json),
        _ => invalidValue(value, r'$', JsonValueKind.object),
      };
    } on ResponseValidationException catch (e) {
      throw nestUnder(e, 'models.$index');
    }
  }

  /// The prebuilt map on the common path; a merged copy only when the call
  /// adds [callerHeaders] or is a retry.
  Map<String, String> _headers(
    Map<String, String>? callerHeaders, {
    required int attempt,
    required bool hasBody,
  }) {
    if (attempt == 0 && callerHeaders == null) {
      return hasBody ? _postHeaders : _getHeaders;
    }
    return {
      ..._defaultHeaders,
      ...?callerHeaders,
      ...hasBody ? _sdkPostHeaders : _sdkGetHeaders,
      if (attempt > 0) retryCountHeader: '$attempt',
    };
  }

  /// [headers] validated and keyed lower-case, minus [_droppedHeaders], so no
  /// spelling of a name outranks the SDK's. [argument] names them in errors.
  static Map<String, String> _callerHeaders(
    Map<String, String> headers, {
    required String argument,
  }) {
    final result = <String, String>{};
    for (final MapEntry(:key, :value) in headers.entries) {
      checkHeader(key, value, argument: argument);
      final name = key.toLowerCase();
      if (!_droppedHeaders.contains(name)) {
        result[name] = value;
      }
    }
    return result;
  }

  /// Names a caller can't send: those the SDK sets itself, even where it sends
  /// none, and framing or hop-by-hop ones the HTTP client owns.
  static const Set<String> _droppedHeaders = {
    authorizationHeader,
    acceptHeader,
    userAgentHeader,
    sdkHeader,
    contentTypeHeader,
    retryCountHeader,
    'accept-encoding',
    'connection',
    'content-length',
    'host',
    'keep-alive',
    'proxy-connection',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };

  static Map<String, String> _sdkHeaders(
    ClientConfig config, {
    required bool hasBody,
  }) => Map.unmodifiable({
    authorizationHeader: 'Bearer ${config.apiKey}',
    acceptHeader: _jsonContentType,
    userAgentHeader: _sdkIdentifier,
    sdkHeader: _sdkIdentifier,
    if (hasBody) contentTypeHeader: _jsonContentType,
  });

  static const _jsonContentType = 'application/json';
  static const _sdkIdentifier = 'typesafe_ai_dart/$packageVersion';
}

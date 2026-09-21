import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/client/retry_policy.dart';
import 'package:typesafe_ai_dart/src/env/env.dart';
import 'package:typesafe_ai_dart/src/http/http_headers.dart';

/// Fully resolved settings of a `TypeSafeClient`; validated on construction,
/// so a config that exists is one the client can use.
@immutable
final class ClientConfig {
  ClientConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.defaultModel,
    Map<String, String> defaultHeaders = const {},
    this.timeout = defaultTimeout,
    this.totalTimeout,
    this.retryPolicy = const RetryPolicy(),
    this.http2 = false,
  }) : defaultHeaders = Map.unmodifiable(defaultHeaders) {
    if (apiKey.isEmpty) {
      throw ArgumentError.value(apiKey, 'apiKey', 'must not be empty');
    }
    if (!apiKey.codeUnits.every((unit) => unit > 0x20 && unit < 0x7F)) {
      // Never echo the key: it is a secret, and errors end up in logs.
      throw ArgumentError(
        'must be visible ASCII, with no spaces or line breaks (check for a '
            'trailing newline)',
        'apiKey',
      );
    }
    for (final MapEntry(:key, :value) in defaultHeaders.entries) {
      checkHeader(key, value, argument: 'defaultHeaders');
    }
    if (!baseUrl.isAbsolute ||
        !(baseUrl.isScheme('https') || baseUrl.isScheme('http')) ||
        baseUrl.host.isEmpty) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an http(s) URL with a host',
      );
    }
    if (http2 && !baseUrl.isScheme('https')) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be https when http2 is true',
      );
    }
    if (defaultModel.isEmpty) {
      throw ArgumentError.value(
        defaultModel,
        'defaultModel',
        'must not be empty',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    if (totalTimeout != null && totalTimeout! <= Duration.zero) {
      throw ArgumentError.value(
        totalTimeout,
        'totalTimeout',
        'must be positive',
      );
    }
  }

  /// Resolves apiKey/baseUrl/model as: argument, then env var, then
  /// `--define`, then default; an empty string counts as unset at each step.
  factory ClientConfig.resolve({
    String? apiKey,
    String? baseUrl,
    String? defaultModel,
    Map<String, String> defaultHeaders = const {},
    Duration timeout = defaultTimeout,
    Duration? totalTimeout,
    RetryPolicy retryPolicy = const RetryPolicy(),
    bool http2 = false,
  }) {
    final key = _nonEmpty(apiKey) ?? readEnv(apiKeyVariable) ?? _defineApiKey;
    if (key == null) {
      throw ArgumentError(
        'No TypeSafe API key. Pass apiKey or set the $apiKeyVariable '
        'environment variable.',
      );
    }
    final url =
        _nonEmpty(baseUrl) ??
        readEnv(baseUrlVariable) ??
        _defineBaseUrl ??
        defaultBaseUrl;
    final model =
        _nonEmpty(defaultModel) ??
        readEnv(defaultModelVariable) ??
        _defineDefaultModel ??
        defaultModelName;

    final Uri parsed;
    try {
      parsed = Uri.parse(_stripTrailingSlashes(url));
    } on FormatException catch (e) {
      throw ArgumentError.value(url, 'baseUrl', 'is not a URL: ${e.message}');
    }
    return ClientConfig(
      apiKey: key,
      baseUrl: parsed,
      defaultModel: model,
      defaultHeaders: defaultHeaders,
      timeout: timeout,
      totalTimeout: totalTimeout,
      retryPolicy: retryPolicy,
      http2: http2,
    );
  }

  /// Name of the environment variable, or `--define`, holding the API key.
  static const apiKeyVariable = 'TYPESAFE_API_KEY';

  /// Name of the environment variable, or `--define`, overriding the API
  /// root.
  static const baseUrlVariable = 'TYPESAFE_BASE_URL';

  /// Name of the environment variable, or `--define`, overriding the default
  /// model.
  static const defaultModelVariable = 'TYPESAFE_DEFAULT_MODEL';

  /// API root used when nothing else is configured.
  static const defaultBaseUrl = 'https://api.typesafe.ai';

  /// Model used when nothing else is configured.
  static const defaultModelName = 'jev-latest';

  /// Per-attempt timeout used when nothing else is configured.
  static const defaultTimeout = Duration(seconds: 10);

  /// Secret sent as a bearer token in the `authorization` header.
  final String apiKey;

  /// API root that endpoint paths are resolved against. [ClientConfig.resolve]
  /// strips its trailing slash; the unnamed constructor keeps it as given.
  final Uri baseUrl;

  /// Model used for a request that does not name one.
  final String defaultModel;

  /// Unmodifiable extra headers sent with every request; per-call headers
  /// merge over these, and the SDK's own headers win over both.
  final Map<String, String> defaultHeaders;

  /// Timeout for each attempt; retries do not share it. [totalTimeout] is
  /// the bound on the call as a whole.
  final Duration timeout;

  /// Budget for a whole call, retries and backoff included, or `null` for
  /// none; attempts are clamped to what remains and a late retry is skipped.
  final Duration? totalTimeout;

  /// Retry behaviour for every request, unless overridden per call.
  final RetryPolicy retryPolicy;

  /// Whether the client the SDK builds uses pooled HTTP/2 (`Http2Client` from
  /// `package:http2`, experimental upstream) instead of HTTP/1.1. Needs an
  /// `https` [baseUrl]; see "Known limitations" in doc/design.md before
  /// enabling.
  final bool http2;

  /// Lists the base URL, model, timing and transport settings, deliberately
  /// leaving out [apiKey] and [defaultHeaders] so a config can be logged.
  @override
  String toString() =>
      'ClientConfig(baseUrl: $baseUrl, defaultModel: $defaultModel, '
      'timeout: $timeout, totalTimeout: $totalTimeout, '
      'retryPolicy: $retryPolicy, http2: $http2)';

  // An empty define reads as unset, as an empty env var does.
  static const String? _defineApiKey =
      String.fromEnvironment(apiKeyVariable) == ''
      ? null
      : String.fromEnvironment(apiKeyVariable);
  static const String? _defineBaseUrl =
      String.fromEnvironment(baseUrlVariable) == ''
      ? null
      : String.fromEnvironment(baseUrlVariable);
  static const String? _defineDefaultModel =
      String.fromEnvironment(defaultModelVariable) == ''
      ? null
      : String.fromEnvironment(defaultModelVariable);

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  static String _stripTrailingSlashes(String url) =>
      url.replaceFirst(RegExp(r'/+$'), '');
}

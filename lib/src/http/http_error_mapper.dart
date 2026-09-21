// Error mapping (message extraction order, status routing, default
// messages) is ported from `typesafe-sdk-js` to match the official SDK's
// behaviour.

import 'dart:convert';

import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/http_headers.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_after.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Message is the first to match: the body's `error`/`message`/`detail`
/// field, a canned sentence, the trimmed body (200 chars max), or `HTTP <n>`.
TypeSafeApiException mapErrorResponse({
  required int statusCode,
  required String body,
  required Map<String, String> headers,
  required Endpoint endpoint,
}) {
  final errorJson = _decodeObject(body);
  final message =
      _extractMessage(errorJson) ??
      _defaultMessage(statusCode) ??
      _plainTextMessage(body) ??
      'HTTP $statusCode';
  final requestId = headers[requestIdHeader];

  return switch (statusCode) {
    400 => BadRequestException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    401 => AuthenticationException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    403 => PermissionDeniedException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    404 => NotFoundException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    422 => UnprocessableEntityException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    429 => RateLimitException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
      retryAfter: parseRetryAfter(headers),
    ),
    >= 500 && <= 599 => InternalServerException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
    _ => UnknownApiException(
      message,
      statusCode: statusCode,
      body: body,
      headers: headers,
      endpoint: endpoint,
      errorJson: errorJson,
      requestId: requestId,
    ),
  };
}

/// Decodes [body] as a JSON object, or returns `null` when it is empty,
/// invalid JSON, or JSON that is not an object.
Map<String, Object?>? _decodeObject(String body) {
  if (body.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(body);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Reads `error`, then `message`, then `detail`, matching the field order
/// the official SDKs use.
String? _extractMessage(Map<String, Object?>? json) {
  if (json == null) {
    return null;
  }
  return _messageOf(json['error']) ??
      _messageOf(json['message']) ??
      _messageOf(json['detail']);
}

/// A validation-error list with no recognised items yields `''`, not
/// `null` — that's what stops [_extractMessage] falling through further.
String? _messageOf(Object? value) => switch (value) {
  String() when value.isNotEmpty => value,
  Map<String, Object?>() => switch (value['message']) {
    final String message when message.isNotEmpty => message,
    _ => null,
  },
  List<Object?>() when value.isNotEmpty =>
    value.map(_validationItem).whereType<String>().join('; '),
  _ => null,
};

/// Returns `null` for any shape it doesn't recognise, silently dropping
/// that entry from the joined message.
String? _validationItem(Object? item) {
  if (item is String) {
    return item;
  }
  if (item is! Map<String, Object?>) {
    return null;
  }
  final msg = item['msg'];
  final loc = item['loc'];
  if (msg is String && loc is List<Object?>) {
    // Only scalar parts: joining a nested list would recurse through it.
    final path = [
      for (final part in loc)
        if (part is String || part is num || part is bool) part,
    ].join('.');
    return '$path: $msg';
  }
  if (msg is String) {
    return msg;
  }
  final message = item['message'];
  return message is String ? message : null;
}

String? _defaultMessage(int statusCode) => switch (statusCode) {
  401 => 'Missing or invalid API key. Check the Authorization header.',
  422 => 'The request body failed validation.',
  429 => 'You have exceeded your rate limit.',
  529 => 'TypeSafe is temporarily overloaded.',
  _ => null,
};

/// Returns [body] trimmed, and cut to 200 UTF-16 units (never mid-pair) plus
/// an ellipsis when longer, or `null` when empty or opening like JSON/markup.
String? _plainTextMessage(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty || trimmed.startsWith('{') || trimmed.startsWith('<')) {
    return null;
  }
  if (trimmed.length <= _maxPlainText) {
    return trimmed;
  }
  final splitsPair = trimmed.codeUnitAt(_maxPlainText - 1) & 0xFC00 == 0xD800;
  return '${trimmed.substring(0, _maxPlainText - (splitsPair ? 1 : 0))}…';
}

const _maxPlainText = 200;

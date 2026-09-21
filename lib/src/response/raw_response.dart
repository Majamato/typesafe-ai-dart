import 'dart:convert';
import 'dart:typed_data';

import 'package:typesafe_ai_dart/src/http/http_headers.dart';

/// One HTTP response as the SDK received it, before any decoding. It holds
/// the objects the transport already built, so keeping it costs no copy.
final class RawResponse {
  RawResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  /// HTTP status code.
  final int statusCode;

  /// Response headers with lower-cased names. Don't change them.
  final Map<String, String> headers;

  /// The body exactly as received, not copied. Don't change it.
  final Uint8List bodyBytes;

  /// [bodyBytes] as UTF-8, malformed bytes replaced, decoded on first read.
  late final String body = utf8.decode(bodyBytes, allowMalformed: true);

  /// Value of the `x-typesafe-request-id` header, when present.
  String? get requestId => headers[requestIdHeader];

  @override
  String toString() => 'RawResponse($statusCode, ${bodyBytes.length} bytes)';
}

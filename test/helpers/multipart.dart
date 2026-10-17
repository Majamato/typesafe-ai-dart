/// A strict `multipart/form-data` reader for checking what the client sends,
/// written here so the tests need no extra package.
library;

import 'dart:convert';
import 'dart:typed_data';

/// One part of a multipart body; header names are lower-case.
final class FormPart {
  FormPart(this.headers, this.body);

  final Map<String, String> headers;
  final Uint8List body;

  /// The `name` from the part's `content-disposition`.
  String get name => _dispositionParam('name')!;

  /// The `filename` from the part's `content-disposition`, if any.
  String? get filename => _dispositionParam('filename');

  String? _dispositionParam(String param) => RegExp(
    '; $param="([^"]*)"',
  ).firstMatch(headers['content-disposition'] ?? '')?[1];
}

/// The boundary named in a `multipart/form-data` [contentType].
String boundaryOf(String contentType) {
  final match = RegExp(
    r'^multipart/form-data; boundary=(\S+)$',
  ).firstMatch(contentType);
  if (match == null) {
    throw FormatException('not multipart/form-data', contentType);
  }
  return match[1]!;
}

/// Splits [body] into its parts, failing on anything RFC 7578 framing
/// doesn't allow: a missing opening or closing boundary, or bytes after it.
List<FormPart> parseMultipart(Uint8List body, String contentType) {
  final boundary = boundaryOf(contentType);
  final open = latin1.encode('--$boundary\r\n');
  final separator = latin1.encode('\r\n--$boundary');
  if (!_startsWithAt(body, open, 0)) {
    throw const FormatException('body does not open with the boundary');
  }
  final parts = <FormPart>[];
  var start = open.length;
  while (true) {
    final end = _indexOf(body, separator, start);
    if (end < 0) {
      throw const FormatException('part is not closed by a boundary');
    }
    parts.add(_part(Uint8List.sublistView(body, start, end)));
    final after = end + separator.length;
    if (_startsWithAt(body, latin1.encode('--\r\n'), after)) {
      if (after + 4 != body.length) {
        throw const FormatException('bytes after the closing boundary');
      }
      return parts;
    }
    if (!_startsWithAt(body, latin1.encode('\r\n'), after)) {
      throw const FormatException('boundary not followed by CRLF');
    }
    start = after + 2;
  }
}

FormPart _part(Uint8List bytes) {
  final split = _indexOf(bytes, latin1.encode('\r\n\r\n'), 0);
  if (split < 0) {
    throw const FormatException('part has no blank line after its headers');
  }
  final headers = <String, String>{};
  for (final line in latin1.decode(bytes.sublist(0, split)).split('\r\n')) {
    final colon = line.indexOf(':');
    headers[line.substring(0, colon).toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return FormPart(headers, Uint8List.sublistView(bytes, split + 4));
}

bool _startsWithAt(Uint8List bytes, List<int> prefix, int at) {
  if (at + prefix.length > bytes.length) {
    return false;
  }
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[at + i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

int _indexOf(Uint8List bytes, List<int> needle, int from) {
  for (var i = from; i <= bytes.length - needle.length; i++) {
    if (_startsWithAt(bytes, needle, i)) {
      return i;
    }
  }
  return -1;
}

/// The first bytes of a PNG file followed by [length] filler bytes: enough
/// for the client, which checks only the signature.
Uint8List fakePng([int length = 16]) => Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  for (var i = 0; i < length; i++) i % 256,
]);

/// The first bytes of a JPEG file followed by [length] filler bytes.
Uint8List fakeJpeg([int length = 16]) => Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, //
  for (var i = 0; i < length; i++) (255 - i) % 256,
]);

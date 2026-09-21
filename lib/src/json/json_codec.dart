/// The codecs the client uses on the wire, shared so none is rebuilt per
/// call.
library;

import 'dart:convert';

/// Encodes straight to UTF-8 bytes, with no intermediate `String`; calls
/// `toJson()` on objects it can't encode directly, anywhere in the tree.
final JsonUtf8Encoder jsonUtf8Encoder = JsonUtf8Encoder();

/// Decodes UTF-8 JSON bytes; on the VM this parses the bytes directly rather
/// than decoding them to a `String` first.
final Converter<List<int>, Object?> jsonUtf8Decoder = utf8.decoder.fuse(
  json.decoder,
);

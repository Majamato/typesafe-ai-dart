/// Validation for the free-form JSON values the API accepts as `state`,
/// `instructions` and criteria descriptions. Errors name the offending type,
/// never the value, since values may be user data.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:typesafe_ai_dart/src/json/json_codec.dart';
import 'package:typesafe_ai_dart/src/json/json_encodable.dart';

/// Returns [value] unchanged if [isJsonEntry] accepts it, or it is `null` and
/// [allowNull] is set.
T checkJsonEntry<T>(T value, {required String name, bool allowNull = false}) {
  if (value == null ? allowNull : isJsonEntry(value)) {
    return value;
  }
  invalidJsonEntry(value, name);
}

/// Whether [value] is a String, a JSON object, a JSON array or a
/// [JsonEncodable], whose `toJson()` the encoder calls itself.
bool isJsonEntry(Object? value) =>
    value is String ||
    value is Map<String, Object?> ||
    value is List ||
    value is JsonEncodable;

/// Shared by every argument that takes free-form JSON, so `state`,
/// `instructions` and criteria all word the error the same way.
Never invalidJsonEntry(Object? value, String name) => throw ArgumentError(
  'must be a String, a Map<String, Object?>, a List or a JsonEncodable, '
  'not ${value.runtimeType}',
  name,
);

/// Encodes [value] to UTF-8 JSON.
Uint8List encodeJsonArgument(Object? value, {required String name}) {
  try {
    return jsonUtf8Encoder.convert(value) as Uint8List;
    // ignore: avoid_catching_errors, it is the encoder's only way to say "not JSON".
  } on JsonUnsupportedObjectError catch (e) {
    throw ArgumentError(
      'must be JSON-encodable, but contains ${_describe(e)}',
      name,
    );
  }
}

/// Names what the encoder choked on: the innermost unsupported value, since
/// a failing `toJson()` wraps the value it returned as its `cause`.
String _describe(JsonUnsupportedObjectError error) {
  var culprit = error.unsupportedObject;
  for (var cause = error.cause; cause is JsonUnsupportedObjectError;) {
    culprit = cause.unsupportedObject;
    cause = cause.cause;
  }
  if (error is JsonCyclicError) {
    return 'a cycle';
  }
  return switch (culprit) {
    final double d when !d.isFinite => 'a non-finite number ($d)',
    final Map<Object?, Object?> _ => 'a map with a non-String key',
    _ => 'a ${culprit.runtimeType}',
  };
}

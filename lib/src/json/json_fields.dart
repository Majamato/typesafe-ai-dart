/// Typed reads of decoded JSON that throw [ResponseValidationException]
/// naming the field at fault. Paths are relative and only built on failure.
library;

import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/json/json_value_kind.dart';

/// Returns [key] of [json] as a string.
String readString(Map<String, Object?> json, String key) => switch (json[key]) {
  final String value => value,
  _ => invalidField(json, key, JsonValueKind.string),
};

/// Returns [key] of [json] as a string, or `null` when absent or `null`.
String? readOptionalString(Map<String, Object?> json, String key) =>
    switch (json[key]) {
      null => null,
      final String value => value,
      _ => invalidField(json, key, JsonValueKind.string),
    };

/// Returns [key] of [json] as a double, widening a JSON integer.
double readDouble(Map<String, Object?> json, String key) => switch (json[key]) {
  final num value => value.toDouble(),
  _ => invalidField(json, key, JsonValueKind.number),
};

/// Returns [key] of [json] as a JSON object (the decoded map, not a copy).
Map<String, Object?> readObject(Map<String, Object?> json, String key) =>
    switch (json[key]) {
      final Map<String, Object?> value => value,
      _ => invalidField(json, key, JsonValueKind.object),
    };

/// Returns [key] of [json] as a JSON array (the decoded list, not a copy).
List<Object?> readList(Map<String, Object?> json, String key) =>
    switch (json[key]) {
      final List<Object?> value => value,
      _ => invalidField(json, key, JsonValueKind.array),
    };

/// Returns the object [key] of [json] with every value read as a double.
Map<String, double> readDoubles(Map<String, Object?> json, String key) {
  final source = readObject(json, key);
  final result = <String, double>{};
  for (final MapEntry(key: name, :value) in source.entries) {
    if (value is! num) {
      invalidValue(value, '$key.$name', JsonValueKind.number);
    }
    result[name] = value.toDouble();
  }
  return result;
}

/// Needs the whole [json] to tell an absent field from a JSON `null`, which
/// both read as `null`.
Never invalidField(
  Map<String, Object?> json,
  String key,
  JsonValueKind expected,
) {
  if (!json.containsKey(key)) {
    throw ResponseValidationException('Missing required field', fieldPath: key);
  }
  invalidValue(json[key], key, expected);
}

/// For a value known to be present, such as a list element or a map entry;
/// [invalidField] handles a field that may be absent.
Never invalidValue(Object? value, String path, JsonValueKind expected) {
  final found = JsonValueKind.of(value)?.label ?? value.runtimeType.toString();
  throw ResponseValidationException(
    'Expected ${expected.label}, got $found',
    fieldPath: path,
    actual: value,
  );
}

/// Returns [error] with its path moved under [parent], for a reader that
/// decoded a nested value without knowing where it sits.
ResponseValidationException nestUnder(
  ResponseValidationException error,
  String parent,
) => ResponseValidationException(
  error.message,
  fieldPath: error.fieldPath == r'$' ? parent : '$parent.${error.fieldPath}',
  actual: error.actual,
);

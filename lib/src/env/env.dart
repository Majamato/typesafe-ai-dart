import 'dart:io';

/// Returns the value of the environment variable [name], or `null` when it
/// is unset, empty, or the environment cannot be read.
String? readEnv(String name) {
  try {
    final value = Platform.environment[name];
    return value == null || value.isEmpty ? null : value;
  } on Object {
    return null;
  }
}

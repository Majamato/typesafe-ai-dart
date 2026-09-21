// Prints the config `ClientConfig.resolve` builds, as JSON, or the error it
// throws. Arguments are `apiKey=...`, `baseUrl=...` or `model=...`.
import 'dart:convert';
import 'dart:io';

import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

void main(List<String> args) {
  final given = {
    for (final arg in args)
      arg.substring(0, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1),
  };
  try {
    final config = ClientConfig.resolve(
      apiKey: given['apiKey'],
      baseUrl: given['baseUrl'],
      defaultModel: given['model'],
    );
    stdout.writeln(
      jsonEncode({
        'apiKey': config.apiKey,
        'baseUrl': '${config.baseUrl}',
        'model': config.defaultModel,
      }),
    );
  } on Object catch (e) {
    stdout.writeln(jsonEncode({'error': '${e.runtimeType}: $e'}));
  }
}

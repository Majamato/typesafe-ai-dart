@Tags(['subprocess'])
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support.dart';

/// Imports and declarations that let a README fragment compile on its own.
const _prelude = '''
// ignore_for_file: type=lint, unused_import, unused_local_variable
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

late final http.Client myHttpClient;
late final TypeSafeClient client;
late final Object text;
late final Question<Answer> q;
''';

/// The README's Dart blocks, in order. Git on Windows may check README.md
/// out with CRLF line endings, so they are normalised first.
List<String> _readmeSnippets() {
  final readme = File(
    '$packageRoot/README.md',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  return RegExp(
    r'```dart\n(.*?)```',
    dotAll: true,
  ).allMatches(readme).map((m) => m.group(1)!).toList();
}

/// Turns [snippet] into a library: whole programs stay as they are, and
/// fragments are wrapped in a function after [_prelude].
String _asLibrary(String snippet) {
  if (snippet.contains('main(')) {
    return snippet;
  }
  final body = snippet.replaceAll(RegExp('^import .*;\n', multiLine: true), '');
  return '$_prelude\nFuture<void> snippet() async {\n$body\n}\n';
}

void main() {
  test('every README Dart snippet analyzes without errors', () async {
    final snippets = _readmeSnippets();
    expect(snippets, isNotEmpty);
    final dir = Directory('$packageRoot/.dart_tool/readme_snippets');
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);
    for (var i = 0; i < snippets.length; i++) {
      File('${dir.path}/snippet_$i.dart').writeAsStringSync(
        _asLibrary(snippets[i]),
      );
    }
    final result = await Process.run(Platform.resolvedExecutable, [
      'analyze',
      '--fatal-infos=false',
      '--no-fatal-warnings',
      dir.path,
    ], workingDirectory: packageRoot);
    final errors = '${result.stdout}'
        .split('\n')
        .where((line) => line.trimLeft().startsWith('error'))
        .toList();
    expect(errors, isEmpty, reason: '${result.stdout}${result.stderr}');
  });

  group('compiles AOT', () {
    late Directory out;
    setUpAll(() => out = Directory.systemTemp.createTempSync('typesafe_aot'));
    tearDownAll(() => out.deleteSync(recursive: true));

    for (final entry in [
      'example/typesafe_ai_dart_example.dart',
      'benchmark/sdk_overhead.dart',
      'benchmark/live_transport.dart',
    ]) {
      test(entry, () async {
        final result = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'exe',
          entry,
          '-o',
          '${out.path}/${entry.hashCode}',
        ], workingDirectory: packageRoot);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      });
    }
  });

  test('D10: pubspec topics follow the pub.dev format', () {
    final pubspec = File('$packageRoot/pubspec.yaml').readAsLinesSync();
    final start = pubspec.indexOf('topics:');
    final topics = [
      for (final line
          in pubspec
              .skip(start + 1)
              .takeWhile(
                (line) => line.startsWith('  - '),
              ))
        line.substring(4).trim(),
    ];
    expect(topics, isNotEmpty);
    // pub.dev: 2-32 characters, lower-case letters, digits and dashes,
    // starting with a letter and not ending with a dash.
    final valid = RegExp(r'^[a-z][a-z0-9-]{0,30}[a-z0-9]$');
    expect(topics.where((t) => !valid.hasMatch(t)), isEmpty);
  });

  test('pub publish --dry-run reports no problems but a dirty tree', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'publish',
      '--dry-run',
    ], workingDirectory: packageRoot);
    final output = '${result.stdout}${result.stderr}';
    final problems = output
        .split('\n')
        .where((line) => line.startsWith('* '))
        .where((line) => !line.contains('checked-in file'))
        .where((line) => !line.contains('modified in git'))
        .toList();
    expect(problems, isEmpty, reason: output);
    expect(
      output,
      isNot(contains('Package validation found the following error')),
    );
  });
}

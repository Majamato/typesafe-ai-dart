@Tags(['mutation'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the suite kills every hand-picked mutant', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tool/mutation/run.dart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}

@Tags(['subprocess', 'stress'])
library;

import 'dart:convert';

import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('500 k calls sharing one CancelToken keep memory flat', () async {
    final result = await runFixture('shared_token_memory', args: ['500000']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final report =
        jsonDecode((result.stdout as String).trim()) as Map<String, Object?>;
    expect(report['listeners'], 0);
    expect(report['pendingDeadlines'], 0);
    final growth = (report['endRss']! as int) - (report['warmRss']! as int);
    // A retained listener per call would cost well over 100 MB here.
    expect(growth, lessThan(48 * 1024 * 1024), reason: '$report');
  });
}

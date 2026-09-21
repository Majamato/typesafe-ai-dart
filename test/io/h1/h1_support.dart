import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

final billing = Noul(id: 'billing', instructions: 'Is `ticket` billing?');
final tone = Choice(
  id: 'tone',
  instructions: 'Tone of `ticket`',
  criteria: const {'calm': null, 'angry': null},
);
final urgency = Score(
  id: 'urgency',
  instructions: 'Urgency of `ticket`',
  criteria: const ['low', 'mid', 'high'],
);
const ticket = {'ticket': 'Charged twice, fix it now.'};

/// A policy with 1 ms backoff so retry tests don't wait.
const quickRetry = RetryPolicy(
  backoffInitial: Duration(milliseconds: 1),
  backoffMax: Duration(milliseconds: 1),
  jitter: 0,
);

/// A response body answering only [billing] with [noul].
String noulBody(double noul) => jsonEncode({
  'model': 'jev-1.13.0',
  'answers': {
    'billing': {'type': 'noul', 'noul': noul},
  },
});

/// Builds a client on the SDK's default HTTP/1.1 client for [url], closed and
/// checked for armed deadlines when the test ends.
TypeSafeClient h1Client(
  String url, {
  RetryPolicy retryPolicy = RetryPolicy.none,
  Duration timeout = const Duration(seconds: 5),
  String apiKey = 'sk-test',
  Map<String, String> defaultHeaders = const {},
}) {
  final client = TypeSafeClient(
    apiKey: apiKey,
    baseUrl: url,
    defaultModel: 'jev-test',
    retryPolicy: retryPolicy,
    timeout: timeout,
    defaultHeaders: defaultHeaders,
  );
  addTearDown(client.close);
  addTearDown(
    () => expect(client.pendingDeadlines, 0, reason: 'armed deadlines left'),
  );
  return client;
}

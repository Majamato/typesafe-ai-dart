// ignore_for_file: avoid_print, this is a benchmark script.
// Measures what the SDK itself costs per call, with the network taken out:
// an in-memory client answers every request instantly with canned bytes.
//
// JIT: dart run benchmark/sdk_overhead.dart
// AOT: dart compile exe benchmark/sdk_overhead.dart -o /tmp/b && /tmp/b
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

enum Department { billing, technical, other }

Future<void> main() async {
  final questions = <Question<Answer>>[
    Noul(
      id: 'billing',
      instructions: 'Is `ticket` about a payment or a charge?',
      criteria: NoulCriteria(whenTrue: 'money moved', whenFalse: 'anything'),
    ),
    Choice.fromEnum(
      id: 'department',
      instructions: 'Which department should handle `ticket`?',
      values: Department.values,
      describe: (d) => '${d.name} team',
    ),
    Score(
      id: 'urgency',
      instructions: 'How urgent is `ticket`?',
      criteria: const [
        ScoreLevel(summary: 'No deadline'),
        ScoreLevel(summary: 'This week'),
        ScoreLevel(summary: 'Today', signals: ['today', 'now']),
      ],
    ),
  ];
  const smallState = {'ticket': 'I was charged twice. Fix it today.'};
  final largeState = {
    'ticket': 'I was charged twice. Fix it today.',
    'history': [
      for (var i = 0; i < 32; i++)
        {'id': i, 'label': 'item-$i', 'active': i.isEven, 'score': i / 3},
    ],
  };

  final responseBytes = utf8.encode(_responseBody);
  final client = TypeSafeClient(
    apiKey: 'sk-bench',
    baseUrl: 'https://api.bench',
    httpClient: _InstantClient(responseBytes),
  );

  // The same, with an event callback that does nothing: what events cost.
  final observed = TypeSafeClient(
    apiKey: 'sk-bench',
    baseUrl: 'https://api.bench',
    httpClient: _InstantClient(responseBytes),
    onEvent: (_) {},
  );

  Future<void> call(Object state, [TypeSafeClient? via]) async {
    final response = await (via ?? client).systemOne(
      state: state,
      questions: questions,
    );
    questions.forEach(response.answer);
  }

  // The floor: the same round trip through package:http with no SDK at all.
  final bare = _InstantClient(responseBytes);
  final bareBody = utf8.encode(jsonEncode({'state': smallState}));
  final bareUrl = Uri.parse('https://api.bench/v1/systemone');
  Future<Object?> bareCall() async {
    final request = http.Request('POST', bareUrl)
      ..headers['authorization'] = 'Bearer sk-bench'
      ..bodyBytes = bareBody;
    final response = await http.Response.fromStream(await bare.send(request));
    return response.bodyBytes;
  }

  print('response bytes: ${responseBytes.length}');
  await _report('floor: bare package:http call', bareCall);
  print('large state bytes: ${utf8.encode(jsonEncode(largeState)).length}');
  await _report('send, small state', () => call(smallState));
  await _report('send, large state', () => call(largeState));
  await _report('send, small state, onEvent', () => call(smallState, observed));

  final decoder = utf8.decoder.fuse(json.decoder);
  await _report(
    'decode jsonDecode(utf8.decode)',
    () async => jsonDecode(utf8.decode(responseBytes)),
  );
  await _report(
    'decode fused utf8+json',
    () async => decoder.convert(responseBytes),
  );
  client.close();
  observed.close();
}

Future<void> _report(String name, Future<Object?> Function() operation) async {
  const warmup = 20000;
  const iterations = 100000;
  for (var i = 0; i < warmup; i++) {
    await operation();
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    await operation();
  }
  stopwatch.stop();
  final perOp = stopwatch.elapsedMicroseconds / iterations;
  print('${name.padRight(34)} ${perOp.toStringAsFixed(2).padLeft(7)} µs/op');
}

/// Drains each request body, as a real client must, then answers with
/// [_body] straight away.
final class _InstantClient extends http.BaseClient {
  _InstantClient(this._body);

  final Uint8List _body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().toBytes();
    return http.StreamedResponse(
      Stream.value(_body),
      200,
      contentLength: _body.length,
      headers: const {
        'content-type': 'application/json',
        'x-typesafe-request-id': 'req_bench',
      },
      request: request,
    );
  }
}

const _responseBody = '''
{"model":"jev-1.13.0",
 "answers":{
   "billing":{"type":"noul","noul":0.93},
   "department":{"type":"choice","choice":"billing",
     "probabilities":{"billing":0.8,"technical":0.15,"other":0.05},
     "confidence":0.7},
   "urgency":{"type":"score","score":1.5,
     "legend":{"0":{"summary":"No deadline"},"1":{"summary":"This week"},
               "2":{"summary":"Today","signals":["today","now"]}},
     "probabilities":{"0":0.1,"1":0.3,"2":0.6},"confidence":0.5}},
 "usage":{"input_tokens":120,"output_tokens":0}}
''';

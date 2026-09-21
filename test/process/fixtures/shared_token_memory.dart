// Makes many calls that share one CancelToken and prints, as JSON, the RSS
// after a warm-up and at the end, plus the token's remaining listeners.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

const _body = '{"model":"jev-test","answers":{"q":{"type":"noul","noul":0.5}}}';

Future<void> main(List<String> args) async {
  final total = int.parse(args[0]);
  const batch = 500;
  final client = TypeSafeClient(
    apiKey: 'sk-test',
    baseUrl: 'https://api.test',
    httpClient: MockClient((_) async => http.Response(_body, 200)),
  );
  final question = Noul(id: 'q', instructions: 'Is `x` true?');
  final options = RequestOptions(cancelToken: CancelToken());
  Future<void> run(int calls) async {
    for (var done = 0; done < calls; done += batch) {
      await Future.wait([
        for (var i = 0; i < batch; i++)
          client.systemOne(state: 'x', questions: [question], options: options),
      ]);
    }
  }

  await run(20000);
  final warm = ProcessInfo.currentRss;
  await run(total);
  stdout.writeln(
    jsonEncode({
      'warmRss': warm,
      'endRss': ProcessInfo.currentRss,
      'listeners': options.cancelToken!.listenerCount,
      'pendingDeadlines': client.pendingDeadlines,
    }),
  );
  client.close();
}

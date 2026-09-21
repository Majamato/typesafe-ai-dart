@Tags(['stress', 'h1'])
library;

import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/h1_server.dart';
import '../helpers/zone_guard.dart';
import '../io/h1/h1_support.dart';

void main() {
  test(
    '2 k calls through 429s, 5xx and resets all succeed, in order',
    () async {
      await expectNoUncaughtErrors(() async {
        final random = Random(3);
        final attempts = <int, List<int>>{};
        final server = await H1Server.start((request, response) async {
          final call = int.parse(request.header('x-call')!);
          final attempt = int.parse(
            request.header('x-typesafe-retry-count') ?? '0',
          );
          (attempts[call] ??= []).add(attempt);
          final fault = attempt < 2 ? random.nextInt(5) : 4;
          switch (fault) {
            case 0:
              await respondJson(
                response,
                '{"error":"slow down"}',
                status: 429,
                headers: {'retry-after-ms': '${random.nextInt(10)}'},
              );
            case 1:
              await respondJson(response, '{"error":"busy"}', status: 503);
            case 2:
              (await response.detachSocket()).destroy();
            default:
              await respondJson(response, noulBody(call / 10000));
          }
        });
        addTearDown(server.close);
        final client = h1Client(
          server.url,
          retryPolicy: quickRetry.copyWith(maxRetries: 3),
        );

        const calls = 2000;
        const wave = 100;
        for (var start = 0; start < calls; start += wave) {
          final responses = await Future.wait([
            for (var call = start; call < start + wave; call++)
              client.systemOne(
                state: ticket,
                questions: [billing],
                options: RequestOptions(headers: {'x-call': '$call'}),
              ),
          ]);
          for (var i = 0; i < wave; i++) {
            expect(responses[i].answer(billing).noul, (start + i) / 10000);
          }
        }
        for (var call = 0; call < calls; call++) {
          final seen = attempts[call]!;
          expect(seen, [for (var i = 0; i < seen.length; i++) i]);
        }
        expect(attempts.values.where((a) => a.length > 1), isNotEmpty);
      });
    },
  );
}

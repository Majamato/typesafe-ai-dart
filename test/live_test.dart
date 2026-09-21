@Tags(['live'])
library;

import 'dart:async';

import 'package:http2/client.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/env/env.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

enum Department { billingTeam, technicalSupport, other }

void main() {
  final apiKey = readEnv(ClientConfig.apiKeyVariable);

  group(
    'live API',
    () {
      late TypeSafeClient client;

      setUpAll(() => client = TypeSafeClient());
      tearDownAll(() => client.close());

      const ticket = {
        'ticket': 'I was charged twice. Refund me today or I cancel.',
      };

      test(
        'answers all three primitives over the default client',
        () async {
          final billing = Noul(
            id: 'billing',
            instructions: 'Is `ticket` about a payment or a charge?',
          );
          final tone = Choice(
            id: 'tone',
            instructions: 'What is the tone of `ticket`?',
            criteria: const {'calm': null, 'angry': null, 'neutral': null},
          );
          final urgency = Score(
            id: 'urgency',
            instructions: 'How urgent is `ticket`?',
            criteria: const ['can wait weeks', 'this week', 'today'],
          );

          final response = await client.systemOne(
            state: ticket,
            questions: [billing, tone, urgency],
          );

          expect(response.model, startsWith('jev-'));
          expect(response.usage.inputTokens, greaterThan(0));
          expect(response.requestId, isNotEmpty);

          final b = response.answer(billing);
          expect(b.noul, inInclusiveRange(0, 1));
          expect(b.noul, greaterThanOrEqualTo(0.5));

          final t = response.answer(tone);
          expect(
            t.probabilities.keys,
            containsAll(['calm', 'angry', 'neutral']),
          );
          final sum = t.probabilities.values.fold<double>(0, (a, b) => a + b);
          expect(sum, closeTo(1, 0.05));
          expect(t.confidence, inInclusiveRange(0, 1));

          final u = response.answer(urgency);
          expect(u.score, inInclusiveRange(0, 2));
          expect(u.legend.keys, [0, 1, 2]);
          expect(u.mostLikelyLevel, 2);
        },
      );

      test('score is the probability-weighted mean of the levels', () async {
        final urgency = Score(
          id: 'urgency',
          instructions: 'How urgent is `ticket`?',
          criteria: const ['weeks', 'days', 'hours', 'minutes'],
        );
        final answer = (await client.systemOne(
          state: ticket,
          questions: [urgency],
        )).answer(urgency);
        final total = answer.probabilities.values.fold<double>(
          0,
          (a, b) => a + b,
        );
        final mean = answer.probabilities.entries.fold<double>(
          0,
          (sum, e) => sum + e.key * e.value,
        );
        expect(total, closeTo(1, 0.05));
        expect(answer.score, closeTo(mean / total, 0.05));
        expect(answer.confidence, inInclusiveRange(0, 1));
      });

      test(
        'accepts structured instructions, criteria and encoded enums',
        () async {
          final refund = Noul(
            id: 'refund',
            instructions: const {
              'question': 'Does `ticket` ask for money back?',
              'exclude': ['complaints without a request'],
            },
            criteria: NoulCriteria(
              whenTrue: 'an explicit refund or chargeback request',
              whenFalse: const {
                'examples': ['just venting'],
              },
            ),
          );
          final department = Choice.fromEnum(
            id: 'department',
            instructions: 'Which team should handle `ticket`?',
            values: Department.values,
            describe: (d) => 'the ${d.name} queue',
            encode: (d) => d.name.replaceAllMapped(
              RegExp('[A-Z]'),
              (m) => '_${m[0]!.toLowerCase()}',
            ),
          );
          final urgency = Score(
            id: 'urgency',
            instructions: 'How urgent is `ticket`?',
            criteria: const [
              ScoreLevel(summary: 'No deadline'),
              ScoreLevel(summary: 'Today', signals: ['today', 'now']),
            ],
          );
          final response = await client.systemOne(
            state: ticket,
            questions: [refund, department, urgency],
          );
          expect(response.answer(refund).noul, greaterThan(0.5));
          final picked = response.answer(department);
          expect(picked.selected, Department.billingTeam);
          expect(picked.choice, 'billing_team');
          expect(picked.distribution.keys, Department.values);
          expect(response.answer(urgency).legend.keys, [0, 1]);
        },
      );

      test(
        'accepts the documented limits: 255 options, 2 and 10 levels',
        () async {
          final wide = Choice(
            id: 'wide',
            instructions: 'Which label fits `ticket` best?',
            criteria: {
              'billing': null,
              for (var i = 1; i < Choice.maxOptions; i++) 'label$i': null,
            },
          );
          final narrow = Score(
            id: 'narrow',
            instructions: 'Is `ticket` urgent?',
            criteria: const ['no', 'yes'],
          );
          final fine = Score(
            id: 'fine',
            instructions: 'How urgent is `ticket`?',
            criteria: [for (var i = 0; i < Score.maxLevels; i++) 'level $i'],
          );
          final response = await client.systemOne(
            state: ticket,
            questions: [wide, narrow, fine],
          );
          expect(
            response.answer(wide).probabilities,
            hasLength(Choice.maxOptions),
          );
          expect(response.answer(narrow).legend, hasLength(Score.minLevels));
          expect(response.answer(fine).legend, hasLength(Score.maxLevels));
        },
      );

      test(
        'echoes question ids with quotes, unicode and emoji exactly',
        () async {
          final odd = Noul(
            id: 'is "urgent" — ü 🎯',
            instructions: 'Is `ticket` urgent?',
          );
          final response = await client.systemOne(
            state: const {'ticket': 'Überweisung doppelt 💸 "sofort" zurück!'},
            questions: [odd],
          );
          expect(response.answer(odd).noul, inInclusiveRange(0, 1));
        },
      );

      test('multiplexes 20 concurrent calls over one connection', () async {
        // Needs the instance itself for connectionCount.
        // ignore: experimental_member_use
        final http2 = Http2Client();
        final shared = TypeSafeClient(httpClient: http2);
        addTearDown(() {
          shared.close();
          http2.close();
        });
        final isAngry = Noul(id: 'angry', instructions: 'Is `ticket` angry?');
        final responses = await Future.wait([
          for (var i = 0; i < 20; i++)
            shared.systemOne(
              state: {'ticket': 'Message $i: this is unacceptable!'},
              questions: [isAngry],
            ),
        ]);
        expect(responses, hasLength(20));
        expect(http2.connectionCount, 1);
        expect(shared.pendingDeadlines, 0);
      });

      test(
        'a cancel mid-flight fails the call and leaves the client usable',
        () async {
          final isAngry = Noul(id: 'angry', instructions: 'Is `ticket` angry?');
          final token = CancelToken();
          final call = client.systemOne(
            state: ticket,
            questions: [isAngry],
            options: RequestOptions(cancelToken: token),
          );
          Timer(const Duration(milliseconds: 20), () => token.cancel('test'));
          await expectLater(call, throwsA(isA<TypeSafeCancelledException>()));
          expect(token.listenerCount, 0);
          final after = await client.systemOne(
            state: ticket,
            questions: [isAngry],
          );
          expect(after.answer(isAngry).noul, inInclusiveRange(0, 1));
        },
      );

      test(
        'a bad key is an AuthenticationException carrying a request id',
        () async {
          final bad = TypeSafeClient(apiKey: 'sk-not-a-real-key');
          addTearDown(bad.close);
          await expectLater(
            bad.listModels(),
            throwsA(
              isA<AuthenticationException>()
                  .having((e) => e.statusCode, 'statusCode', 401)
                  .having((e) => e.requestId, 'requestId', isNotEmpty)
                  .having((e) => '$e', 'toString', isNot(contains('sk-not'))),
            ),
          );
        },
      );

      test('an unknown model is a BadRequestException naming it', () async {
        final isAngry = Noul(id: 'angry', instructions: 'Is `ticket` angry?');
        await expectLater(
          client.systemOne(
            state: ticket,
            questions: [isAngry],
            model: 'jev-does-not-exist',
          ),
          throwsA(
            isA<BadRequestException>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.message, 'message', contains('jev-does-not'))
                .having((e) => e.requestId, 'requestId', isNotEmpty),
          ),
        );
      });

      test('lists models, including the default', () async {
        final models = await client.listModels();
        expect(models, isNotEmpty);
        expect(models.map((m) => m.name), anyElement(startsWith('jev')));
        final isAngry = Noul(id: 'angry', instructions: 'Is `ticket` angry?');
        final named = await client.systemOne(
          state: ticket,
          questions: [isAngry],
          model: models.first.name,
        );
        expect(named.model, startsWith('jev-'));
      });
    },
    skip: apiKey == null ? 'TYPESAFE_API_KEY is not set' : false,
  );
}

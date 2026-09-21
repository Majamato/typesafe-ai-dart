import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/response/system_one_response.dart';
import 'package:typesafe_ai_dart/src/response/usage.dart';

const body = '''
{
  "model": "jev-1.13.0",
  "answers": {
    "billing": {"type": "noul", "noul": 0.93},
    "tone": {"type": "choice", "choice": "angry",
             "probabilities": {"calm": 0.2, "angry": 0.8}, "confidence": 0.7},
    "urgency": {"type": "score", "score": 1.5,
                "legend": {"0": "low", "1": "mid", "2": "high"},
                "probabilities": {"0": 0.1, "1": 0.3, "2": 0.6},
                "confidence": 0.5}
  },
  "usage": {"input_tokens": 120, "output_tokens": 0}
}
''';

enum Tone { calm, angry }

enum Mood { serene, furious }

void main() {
  final response = SystemOneResponse.fromJson(decoded(), requestId: 'req_1');
  final billing = Noul(id: 'billing', instructions: 'Billing?');
  final tone = Choice(
    id: 'tone',
    instructions: 'Tone',
    criteria: const {
      'calm': null,
      'angry': null,
    },
  );
  final urgency = Score(
    id: 'urgency',
    instructions: 'Urgency',
    criteria: const ['low', 'mid', 'high'],
  );

  group('SystemOneResponse', () {
    test('decodes model, answers, usage and request id', () {
      expect(response.model, 'jev-1.13.0');
      expect(response.requestId, 'req_1');
      expect(response.usage, const Usage(inputTokens: 120, outputTokens: 0));
      expect(response.answers.keys, ['billing', 'tone', 'urgency']);
      expect(response.toJson(), jsonDecode(body));
    });

    test('answer() returns the statically typed answer for a handle', () {
      // Field access below only compiles because the static type is
      // the concrete answer class, which is the point of typed handles.
      final b = response.answer(billing);
      final t = response.answer(tone);
      final u = response.answer(urgency);
      expect(b.noul, 0.93);
      expect(t.choice, 'angry');
      expect(u.mostLikelyLevel, 2);
    });

    test('answer() rejects a missing id with its path', () {
      expect(
        () => response.answer(Noul(id: 'nope', instructions: 'x')),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            'answers.nope',
          ),
        ),
      );
    });

    test('answer() rejects a type mismatch with the type path', () {
      expect(
        () => response.answer(Noul(id: 'tone', instructions: 'x')),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'answers.tone.type')
              .having((e) => e.actual, 'actual', 'choice'),
        ),
      );
    });

    test('answer() rejects a choice outside the handle criteria', () {
      final handle = Choice(
        id: 'tone',
        instructions: 'Tone',
        criteria: const {'calm': null, 'neutral': null},
      );
      expect(
        () => response.answer(handle),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'answers.tone.choice')
              .having((e) => e.actual, 'actual', 'angry')
              .having((e) => e.message, 'message', contains('neutral')),
        ),
      );
      expect(response.answer(tone), response['tone']);
      expect((response['tone']! as ChoiceAnswer).choice, 'angry');
      expect(response.choices['tone']!.choice, 'angry');
    });

    test('answer() resolves a TypedChoice handle through encoded keys', () {
      final handle = TypedChoice(
        id: 'tone',
        instructions: 'Tone',
        values: Mood.values,
        encode: (m) => m == Mood.serene ? 'calm' : 'angry',
      );
      final t = response.answer(handle);
      expect(t.selected, Mood.furious);
      expect(t.distribution, {Mood.serene: 0.2, Mood.furious: 0.8});
    });

    test('answer() resolves a TypedChoice handle to its enum', () {
      final handle = TypedChoice(
        id: 'tone',
        instructions: 'Tone',
        values: Tone.values,
      );
      final t = response.answer(handle);
      expect(t.selected, Tone.angry);
      expect(t.probabilityOf(Tone.calm), 0.2);
      expect(t.distribution, {Tone.calm: 0.2, Tone.angry: 0.8});
      final decoded = jsonDecode(body) as Map<String, Object?>;
      final wire = decoded['answers']! as Map<String, Object?>;
      expect(t.toJson(), wire['tone']);
    });

    test('answer() rejects an option outside the handle enum', () {
      final handle = TypedChoice(
        id: 'tone',
        instructions: 'Tone',
        values: const [Tone.calm],
      );
      expect(
        () => response.answer(handle),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'answers.tone.choice')
              .having((e) => e.actual, 'actual', 'angry'),
        ),
      );
    });

    test('answer() rejects a non-choice answer for a TypedChoice handle', () {
      final handle = TypedChoice(
        id: 'billing',
        instructions: 'Billing',
        values: Tone.values,
      );
      expect(
        () => response.answer(handle),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'answers.billing.type')
              .having((e) => e.actual, 'actual', 'noul'),
        ),
      );
    });

    test('raw access and typed views', () {
      expect(response['billing'], const NoulAnswer(0.93));
      expect(response['missing'], isNull);
      expect(response.nouls.keys, ['billing']);
      expect(response.choices.keys, ['tone']);
      expect(response.scores.keys, ['urgency']);
      expect(
        () => response.answers['x'] = const NoulAnswer(1),
        throwsUnsupportedError,
      );
    });

    test('raw is carried but left out of ==, hashCode and toJson', () {
      final raw = RawResponse(
        statusCode: 200,
        headers: const {'x-typesafe-request-id': 'req_1'},
        bodyBytes: utf8.encode(body),
      );
      final withRaw = SystemOneResponse.fromJson(decoded(), raw: raw);
      final without = SystemOneResponse.fromJson(decoded());

      expect(withRaw.raw, same(raw));
      expect(without.raw, isNull);
      expect(withRaw, without);
      expect(withRaw.hashCode, without.hashCode);
      expect(withRaw.toJson(), without.toJson());
      expect(withRaw.toString(), without.toString());
      expect(raw.body, body);
      expect(raw.body, same(raw.body), reason: 'decoded once');
      expect(raw.requestId, 'req_1');
      expect(
        raw.toString(),
        'RawResponse(200, ${utf8.encode(body).length} bytes)',
      );
    });

    test('usage defaults when absent and answers must be an object', () {
      final minimal = SystemOneResponse.fromJson(const {
        'model': 'jev',
        'answers': <String, Object?>{},
      });
      expect(minimal.usage.totalTokens, 0);
      expect(
        () => SystemOneResponse.fromJson(const {
          'model': 'jev',
          'answers': <Object?>[],
        }),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            'answers',
          ),
        ),
      );
    });

    test('a malformed answer is reported under its id', () {
      expect(
        () => SystemOneResponse.fromJson(const {
          'model': 'jev',
          'answers': {
            'tone': {'type': 'choice', 'choice': 'angry', 'confidence': 1},
          },
        }),
        throwsA(
          isA<ResponseValidationException>()
              .having(
                (e) => e.fieldPath,
                'fieldPath',
                'answers.tone.probabilities',
              )
              .having((e) => e.message, 'message', 'Missing required field'),
        ),
      );
      expect(
        () => SystemOneResponse.fromJson(const {
          'model': 'jev',
          'answers': {'tone': 'angry'},
        }),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'answers.tone')
              .having((e) => e.actual, 'actual', 'angry'),
        ),
      );
    });

    test('equality covers answers and metadata', () {
      final again = SystemOneResponse.fromJson(decoded(), requestId: 'req_1');
      expect(again, response);
      expect(again.hashCode, response.hashCode);
      expect(
        SystemOneResponse.fromJson(decoded()),
        isNot(response),
      );
    });
  });
}

Map<String, Object?> decoded() => jsonDecode(body) as Map<String, Object?>;

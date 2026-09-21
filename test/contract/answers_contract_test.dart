// Equality tests need distinct instances, which `const` would canonicalise.
// ignore_for_file: prefer_const_constructors
// ignore_for_file: prefer_const_literals_to_create_immutables
import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

enum Tone { calm, angry }

/// Builds a fresh, structurally identical value on every call.
typedef Build = Object Function();

/// Negative zero: the literal `-0.0` lints as an int, and `-0` is plain 0.
const double minusZero = -1 * 0.0;

Map<String, Object?> json(String text) =>
    jsonDecode(text) as Map<String, Object?>;

ChoiceAnswer rawTone() => ChoiceAnswer(
  choice: 'angry',
  probabilities: {'calm': 0.2, 'angry': 0.8},
  confidence: 0.7,
);

ScoreAnswer score({double p0 = 0.1}) => ScoreAnswer(
  score: 1.5,
  legend: {
    0: 'low',
    1: {
      'summary': 'mid',
      'signals': ['x'],
    },
  },
  probabilities: {0: p0, 1: 0.9},
  confidence: 0.5,
);

void main() {
  group('equality', () {
    final valueTypes = <String, Build>{
      'NoulAnswer': () => NoulAnswer(0.5 + 0),
      'ChoiceAnswer': rawTone,
      'TypedChoiceAnswer': () => TypedChoiceAnswer.from(rawTone(), Tone.values),
      'ScoreAnswer': score,
      'Usage': () => Usage(inputTokens: 1 + 0, outputTokens: 2),
      'ModelCard': () =>
          ModelCard(name: 'jev', description: 'd', releaseDate: 'r'),
      'RetryPolicy': () => RetryPolicy(retryOnStatuses: {408, 429 + 0}),
      'SystemOneResponse': () => SystemOneResponse(
        model: 'jev',
        answers: {'a': NoulAnswer(0.5 + 0), 'b': rawTone()},
        usage: Usage(inputTokens: 1 + 0, outputTokens: 2),
        requestId: 'r',
      ),
    };
    for (final MapEntry(key: name, value: build) in valueTypes.entries) {
      test('$name has value equality with a matching hashCode', () {
        final a = build();
        final b = build();
        expect(identical(a, b), isFalse);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });
    }

    final identityTypes = <String, Build>{
      'Noul': () => Noul(id: 'n', instructions: 'x'),
      'Choice': () => Choice(id: 'c', instructions: 'x', criteria: {'a': null}),
      'TypedChoice': () =>
          TypedChoice(id: 't', instructions: 'x', values: Tone.values),
      'Score': () => Score(id: 's', instructions: 'x', criteria: ['a', 'b']),
      'NoulCriteria': () => NoulCriteria(whenTrue: 'y'),
      'ScoreLevel': () => ScoreLevel(summary: 'low', signals: ['a']),
      'SystemOneRequest': () => SystemOneRequest(
        state: 's',
        questions: [Noul(id: 'n', instructions: 'x')],
      ),
      'ClientConfig': () => ClientConfig(
        apiKey: 'k',
        baseUrl: Uri.parse('https://h'),
        defaultModel: 'm',
      ),
      'RequestOptions': () => RequestOptions(headers: {'a': 'b'}),
    };
    for (final MapEntry(key: name, value: build) in identityTypes.entries) {
      test('$name compares by identity', () {
        final a = build();
        expect(a, same(a));
        expect(a == build(), isFalse);
      });
    }

    test('-0.0 and 0.0 are equal answers with equal hashes', () {
      final pairs = [
        (NoulAnswer(0), NoulAnswer(minusZero)),
        (
          ChoiceAnswer(choice: 'a', probabilities: {'a': 0}, confidence: 0),
          ChoiceAnswer(
            choice: 'a',
            probabilities: {'a': minusZero},
            confidence: minusZero,
          ),
        ),
        (score(p0: 0), score(p0: minusZero)),
      ];
      for (final (a, b) in pairs) {
        expect(a, b);
        expect(a.hashCode, b.hashCode, reason: '$a');
      }
    });

    test('answers that differ in any field are unequal', () {
      final base = rawTone();
      final variants = [
        ChoiceAnswer(
          choice: 'calm',
          probabilities: base.probabilities,
          confidence: 0.7,
        ),
        ChoiceAnswer(
          choice: 'angry',
          probabilities: {'calm': 0.2},
          confidence: 0.7,
        ),
        ChoiceAnswer(
          choice: 'angry',
          probabilities: base.probabilities,
          confidence: 0.6,
        ),
        TypedChoiceAnswer.from(base, Tone.values),
      ];
      for (final variant in variants) {
        expect(variant == base, isFalse, reason: '$variant');
      }
      expect(score() == score(p0: 0.2), isFalse);
    });
  });

  group('reading answers through handles', () {
    final tone = Choice(
      id: 'tone',
      instructions: 'x',
      criteria: {'calm': null, 'angry': null},
    );

    Future<Object?> readTone(String answer) async {
      final scripted = ScriptedClient([
        Step(200, body: '{"model":"m","answers":{"tone":$answer}}'),
      ]);
      final response = await clientFor(
        scripted,
      ).systemOne(state: 's', questions: [tone]);
      try {
        return response.answer(tone);
      } on ResponseValidationException catch (e) {
        return e;
      }
    }

    Matcher failsAt(String path) => isA<ResponseValidationException>().having(
      (e) => e.fieldPath,
      'path',
      path,
    );

    test('an unoffered choice fails at answers.<id>.choice', () async {
      expect(
        await readTone(
          '{"type":"choice","choice":"meh","probabilities":{},"confidence":1}',
        ),
        failsAt('answers.tone.choice'),
      );
    });

    test('a mismatched type fails at answers.<id>.type', () async {
      expect(
        await readTone('{"type":"noul","noul":0.5}'),
        failsAt('answers.tone.type'),
      );
    });

    test('Answer.fromJson paths are relative; the response nests them', () {
      expect(
        () => Answer.fromJson({'type': 'noul'}),
        throwsA(failsAt('noul')),
      );
      expect(
        () => SystemOneResponse.fromJson({
          'model': 'm',
          'answers': {
            'x': {'type': 'noul'},
          },
        }),
        throwsA(failsAt('answers.x.noul')),
      );
    });
  });

  group('documented answer helpers', () {
    test('mostLikelyLevel: ties go to the first, empty gives 0', () {
      ScoreAnswer of(Map<int, double> p) => ScoreAnswer(
        score: 0,
        legend: const {},
        probabilities: p,
        confidence: 0,
      );
      expect(of({2: 0.4, 1: 0.4, 0: 0.2}).mostLikelyLevel, 2);
      expect(of({}).mostLikelyLevel, 0);
      expect(of({3: 0.1, 5: 0.9}).probabilityOf(4), 0);
    });

    test('probabilityOfKey reads 0 for an unknown key', () {
      expect(rawTone().probabilityOfKey('nope'), 0);
    });

    test('distribution has one entry per offered value', () {
      final raw = ChoiceAnswer(
        choice: 'calm',
        probabilities: {'calm': 1},
        confidence: 1,
      );
      expect(TypedChoiceAnswer.from(raw, Tone.values).distribution, {
        Tone.calm: 1.0,
        Tone.angry: 0.0,
      });
    });

    test('choices stay raw even for a TypedChoice question', () {
      final response = SystemOneResponse.fromJson(json(successBody));
      expect(
        response.choices.values,
        everyElement(
          predicate<ChoiceAnswer>((a) => a.runtimeType == ChoiceAnswer),
        ),
      );
    });

    test('toJson leaves out requestId; missing usage reads as zero', () {
      final body = json(successBody)..remove('usage');
      final response = SystemOneResponse.fromJson(body, requestId: 'r');
      expect(response.toJson(), isNot(contains('requestId')));
      expect(response.usage, const Usage(inputTokens: 0, outputTokens: 0));
    });

    test('wraps answers without copying (documented)', () {
      final answers = <String, Answer>{};
      final response = SystemOneResponse(
        model: 'm',
        answers: answers,
        usage: const Usage(inputTokens: 0, outputTokens: 0),
      );
      answers['late'] = const NoulAnswer(1);
      expect(response['late'], const NoulAnswer(1));
      expect(
        () => response.answers['x'] = const NoulAnswer(0),
        throwsUnsupportedError,
      );
    });
  });

  group('D7: score level keys are strict decimal indexes', () {
    for (final key in ['+1', '0x1', ' 1 ', '01', '1.0', '-1', '1e0']) {
      test('"$key" is rejected with its path', () {
        final body = {
          'type': 'score',
          'score': 1,
          'legend': {key: 'mid'},
          'probabilities': {key: 1},
          'confidence': 1,
        };
        expect(
          () => Answer.fromJson(body),
          throwsA(
            isA<ResponseValidationException>().having(
              (e) => e.fieldPath,
              'path',
              anyOf('legend.$key', 'probabilities.$key'),
            ),
          ),
        );
      });
    }
  });

  group('D1: token counts that overflow a double read as 0', () {
    for (final field in ['input_tokens', 'output_tokens']) {
      test(field, () async {
        final body = successBody.replaceFirst(
          '"usage":{"input_tokens":120,"output_tokens":0}',
          '"usage":{"$field":1e400}',
        );
        final scripted = ScriptedClient([Step(200, body: body)]);
        final response = await clientFor(scripted).systemOne(
          state: 's',
          questions: [Noul(id: 'billing', instructions: 'x')],
        );
        expect(response.usage.totalTokens, 0);
      });
    }
  });
}

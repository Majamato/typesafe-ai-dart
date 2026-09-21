import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/models/model_card.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';
import 'package:typesafe_ai_dart/src/response/usage.dart';
import 'package:typesafe_ai_dart/src/shared/judgement_type.dart';

void main() {
  group('NoulAnswer', () {
    test('decodes integers and doubles', () {
      expect(NoulAnswer.fromJson(read('{"type":"noul","noul":1}')).noul, 1.0);
      final a = Answer.fromJson(read('{"type":"noul","noul":0.22}'));
      expect(a, const NoulAnswer(0.22));
      expect(a.toJson(), {'type': 'noul', 'noul': 0.22});
    });

    test('reports the path of a mistyped field', () {
      expect(
        () => NoulAnswer.fromJson(read('{"type":"noul","noul":"high"}')),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            'noul',
          ),
        ),
      );
    });
  });

  group('ChoiceAnswer', () {
    const json =
        '{"type":"choice","choice":"angry",'
        '"probabilities":{"calm":0.1,"angry":0.9},"confidence":0.85}';

    test('round trips and exposes helpers', () {
      final a = Answer.fromJson(read(json)) as ChoiceAnswer;
      expect(a.choice, 'angry');
      expect(a.probabilityOfKey('calm'), 0.1);
      expect(a.probabilityOfKey('missing'), 0);
      expect(a.toJson(), jsonDecode(json));
      expect(
        a,
        const ChoiceAnswer(
          choice: 'angry',
          probabilities: {'calm': 0.1, 'angry': 0.9},
          confidence: 0.85,
        ),
      );
      expect(a.hashCode, isNot(const NoulAnswer(0.9).hashCode));
    });
  });

  group('TypedChoiceAnswer', () {
    const json =
        '{"type":"choice","choice":"angry",'
        '"probabilities":{"calm":0.1,"angry":0.9},"confidence":0.85}';

    TypedChoiceAnswer<Tone> typed({List<Tone>? values}) =>
        TypedChoiceAnswer<Tone>.from(
          Answer.fromJson(read(json)) as ChoiceAnswer,
          values ?? Tone.values,
        );

    test('resolves the option and keeps the wire shape', () {
      final a = typed();
      expect(a.selected, Tone.angry);
      expect(a.choice, 'angry');
      expect(a.type, JudgementType.choice);
      expect(a.toJson(), jsonDecode(json));
    });

    test('distribution covers every option the question offered', () {
      expect(typed().distribution, {Tone.calm: 0.1, Tone.angry: 0.9});
      expect(typed().probabilityOf(Tone.calm), 0.1);
    });

    test('an option the answer left out reads zero', () {
      const raw = ChoiceAnswer(
        choice: 'angry',
        probabilities: {'angry': 1},
        confidence: 1,
      );
      final a = TypedChoiceAnswer<Tone>.from(raw, Tone.values);
      expect(a.distribution, {Tone.calm: 0.0, Tone.angry: 1.0});
      expect(a.probabilityOf(Tone.calm), 0);
    });

    test('an option outside the enum is a validation error', () {
      expect(
        () => typed(values: [Tone.calm]),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'choice')
              .having((e) => e.actual, 'actual', 'angry')
              .having((e) => e.message, 'message', contains('calm')),
        ),
      );
    });

    test('resolves encoded keys through byKey', () {
      const raw = ChoiceAnswer(
        choice: 'book_flight',
        probabilities: {'search_service': 0.3, 'book_flight': 0.7},
        confidence: 0.6,
      );
      const byKey = {
        'search_service': Intent.searchService,
        'book_flight': Intent.bookFlight,
      };
      final a = TypedChoiceAnswer<Intent>.from(
        raw,
        Intent.values,
        byKey: byKey,
      );
      expect(a.selected, Intent.bookFlight);
      expect(a.choice, 'book_flight');
      expect(a.distribution, {
        Intent.searchService: 0.3,
        Intent.bookFlight: 0.7,
      });
      expect(a.probabilityOf(Intent.searchService), 0.3);

      const outside = ChoiceAnswer(
        choice: 'bookFlight',
        probabilities: {'bookFlight': 1},
        confidence: 1,
      );
      expect(
        () => TypedChoiceAnswer<Intent>.from(
          outside,
          Intent.values,
          byKey: byKey,
        ),
        throwsA(
          isA<ResponseValidationException>()
              .having((e) => e.fieldPath, 'fieldPath', 'choice')
              .having((e) => e.actual, 'actual', 'bookFlight')
              .having((e) => e.message, 'message', contains('book_flight')),
        ),
      );
    });

    test('an enum value the question did not offer reads zero', () {
      final a = typed(values: [Tone.angry]);
      expect(a.probabilityOf(Tone.calm), 0);
      expect(a.distribution, {Tone.angry: 0.9});
    });

    test('never equals the raw answer it was built from', () {
      final raw = Answer.fromJson(read(json)) as ChoiceAnswer;
      final a = typed();
      expect(a, isNot(raw));
      expect(raw, isNot(a));
      expect(a, typed());
      expect(a.hashCode, typed().hashCode);
    });
  });

  group('ScoreAnswer', () {
    const json =
        '{"type":"score","score":1.4,'
        '"legend":{"0":"low","1":{"summary":"mid"},"2":"high"},'
        '"probabilities":{"0":0.1,"1":0.4,"2":0.5},"confidence":0.6}';

    test('parses integer level keys and finds the mode', () {
      final a = Answer.fromJson(read(json)) as ScoreAnswer;
      expect(a.score, 1.4);
      expect(a.legend, {
        0: 'low',
        1: {'summary': 'mid'},
        2: 'high',
      });
      expect(a.probabilities, {0: 0.1, 1: 0.4, 2: 0.5});
      expect(a.mostLikelyLevel, 2);
      expect(a.probabilityOf(7), 0);
      expect(a.toJson(), jsonDecode(json));
      expect(a, Answer.fromJson(read(json)));
    });

    test('rejects non-integer level keys with a path', () {
      const bad =
          '{"type":"score","score":0,"legend":{"low":"x"},'
          '"probabilities":{"0":1},"confidence":1}';
      expect(
        () => ScoreAnswer.fromJson(read(bad)),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            'legend.low',
          ),
        ),
      );
    });
  });

  test('a mistyped score probability is reported under its level', () {
    const bad =
        '{"type":"score","score":0,"legend":{"0":"x"},'
        '"probabilities":{"0":"most"},"confidence":1}';
    expect(
      () => ScoreAnswer.fromJson(read(bad)),
      throwsA(
        isA<ResponseValidationException>()
            .having((e) => e.fieldPath, 'fieldPath', 'probabilities.0')
            .having((e) => e.actual, 'actual', 'most'),
      ),
    );
  });

  test('Answer.fromJson rejects unknown types at the type path', () {
    expect(
      () => Answer.fromJson(read('{"type":"vibe"}')),
      throwsA(
        isA<ResponseValidationException>()
            .having((e) => e.fieldPath, 'fieldPath', 'type')
            .having((e) => e.message, 'message', contains('vibe')),
      ),
    );
  });

  test('every judgement type decodes and re-encodes its own name', () {
    const bodies = {
      JudgementType.noul: '{"type":"noul","noul":0.5}',
      JudgementType.choice:
          '{"type":"choice","choice":"a",'
          '"probabilities":{"a":1},"confidence":1}',
      JudgementType.score:
          '{"type":"score","score":0,"legend":{"0":"x"},'
          '"probabilities":{"0":1},"confidence":1}',
    };
    for (final value in JudgementType.values) {
      final body = bodies[value];
      expect(body, isNotNull, reason: 'no fixture for ${value.name}');
      final answer = Answer.fromJson(read(body!));
      expect(answer.type, value);
      expect(answer.toJson()['type'], value.name);
    }
  });

  test('a question and its answer agree on the judgement type', () {
    expect(Noul(id: 'q', instructions: 'x').type, const NoulAnswer(0).type);
    expect(
      Choice(id: 'q', instructions: 'x', criteria: const {'a': null}).type,
      const ChoiceAnswer(
        choice: 'a',
        probabilities: {'a': 1},
        confidence: 1,
      ).type,
    );
    expect(
      Score(id: 'q', instructions: 'x', criteria: const ['lo', 'hi']).type,
      const ScoreAnswer(
        score: 0,
        legend: {},
        probabilities: {},
        confidence: 1,
      ).type,
    );
  });

  test('Usage decodes, defaults missing counts to 0 and sums', () {
    final usage = Usage.fromJson(const {'input_tokens': 88});
    expect(usage, const Usage(inputTokens: 88, outputTokens: 0));
    expect(usage.totalTokens, 88);
    expect(usage.toJson(), {'input_tokens': 88, 'output_tokens': 0});
  });

  test('ModelCard decodes with optional fields', () {
    final card = ModelCard.fromJson(const {
      'name': 'jev-1.13.0',
      'description': 'Flagship',
      'release_date': '2026-05-01',
    });
    expect(card.name, 'jev-1.13.0');
    expect(card.releaseDate, '2026-05-01');
    expect(
      ModelCard.fromJson(const {'name': 'jev-latest'}),
      const ModelCard(name: 'jev-latest', description: '', releaseDate: ''),
    );
  });
}

Map<String, Object?> read(String json) =>
    jsonDecode(json) as Map<String, Object?>;

enum Tone { calm, angry }

enum Intent { searchService, bookFlight }

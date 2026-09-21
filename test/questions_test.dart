import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';
import 'package:typesafe_ai_dart/src/request/system_one_request.dart';

enum Tone { calm, angry }

enum Intent { searchService, bookFlight }

/// What [question] puts on the wire, helpers such as `ScoreLevel` included.
Object? wire(Question question) => jsonDecode(jsonEncode(question.toJson()));

String snakeCase(Enum value) => value.name.replaceAllMapped(
  RegExp('[A-Z]'),
  (m) => '_${m[0]!.toLowerCase()}',
);

void main() {
  group('Noul', () {
    test('encodes with and without criteria', () {
      expect(wire(Noul(id: 'a', instructions: 'Is it billing?')), {
        'type': 'noul',
        'instructions': 'Is it billing?',
      });
      final withCriteria = Noul(
        id: 'a',
        instructions: const {'question': 'Is `ticket` about billing?'},
        criteria: NoulCriteria(
          whenTrue: 'mentions charges',
          whenFalse: const {
            'what': 'anything else',
            'examples': ['login issues'],
          },
        ),
      );
      expect(wire(withCriteria), {
        'type': 'noul',
        'instructions': {'question': 'Is `ticket` about billing?'},
        'criteria': {
          'true': 'mentions charges',
          'false': {
            'what': 'anything else',
            'examples': ['login issues'],
          },
        },
      });
    });

    test('rejects empty ids and non-JSON instructions', () {
      expect(() => Noul(id: '', instructions: 'x'), throwsArgumentError);
      expect(() => Noul(id: 'a', instructions: 42), throwsArgumentError);
    });
  });

  group('Choice', () {
    test('encodes criteria and validates option count', () {
      final q = Choice(
        id: 'tone',
        instructions: 'Tone of `text`',
        criteria: const {
          'calm': null,
          'angry': {'what': 'hostile wording'},
        },
      );
      expect(q.toJson(), {
        'type': 'choice',
        'instructions': 'Tone of `text`',
        'criteria': {
          'calm': null,
          'angry': {'what': 'hostile wording'},
        },
      });
      expect(() => q.criteria['x'] = 1, throwsUnsupportedError);
      expect(
        () => Choice(id: 'a', instructions: 'x', criteria: const {}),
        throwsArgumentError,
      );
      expect(
        () => Choice(
          id: 'a',
          instructions: 'x',
          criteria: {for (var i = 0; i < 256; i++) '$i': null},
        ),
        throwsArgumentError,
      );
      expect(
        () => Choice(id: 'a', instructions: 'x', criteria: const {'k': 3}),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'criteria[k]'),
        ),
      );
    });

    test('fromEnum uses value names as keys', () {
      final q = Choice.fromEnum(
        id: 'tone',
        instructions: 'Tone',
        values: Tone.values,
        describe: (t) => t == Tone.angry ? 'hostile' : null,
      );
      expect(q, isA<TypedChoice<Tone>>());
      expect(q.criteria, {'calm': null, 'angry': 'hostile'});
      expect(q.criteria.keys, Tone.values.map((t) => t.name));
      expect(q.byKey, {'calm': Tone.calm, 'angry': Tone.angry});
      expect(q.values, Tone.values);
      expect(
        q.toJson(),
        Choice(
          id: 'tone',
          instructions: 'Tone',
          criteria: const {'calm': null, 'angry': 'hostile'},
        ).toJson(),
      );
    });

    test('fromEnum sends the encoded keys and keeps the reverse map', () {
      final q = Choice.fromEnum(
        id: 'intent',
        instructions: 'Intent',
        values: Intent.values,
        describe: (i) => i == Intent.bookFlight ? 'wants a seat' : null,
        encode: snakeCase,
      );
      expect(q.toJson(), {
        'type': 'choice',
        'instructions': 'Intent',
        'criteria': {'search_service': null, 'book_flight': 'wants a seat'},
      });
      expect(q.byKey, {
        'search_service': Intent.searchService,
        'book_flight': Intent.bookFlight,
      });
      expect(() => q.byKey['x'] = Intent.bookFlight, throwsUnsupportedError);
      expect(q.values, Intent.values);
    });

    test('rejects values that share a key', () {
      final named = isA<ArgumentError>()
          .having((e) => e.invalidValue, 'invalidValue', 'same')
          .having((e) => e.message, 'message', contains('searchService'));
      expect(
        () => TypedChoice(
          id: 'intent',
          instructions: 'Intent',
          values: Intent.values,
          encode: (_) => 'same',
        ),
        throwsA(named),
      );
      expect(
        () => TypedChoice(
          id: 'tone',
          instructions: 'Tone',
          values: const [Tone.calm, Tone.calm],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.invalidValue,
            'invalidValue',
            'calm',
          ),
        ),
      );
    });

    test('rejects an empty set of values', () {
      expect(
        () => TypedChoice<Tone>(
          id: 'tone',
          instructions: 'Tone',
          values: const [],
        ),
        throwsArgumentError,
      );
    });
  });

  group('Score', () {
    test('encodes string and ScoreLevel levels', () {
      final q = Score(
        id: 'urgency',
        instructions: 'How urgent is `ticket`?',
        criteria: const [
          'low',
          ScoreLevel(summary: 'high', signals: ['deadline today']),
        ],
      );
      expect(wire(q), {
        'type': 'score',
        'instructions': 'How urgent is `ticket`?',
        'criteria': [
          'low',
          {
            'summary': 'high',
            'signals': ['deadline today'],
          },
        ],
      });
      expect(
        () => Score(id: 'a', instructions: 'x', criteria: const ['only']),
        throwsArgumentError,
      );
      expect(
        () => Score(
          id: 'a',
          instructions: 'x',
          criteria: List.filled(11, 'level'),
        ),
        throwsArgumentError,
      );
      expect(
        () => Score(id: 'a', instructions: 'x', criteria: const ['low', 3]),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'criteria[1]'),
        ),
      );
    });
  });

  group('SystemOneRequest', () {
    test('encodes body with default model and extra fields', () {
      final request = SystemOneRequest(
        state: const {'ticket': 'Charged twice'},
        questions: [
          Noul(id: 'billing', instructions: 'Is `ticket` about billing?'),
          Choice(
            id: 'tone',
            instructions: 'Tone',
            criteria: const {'calm': null},
          ),
        ],
        extra: const {'beam_width': 4, 'model': 'ignored'},
      );
      expect(request.toJson(defaultModel: 'jev-latest'), {
        'beam_width': 4,
        'state': {'ticket': 'Charged twice'},
        'model': 'jev-latest',
        'questions': {
          'billing': {
            'type': 'noul',
            'instructions': 'Is `ticket` about billing?',
          },
          'tone': {
            'type': 'choice',
            'instructions': 'Tone',
            'criteria': {'calm': null},
          },
        },
      });
      expect(
        SystemOneRequest(
          state: 'x',
          questions: [Noul(id: 'a', instructions: 'y')],
          model: 'jev-1.13.0',
        ).toJson(defaultModel: 'jev-latest')['model'],
        'jev-1.13.0',
      );
    });

    test('encode matches toJson and caches each question', () {
      final billing = Noul(
        id: 'billing',
        instructions: 'Is `ticket` about billing?',
        criteria: NoulCriteria(whenTrue: 'money'),
      );
      final urgency = Score(
        id: 'urgency',
        instructions: const {'ask': 'How urgent is "it"?'},
        criteria: const [
          'low',
          ScoreLevel(summary: 'ünïcode ✓'),
        ],
      );
      final request = SystemOneRequest(
        state: const {
          'ticket': 'Charged twice',
          'level': ScoreLevel(summary: 'nested helper'),
        },
        questions: [billing, urgency],
        extra: const {'beam_width': 4, 'model': 'ignored', 'state': 0},
      );
      final bytes = request.encode(defaultModelJson: utf8.encode('"jev-x"'));
      expect(
        jsonDecode(utf8.decode(bytes)),
        jsonDecode(jsonEncode(request.toJson(defaultModel: 'jev-x'))),
      );
      expect(
        encodedQuestionEntry(billing),
        same(encodedQuestionEntry(billing)),
      );
      expect(
        utf8.decode(encodedQuestionEntry(urgency)),
        '"urgency":${jsonEncode(urgency.toJson())}',
      );
    });

    test('encode writes an explicit model and keeps extra fields', () {
      final request = SystemOneRequest(
        state: 'x',
        questions: [Noul(id: 'a', instructions: 'y')],
        model: 'jev-1.13.0',
        extra: const {'beam_width': 4},
      );
      final body =
          jsonDecode(
                utf8.decode(
                  request.encode(defaultModelJson: utf8.encode('"jev-x"')),
                ),
              )
              as Map<String, Object?>;
      expect(body['model'], 'jev-1.13.0');
      expect(body['beam_width'], 4);
      expect(body['state'], 'x');
    });

    test('encode writes the exact bytes, separators included', () {
      final noul = Noul(id: 'a', instructions: 'y');
      final score = Score(
        id: 'b',
        instructions: 'z',
        criteria: const ['1', '2'],
      );
      String encode(List<Question> questions, Map<String, Object?> extra) =>
          utf8.decode(
            SystemOneRequest(
              state: 'x',
              questions: questions,
              extra: extra,
            ).encode(defaultModelJson: utf8.encode('"jev-x"')),
          );
      const head = '{"state":"x","model":"jev-x","questions":';
      const a = '"a":{"type":"noul","instructions":"y"}';
      const b = '"b":{"type":"score","instructions":"z","criteria":["1","2"]}';
      expect(encode([noul], const {}), '$head{$a}}');
      expect(encode([noul, score], const {}), '$head{$a,$b}}');
      expect(
        encode(
          [noul],
          const {
            'beam_width': 4,
            'model': 'no',
            'top': [1],
          },
        ),
        '$head{$a},"beam_width":4,"top":[1]}',
      );
    });

    test('rejects empty questions, duplicate ids and bad state', () {
      expect(
        () => SystemOneRequest(state: 'x', questions: const []),
        throwsArgumentError,
      );
      expect(
        () => SystemOneRequest(
          state: 'x',
          questions: [
            Noul(id: 'a', instructions: 'y'),
            Score(id: 'a', instructions: 'y', criteria: const ['1', '2']),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
      expect(
        () => SystemOneRequest(
          state: true,
          questions: [Noul(id: 'a', instructions: 'y')],
        ),
        throwsArgumentError,
      );
    });
  });
}

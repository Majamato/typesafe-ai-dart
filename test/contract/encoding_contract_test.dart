import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

/// A JSON helper that counts how often the encoder asks it for JSON.
final class Spy implements JsonEncodable {
  Spy(this.json);

  final Object? json;
  int calls = 0;

  @override
  Object? toJson() {
    calls++;
    return json;
  }
}

enum Tone { calm, angry }

Map<String, Object?> decode(String body) =>
    jsonDecode(body) as Map<String, Object?>;

void main() {
  group('encoding once (README "On a server")', () {
    test('a question encodes itself once across many calls', () async {
      final instructions = Spy('Is `ticket` billing?');
      final question = Noul(id: 'billing', instructions: instructions);
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      final client = clientFor(scripted);
      for (var i = 0; i < 5; i++) {
        await client.systemOne(state: 'call $i', questions: [question]);
      }
      expect(instructions.calls, 1);
      expect(
        [for (final b in scripted.bodies) decode(b)['state']],
        ['call 0', 'call 1', 'call 2', 'call 3', 'call 4'],
      );
    });

    test('state is encoded once and the body reused across retries', () async {
      final state = Spy({'ticket': 'Charged twice'});
      final scripted = ScriptedClient([
        const Step(503),
        const Step(502),
        const Step(200, body: successBody),
      ]);
      await clientFor(scripted).systemOne(
        state: state,
        questions: [Noul(id: 'billing', instructions: 'Billing?')],
      );
      expect(state.calls, 1);
      expect(scripted.bodies.toSet(), hasLength(1));
    });

    test('a question changed after its first send keeps sending its first '
        'encoding (documented: build handles once)', () async {
      final instructions = <String, Object?>{'q': 'first'};
      final question = Noul(id: 'n', instructions: instructions);
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      final client = clientFor(scripted);
      await client.systemOne(state: 's', questions: [question]);
      instructions['q'] = 'second';
      await client.systemOne(state: 's', questions: [question]);
      final sent = [
        for (final b in scripted.bodies) (decode(b)['questions']! as Map)['n'],
      ];
      expect(sent, everyElement(containsPair('instructions', {'q': 'first'})));
      expect(question.toJson()['instructions'], {'q': 'second'});
    });
  });

  group('SystemOneRequest', () {
    final q = Noul(id: 'n', instructions: 'x');

    test('documented fields win over extra, in toJson and on the wire', () {
      final request = SystemOneRequest(
        state: 'real',
        questions: [q],
        model: 'm',
        extra: const {'state': 'fake', 'model': 'fake', 'questions': 1, 'x': 2},
      );
      final wire = decode(utf8.decode(request.encode(defaultModelJson: [])));
      final logged = jsonDecode(
        jsonEncode(request.toJson(defaultModel: 'd')),
      );
      for (final json in [wire, logged]) {
        expect(json, containsPair('state', 'real'));
        expect(json, containsPair('model', 'm'));
        expect(json, containsPair('x', 2));
        expect((json as Map)['questions'], {'n': q.toJson()});
      }
    });

    test('keeps extra without copying, but sends it as it was when built', () {
      final extra = <String, Object?>{'early': true};
      final state = <String, Object?>{'a': 1};
      final request = SystemOneRequest(
        state: state,
        questions: [q],
        extra: extra,
      );
      extra['late'] = true;
      state['a'] = 2;
      expect(request.extra, same(extra));
      final wire = decode(
        utf8.decode(request.encode(defaultModelJson: utf8.encode('"d"'))),
      );
      expect(wire['early'], isTrue);
      expect(wire.containsKey('late'), isFalse);
      expect(wire['state'], {'a': 1});
    });

    test('toJson leaves helpers such as ScoreLevel for jsonEncode', () {
      const level = ScoreLevel(summary: 'low', signals: ['calm']);
      final score = Score(
        id: 's',
        instructions: 'x',
        criteria: const [level, 'high'],
      );
      expect(score.toJson()['criteria'], [same(level), 'high']);
      expect(decode(jsonEncode(score.toJson()))['criteria'], [
        {
          'summary': 'low',
          'signals': ['calm'],
        },
        'high',
      ]);
    });
  });

  group('validation bounds', () {
    Map<String, Object?> options(int n) => {
      for (var i = 0; i < n; i++) 'o$i': null,
    };
    List<Object> levels(int n) => [for (var i = 0; i < n; i++) 'l$i'];

    for (final (n, ok) in [(0, false), (1, true), (255, true), (256, false)]) {
      test('Choice with $n options is ${ok ? 'accepted' : 'rejected'}', () {
        Choice build() =>
            Choice(id: 'c', instructions: 'x', criteria: options(n));
        expect(build, ok ? returnsNormally : throwsArgumentError);
      });
    }

    for (final (n, ok) in [(1, false), (2, true), (10, true), (11, false)]) {
      test('Score with $n levels is ${ok ? 'accepted' : 'rejected'}', () {
        Score build() => Score(id: 's', instructions: 'x', criteria: levels(n));
        expect(build, ok ? returnsNormally : throwsArgumentError);
      });
    }

    test('TypedChoice rejects two values that encode to one key', () {
      expect(
        () => Choice.fromEnum(
          id: 't',
          instructions: 'x',
          values: Tone.values,
          encode: (v) => 'same',
        ),
        throwsA(
          isA<ArgumentError>().having((e) => '$e', 'message', contains('same')),
        ),
      );
    });

    test('an empty id, question list or duplicate id is rejected', () {
      expect(() => Noul(id: '', instructions: 'x'), throwsArgumentError);
      final q = Noul(id: 'n', instructions: 'x');
      expect(
        () => SystemOneRequest(state: 's', questions: const []),
        throwsArgumentError,
      );
      expect(
        () => SystemOneRequest(state: 's', questions: [q, q]),
        throwsArgumentError,
      );
    });
  });

  group('S2: non-JSON input is an ArgumentError at construction', () {
    final poisons = <String, Object?>{
      'DateTime': DateTime.utc(2026),
      'Set': {1, 2},
      'Object': Object(),
      'NaN': double.nan,
      'Infinity': double.infinity,
      'int-keyed map': {1: 'a'},
    };
    for (final MapEntry(key: name, value: poison) in poisons.entries) {
      group('a nested $name', () {
        final builders = <String, Object Function()>{
          'in state': () => SystemOneRequest(
            state: {
              'a': [poison],
            },
            questions: [Noul(id: 'n', instructions: 'x')],
          ),
          'in extra': () => SystemOneRequest(
            state: 's',
            questions: [Noul(id: 'n', instructions: 'x')],
            extra: {'x': poison},
          ),
          'in instructions': () => Noul(
            id: 'n',
            instructions: {'deep': poison},
          ),
          'in a criteria description': () => Choice(
            id: 'c',
            instructions: 'x',
            criteria: {
              'a': {'why': poison},
            },
          ),
          'in NoulCriteria': () => NoulCriteria(whenTrue: [poison]),
          'in a Score level': () => Score(
            id: 's',
            instructions: 'x',
            criteria: [
              'low',
              {'high': poison},
            ],
          ),
        };
        for (final MapEntry(key: where, value: build) in builders.entries) {
          test(where, () => expect(build, throwsArgumentError));
        }
      });
    }

    test('through systemOne, the call fails with ArgumentError and sends '
        'nothing', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await expectLater(
        clientFor(scripted).systemOne(
          state: {'at': DateTime.utc(2026)},
          questions: [Noul(id: 'n', instructions: 'x')],
        ),
        throwsArgumentError,
      );
      expect(scripted.requests, isEmpty);
    });
  });

  test('D9: systemOne reports bad arguments through its Future', () async {
    final client = clientFor(ScriptedClient([const Step(200)]));
    late Future<SystemOneResponse> call;
    expect(
      () => call = client.systemOne(state: 's', questions: const []),
      returnsNormally,
    );
    await expectLater(call, throwsArgumentError);
  });

  group('a non-JSON argument error names the type, never the value', () {
    final secret = _Secret();
    for (final (where, build) in <(String, Object Function())>[
      (
        'state',
        () => SystemOneRequest(
          state: {
            'user': [secret],
          },
          questions: [Noul(id: 'n', instructions: 'x')],
        ),
      ),
      (
        'extra',
        () => SystemOneRequest(
          state: 's',
          questions: [Noul(id: 'n', instructions: 'x')],
          extra: {'x': secret},
        ),
      ),
      ('instructions', () => Noul(id: 'n', instructions: {'x': secret})),
    ]) {
      test(where, () {
        expect(
          build,
          throwsA(
            isA<ArgumentError>().having(
              (e) => '$e',
              'text',
              allOf(contains('_Secret'), isNot(contains('hunter2'))),
            ),
          ),
        );
      });
    }

    test('a NaN is reported as a non-finite number', () {
      expect(
        () => SystemOneRequest(
          state: {'ratio': double.nan},
          questions: [Noul(id: 'n', instructions: 'x')],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '$e',
            'text',
            contains('non-finite number'),
          ),
        ),
      );
    });
  });
}

/// A value JSON can't encode, whose text must never reach an error message.
final class _Secret {
  @override
  String toString() => 'hunter2';
}

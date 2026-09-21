@Tags(['property'])
library;

import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/fuzz.dart';
import '../helpers/gen.dart';

final List<int> defaultModelJson = utf8.encode(jsonEncode('jev-default'));
const reserved = {'state', 'model', 'questions'};

/// What `jsonEncode` makes of [value], decoded again.
Object? roundTrip(Object? value) => jsonDecode(jsonEncode(value));

/// A random request, kept with its parts so the check can rebuild it.
typedef Generated = ({
  Object state,
  List<Question<Answer>> questions,
  String? model,
  Map<String, Object?> extra,
});

Generated generate(Random random) {
  final ids = <String>{};
  while (ids.length < 1 + random.nextInt(5)) {
    ids.add(randomKey(random));
  }
  return (
    state: randomEntry(random),
    questions: [for (final id in ids) randomQuestion(random, id)],
    model: random.nextBool() ? null : randomString(random),
    extra: {
      ...randomObject(random, depth: 2),
      if (random.nextInt(3) == 0)
        reserved.elementAt(random.nextInt(3)): randomJson(random),
    },
  );
}

String describe(Generated g) => jsonEncode({
  'state': g.state,
  'questions': [for (final q in g.questions) q.toJson()],
  'model': g.model,
  'extra': g.extra,
});

/// A value no JSON encoder accepts, or one outside the JSON data model.
Object? poison(Random random) => switch (random.nextInt(6)) {
  0 => DateTime.utc(2026),
  1 => {1, 2},
  2 => Object(),
  3 => double.nan,
  4 => double.infinity,
  _ => {1: 'int key'},
};

/// Returns [tree] with [bad] placed at a random depth of one or more.
Object plant(Random random, Object tree, Object? bad) {
  switch (tree) {
    case final Map<String, Object?> map when map.isNotEmpty:
      final key = map.keys.elementAt(random.nextInt(map.length));
      final child = map[key];
      if (child != null && child is! String && random.nextBool()) {
        return {...map, key: plant(random, child, bad)};
      }
      return {...map, 'poison': bad};
    case final List<Object?> list when list.isNotEmpty:
      final index = random.nextInt(list.length);
      final child = list[index];
      if (child is Map<String, Object?> || child is List) {
        if (random.nextBool()) {
          return [...list]..[index] = plant(random, child!, bad);
        }
      }
      return [...list, bad];
    default:
      return {'wrapped': tree, 'poison': bad};
  }
}

void main() {
  test('encode() is exactly the documented JSON body', () async {
    await forAll(generate, describe: describe, (g) {
      final request = SystemOneRequest(
        state: g.state,
        questions: g.questions,
        model: g.model,
        extra: g.extra,
      );
      final bytes = request.encode(defaultModelJson: defaultModelJson);
      final text = utf8.decode(bytes);
      final body = jsonDecode(text) as Map<String, Object?>;

      final expected = {
        for (final MapEntry(:key, :value) in g.extra.entries)
          if (!reserved.contains(key)) key: roundTrip(value),
        'state': roundTrip(g.state),
        'model': g.model ?? 'jev-default',
        'questions': {for (final q in g.questions) q.id: roundTrip(q.toJson())},
      };
      expect(body, expected);
      expect(
        (body['questions']! as Map).keys,
        [for (final q in g.questions) q.id],
        reason: 'question order is kept',
      );
      expect(roundTrip(request.toJson(defaultModel: 'jev-default')), expected);
      expect(
        request.encode(defaultModelJson: defaultModelJson),
        bytes,
        reason: 'cached question bytes are stable',
      );
    });
  });

  test('S7: ids with lone surrogates survive the wire unchanged', () {
    for (final id in ['\ud800', 'a\udfffb', '\udc00\ud800']) {
      final request = SystemOneRequest(
        state: id,
        questions: [Noul(id: id, instructions: id)],
      );
      final body =
          jsonDecode(utf8.decode(request.encode(defaultModelJson: [0x31])))
              as Map<String, Object?>;
      expect((body['questions']! as Map).keys.single, id);
      expect(body['state'], id);
    }
  });

  test('S2: non-JSON anywhere in the input fails at construction', () async {
    await forAll(
      (random) {
        final where = random.nextInt(4);
        final bad = poison(random);
        return (
          where: where,
          bad: bad,
          tree: plant(random, randomEntry(random), bad),
        );
      },
      describe: (g) => 'where=${g.where} bad=${g.bad} tree=${g.tree}',
      (g) {
        final tree = g.tree;
        Object build() => switch (g.where) {
          0 => SystemOneRequest(
            state: tree,
            questions: [Noul(id: 'n', instructions: 'x')],
          ),
          1 => Noul(id: 'n', instructions: tree),
          2 => Choice(id: 'c', instructions: 'x', criteria: {'a': tree}),
          _ => SystemOneRequest(
            state: 's',
            questions: [Noul(id: 'n', instructions: 'x')],
            extra: {'x': tree},
          ),
        };
        expect(build, throwsArgumentError);
      },
      runs: fuzzRuns(100),
    );
  });
}

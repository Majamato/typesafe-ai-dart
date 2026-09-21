import 'dart:math';

import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

/// Strings that stress JSON escaping and UTF-8: quotes, backslashes, control
/// characters, astral emoji, lone surrogates, RTL, zero-width and markup.
const trickyStrings = [
  '',
  ' ',
  'plain',
  '"quoted"',
  r'back\slash',
  '\u0000\u0001\u001f',
  '\n\r\t\b\f',
  '😀🎉👨‍👩‍👧',
  '\ud800',
  '\udfff',
  'a\udc00b',
  'שלום עולם',
  '日本語テキスト',
  'zero​width',
  '  ',
  '</script><!--',
  '{"not":"json"}',
  r'$ref',
  'ticket.messages[0].text',
];

/// Doubles that stress number encoding; all finite, so JSON can carry them.
const trickyDoubles = [
  0.0,
  -0.0,
  0.1,
  -1.5,
  1e308,
  -1e308,
  5e-324,
  1e-7,
  123456789.123456789,
];

/// Integers at the edges of what JSON and the VM carry exactly.
const trickyInts = <int>[
  0,
  -1,
  1,
  9007199254740991,
  -9007199254740991,
  1 << 62,
];

/// Returns a random string, favouring [trickyStrings].
String randomString(Random random, {int maxLength = 12}) {
  if (random.nextInt(3) > 0) {
    return trickyStrings[random.nextInt(trickyStrings.length)];
  }
  final length = random.nextInt(maxLength + 1);
  final units = <int>[
    for (var i = 0; i < length; i++)
      switch (random.nextInt(4)) {
        0 => 0x20 + random.nextInt(0x5f),
        1 => random.nextInt(0x20),
        2 => 0xa0 + random.nextInt(0xd7ff - 0xa0),
        _ => 0xd800 + random.nextInt(0x800),
      },
  ];
  return String.fromCharCodes(units);
}

/// Returns a random non-empty string, for ids and option keys.
String randomKey(Random random) {
  final key = randomString(random);
  return key.isEmpty ? 'k${random.nextInt(1000)}' : key;
}

/// Returns a random JSON value, up to [depth] levels of nesting.
Object? randomJson(Random random, {int depth = 3}) {
  final pick = random.nextInt(depth > 0 ? 8 : 5);
  return switch (pick) {
    0 => null,
    1 => random.nextBool(),
    2 => trickyInts[random.nextInt(trickyInts.length)],
    3 => trickyDoubles[random.nextInt(trickyDoubles.length)],
    4 => randomString(random),
    5 => [
      for (var i = random.nextInt(4); i > 0; i--)
        randomJson(random, depth: depth - 1),
    ],
    _ => randomObject(random, depth: depth - 1),
  };
}

/// Returns a random JSON object, up to [depth] levels of nesting.
Map<String, Object?> randomObject(Random random, {int depth = 3}) => {
  for (var i = random.nextInt(4); i > 0; i--)
    randomKey(random): randomJson(random, depth: depth),
};

/// Returns a value `SystemOneRequest.state` and `instructions` accept: a
/// string, a JSON object or a JSON array.
Object randomEntry(Random random, {int depth = 3}) =>
    switch (random.nextInt(3)) {
      0 => randomString(random),
      1 => randomObject(random, depth: depth),
      _ => [for (var i = random.nextInt(4); i > 0; i--) randomJson(random)],
    };

/// Enum for generated typed choices.
enum Fruit { apple, bananaSplit, cherry, dragonFruit }

/// Returns a random question with id [id], of any kind and shape.
Question<Answer> randomQuestion(Random random, String id) {
  final instructions = randomEntry(random);
  switch (random.nextInt(4)) {
    case 0:
      return Noul(
        id: id,
        instructions: instructions,
        criteria: random.nextBool()
            ? null
            : NoulCriteria(
                whenTrue: random.nextBool() ? null : randomEntry(random),
                whenFalse: random.nextBool() ? null : randomEntry(random),
              ),
      );
    case 1:
      return Choice(
        id: id,
        instructions: instructions,
        criteria: {
          for (var i = 1 + random.nextInt(5); i > 0; i--)
            randomKey(random): random.nextBool() ? null : randomEntry(random),
        },
      );
    case 2:
      Object? describe(Fruit value) => randomEntry(random);
      String encode(Fruit value) => '${value.name}#${value.index}';
      return Choice.fromEnum(
        id: id,
        instructions: instructions,
        values: Fruit.values.sublist(0, 1 + random.nextInt(4)),
        describe: random.nextBool() ? null : describe,
        encode: random.nextBool() ? null : encode,
      );
    default:
      return Score(
        id: id,
        instructions: instructions,
        criteria: [
          for (var i = 2 + random.nextInt(9); i > 0; i--)
            if (random.nextBool())
              randomEntry(random)
            else
              ScoreLevel(
                summary: randomString(random),
                signals: [
                  for (var j = random.nextInt(3); j > 0; j--)
                    randomString(random),
                ],
              ),
        ],
      );
  }
}

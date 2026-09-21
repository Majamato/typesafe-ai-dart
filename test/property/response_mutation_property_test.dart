@Tags(['property'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/fuzz.dart';

enum Fruit { apple, cherry }

final billing = Noul(id: 'billing', instructions: 'x');
final tone = Choice(
  id: 'tone',
  instructions: 'x',
  criteria: const {'calm': null, 'angry': null},
);
final TypedChoice<Fruit> fruit = Choice.fromEnum(
  id: 'fruit',
  instructions: 'x',
  values: Fruit.values,
);
final urgency = Score(
  id: 'urgency',
  instructions: 'x',
  criteria: const ['low', 'mid', 'high'],
);
final List<Question<Answer>> handles = [billing, tone, fruit, urgency];

/// A valid response to [handles] exercising every field the SDK reads.
const Map<String, Object?> validResponse = {
  'model': 'jev-1.13.0',
  'answers': {
    'billing': {'type': 'noul', 'noul': 0.93},
    'tone': {
      'type': 'choice',
      'choice': 'angry',
      'probabilities': {'calm': 0.2, 'angry': 0.8},
      'confidence': 0.7,
    },
    'fruit': {
      'type': 'choice',
      'choice': 'cherry',
      'probabilities': {'apple': 0.1, 'cherry': 0.9},
      'confidence': 0.8,
    },
    'urgency': {
      'type': 'score',
      'score': 1.5,
      'legend': {'0': 'low', '1': 'mid', '2': 'high'},
      'probabilities': {'0': 0.1, '1': 0.3, '2': 0.6},
      'confidence': 0.5,
    },
  },
  'usage': {'input_tokens': 120, 'output_tokens': 7},
};

const Map<String, Object?> validModels = {
  'models': [
    {'name': 'jev-1.13.0', 'description': 'Flagship', 'release_date': 'x'},
    {'name': 'jev-latest'},
  ],
};

/// Raw JSON texts swapped in for a value; `null` deletes the field.
const replacements = <String?>[
  null,
  'null',
  'true',
  '0',
  '1.5',
  '-1',
  '1e400',
  '""',
  '"str"',
  '[]',
  '[1]',
  '{}',
  '{"type":"noul"}',
];

const sentinel = '__MUTATION__';

/// Every `a.b.c` path in [json] with its value, depth first.
Iterable<String> pathsOf(Object? json, [String prefix = '']) sync* {
  final children = switch (json) {
    final Map<String, Object?> map => map.entries.map((e) => (e.key, e.value)),
    final List<Object?> list => [
      for (var i = 0; i < list.length; i++) ('$i', list[i]),
    ],
    _ => const <(String, Object?)>[],
  };
  for (final (key, value) in children) {
    final path = prefix.isEmpty ? key : '$prefix.$key';
    yield path;
    yield* pathsOf(value, path);
  }
}

/// [json] with the value at [path] deleted ([raw] `null`) or replaced by the
/// raw JSON text [raw].
String mutate(Object? json, String path, String? raw) {
  Object? walk(Object? node, List<String> keys) {
    if (keys.isEmpty) {
      return sentinel;
    }
    final [key, ...rest] = keys;
    switch (node) {
      case final Map<String, Object?> map:
        return {
          for (final MapEntry(key: k, :value) in map.entries)
            if (k != key)
              k: value
            else if (rest.isNotEmpty || raw != null)
              k: walk(value, rest),
        };
      case final List<Object?> list:
        final index = int.parse(key);
        return [
          for (var i = 0; i < list.length; i++)
            if (i != index)
              list[i]
            else if (rest.isNotEmpty || raw != null)
              walk(list[i], rest),
        ];
      default:
        throw StateError('no $key under $node');
    }
  }

  return jsonEncode(walk(json, path.split('.'))).replaceFirst(
    '"$sentinel"',
    raw ?? '',
  );
}

/// Whether an error at [reported] plausibly blames a mutation at [mutated]:
/// the same field, one inside it or around it, or a sibling of a `type`.
bool blames(String reported, String mutated) {
  bool under(String a, String b) => a == b || a.startsWith('$b.');
  if (under(reported, mutated) || under(mutated, reported)) {
    return true;
  }
  if (mutated.endsWith('.type')) {
    return under(reported, mutated.substring(0, mutated.length - 5));
  }
  return reported == r'$';
}

/// Sends [body] through a real client and reads every handle; returns the
/// error, or `null` when everything read cleanly.
Future<Object?> readAll(List<int> body, {bool models = false}) async {
  final client = TypeSafeClient(
    apiKey: 'sk-test',
    baseUrl: 'https://api.test',
    retryPolicy: RetryPolicy.none,
    httpClient: MockClient(
      (request) async => http.Response.bytes(body, 200),
    ),
  );
  try {
    if (models) {
      await client.listModels();
      return null;
    }
    final response = await client.systemOne(state: 's', questions: handles);
    handles.forEach(response.answer);
    response
      ..toJson()
      ..toString();
    return null;
  } on Object catch (e) {
    return e;
  } finally {
    client.close();
  }
}

void main() {
  test('the unmutated documents read cleanly', () async {
    expect(await readAll(utf8.encode(jsonEncode(validResponse))), isNull);
    expect(
      await readAll(utf8.encode(jsonEncode(validModels)), models: true),
      isNull,
    );
  });

  for (final (name, document, models) in [
    ('systemOne', validResponse, false),
    ('listModels', validModels, true),
  ]) {
    test('every mutation of a $name response reads or fails as a '
        'ResponseValidationException at the mutated path', () async {
      final failures = <String>[];
      for (final path in pathsOf(document)) {
        for (final raw in replacements) {
          final text = mutate(document, path, raw);
          final error = await readAll(utf8.encode(text), models: models);
          if (error == null) {
            continue;
          }
          if (error is! ResponseValidationException ||
              !blames(error.fieldPath, path)) {
            failures.add('$path := ${raw ?? '<deleted>'} → $error');
          }
        }
      }
      expect(failures, isEmpty, reason: failures.take(20).join('\n'));
    });
  }

  test('every truncation of a body fails at the document root', () async {
    final bytes = utf8.encode(jsonEncode(validResponse));
    for (var length = 0; length < bytes.length; length++) {
      final error = await readAll(bytes.sublist(0, length));
      expect(
        error,
        isA<ResponseValidationException>().having(
          (e) => e.fieldPath,
          'path',
          r'$',
        ),
        reason: 'cut at byte $length',
      );
    }
  });

  test('invalid UTF-8 or random bytes fail as validation errors', () async {
    final valid = utf8.encode(jsonEncode(validResponse));
    await forAll(
      (random) {
        if (random.nextBool()) {
          return Uint8List.fromList([
            for (var i = random.nextInt(64); i > 0; i--) random.nextInt(256),
          ]);
        }
        final at = random.nextInt(valid.length);
        const bad = [0xff, 0xc0, 0x80, 0xed, 0xf5];
        return Uint8List.fromList([
          ...valid.sublist(0, at),
          bad[random.nextInt(bad.length)],
          ...valid.sublist(at),
        ]);
      },
      describe: (bytes) => '$bytes',
      (bytes) async {
        final error = await readAll(bytes);
        // Random bytes can, rarely, spell valid JSON that is not an object.
        expect(error, isA<ResponseValidationException>());
      },
    );
  });

  group('deep nesting', () {
    const depth = 100000;
    final deep = '${'[' * depth}${']' * depth}';

    test('a deeply nested body fails as a validation error', () async {
      expect(
        await readAll(utf8.encode(deep)),
        isA<ResponseValidationException>(),
      );
    });

    test('a deeply nested legend value reads cleanly', () async {
      final text = mutate(validResponse, 'answers.urgency.legend.0', deep);
      expect(await readAll(utf8.encode(text)), isNull);
    });

    test('N6: equality of a deeply nested legend does not overflow', () {
      final text = mutate(validResponse, 'answers.urgency.legend.0', deep);
      final json = jsonDecode(text) as Map<String, Object?>;
      final a = SystemOneResponse.fromJson(json);
      final b = SystemOneResponse.fromJson(json);
      expect(() => a.hashCode, returnsNormally);
      expect(() => a == b, returnsNormally);
    });
  });
}

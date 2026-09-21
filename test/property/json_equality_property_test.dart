@Tags(['property'])
library;

import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/json/json_equality.dart';

import '../helpers/fuzz.dart';
import '../helpers/gen.dart';

void main() {
  test('jsonEquals agrees with DeepCollectionEquality', () async {
    await forAll(
      (random) {
        final a = randomJson(random);
        final b = switch (random.nextInt(3)) {
          0 => jsonDecode(jsonEncode(a)),
          1 => a,
          _ => randomJson(random),
        };
        return (a: a, b: b);
      },
      (pair) {
        final expected = const DeepCollectionEquality().equals(pair.a, pair.b);
        expect(jsonEquals(pair.a, pair.b), expected);
        expect(jsonEquals(pair.b, pair.a), expected);
        if (expected) {
          expect(jsonHash(pair.a), jsonHash(pair.b));
        }
      },
      runs: fuzzRuns(2000),
    );
  });

  test('an int and the equal double are equal and hash alike', () {
    expect(jsonEquals({'a': 1}, {'a': 1.0}), isTrue);
    expect(jsonHash(1), jsonHash(1.0));
  });

  test('a map never equals a list or a scalar', () {
    expect(jsonEquals(<String, Object?>{}, <Object?>[]), isFalse);
    expect(jsonEquals(<Object?>[], null), isFalse);
    expect(jsonEquals('a', <Object?>['a']), isFalse);
  });

  test('200 k levels of nesting compare without overflowing', () {
    Object? nest(int depth, {required bool asMap}) {
      Object? value = 'leaf';
      for (var i = 0; i < depth; i++) {
        value = asMap ? {'k': value} : [value];
      }
      return value;
    }

    for (final asMap in [true, false]) {
      final a = nest(200000, asMap: asMap);
      final b = nest(200000, asMap: asMap);
      expect(jsonEquals(a, b), isTrue);
      expect(jsonHash(a), jsonHash(b));
    }
  });

  test('changing any one leaf breaks equality', () async {
    await forAll(
      (random) => (tree: randomObject(random), seed: random.nextInt(1 << 30)),
      (input) {
        final copy = jsonDecode(jsonEncode(input.tree));
        if (_mutateOneLeaf(copy, Random(input.seed))) {
          expect(jsonEquals(input.tree, copy), isFalse);
        }
      },
    );
  });
}

/// Replaces one leaf of [json] in place with a value it can't equal; returns
/// whether it found a leaf to replace.
bool _mutateOneLeaf(Object? json, Random random) {
  switch (json) {
    case final Map<String, Object?> map when map.isNotEmpty:
      final key = map.keys.elementAt(random.nextInt(map.length));
      if (!_mutateOneLeaf(map[key], random)) {
        map[key] = _Sentinel.value;
      }
      return true;
    case final List<Object?> list when list.isNotEmpty:
      final i = random.nextInt(list.length);
      if (!_mutateOneLeaf(list[i], random)) {
        list[i] = _Sentinel.value;
      }
      return true;
    default:
      return false;
  }
}

/// A leaf no generated JSON value equals.
enum _Sentinel { value }

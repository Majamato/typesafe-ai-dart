/// Typed answers returned by the System One endpoint; all live in one
/// library because [Answer] is `sealed`.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/json/json_equality.dart';
import 'package:typesafe_ai_dart/src/json/json_fields.dart';
import 'package:typesafe_ai_dart/src/json/json_value_kind.dart';
import 'package:typesafe_ai_dart/src/shared/judgement_type.dart';

/// One answer from the `answers` map, always a calibrated judgement. Read it
/// through the question handle that asked for it to get the subtype, no cast.
/// A malformed answer fails with a [ResponseValidationException] whose field
/// path is relative to the answer object.
sealed class Answer {
  const Answer();

  /// Reads one decoded answer object.
  factory Answer.fromJson(Map<String, Object?> json) {
    final wire = readString(json, 'type');
    return switch (_types[wire]) {
      JudgementType.noul => NoulAnswer.fromJson(json),
      JudgementType.choice => ChoiceAnswer.fromJson(json),
      JudgementType.score => ScoreAnswer.fromJson(json),
      null => throw ResponseValidationException(
        'Unknown answer type "$wire"',
        fieldPath: 'type',
        actual: wire,
      ),
    };
  }

  static final Map<String, JudgementType> _types = JudgementType.values
      .asNameMap();

  /// Which judgement this answers.
  JudgementType get type => switch (this) {
    NoulAnswer() => JudgementType.noul,
    ChoiceAnswer() => JudgementType.choice,
    ScoreAnswer() => JudgementType.score,
  };

  /// Encodes this answer in the API's JSON shape. The `type` entry is written
  /// here so it can never drift from [type]; subtypes add the rest.
  Map<String, Object?> toJson() => {'type': type.name, ..._fields};

  /// Everything this answer encodes apart from `type`, in wire order.
  Map<String, Object?> get _fields;
}

/// Answer to a `Noul` question: probability the answer is yes. There is no
/// separate confidence — how far [noul] sits from 0.5 is the whole signal.
@immutable
final class NoulAnswer extends Answer {
  const NoulAnswer(this.noul);

  factory NoulAnswer.fromJson(Map<String, Object?> json) =>
      NoulAnswer(readDouble(json, 'noul'));

  /// Probability in `[0, 1]` that the condition holds; near 1 is yes, near 0
  /// is no. Passed through exactly as returned by the API — not clamped.
  final double noul;

  @override
  Map<String, Object?> get _fields => {'noul': noul};

  @override
  bool operator ==(Object other) => other is NoulAnswer && other.noul == noul;

  @override
  int get hashCode => noul.hashCode;

  @override
  String toString() => 'NoulAnswer(noul: $noul)';
}

/// Answer to a `Choice` question: selected option plus its distribution,
/// keyed by your own criteria keys. Ask with `TypedChoice` for typed options.
@immutable
base class ChoiceAnswer extends Answer {
  const ChoiceAnswer({
    required this.choice,
    required this.probabilities,
    required this.confidence,
  });

  factory ChoiceAnswer.fromJson(Map<String, Object?> json) => ChoiceAnswer(
    choice: readString(json, 'choice'),
    probabilities: readDoubles(json, 'probabilities'),
    confidence: readDouble(json, 'confidence'),
  );

  /// The option key the model selected. `SystemOneResponse.answer` checks it
  /// against the handle's criteria; the raw accessors pass it through as is.
  final String choice;

  /// Probability per option key. The values sum to roughly 1.
  final Map<String, double> probabilities;

  /// How concentrated the distribution is, in `[0, 1]`; summarises
  /// [probabilities], not a statement about overall correctness.
  final double confidence;

  /// Returns the probability of option [key], or 0 when the answer did not
  /// mention it — including when [key] is no option at all, undetectably.
  double probabilityOfKey(String key) => probabilities[key] ?? 0;

  @override
  Map<String, Object?> get _fields => {
    'choice': choice,
    'probabilities': probabilities,
    'confidence': confidence,
  };

  /// Compares the exact runtime type, so a raw answer never equals the
  /// [TypedChoiceAnswer] built from it.
  @override
  bool operator ==(Object other) =>
      other is ChoiceAnswer &&
      other.runtimeType == runtimeType &&
      other.choice == choice &&
      other.confidence == confidence &&
      const MapEquality<String, double>().equals(
        other.probabilities,
        probabilities,
      );

  @override
  int get hashCode => Object.hash(
    runtimeType,
    choice,
    confidence,
    const MapEquality<String, double>().hash(probabilities),
  );

  @override
  String toString() =>
      'ChoiceAnswer(choice: $choice, confidence: $confidence, '
      'probabilities: $probabilities)';
}

/// Answer to a `TypedChoice`: the same wire data as [ChoiceAnswer] with the
/// option resolved to a value of [E], which `SystemOneResponse.answer` builds.
@immutable
final class TypedChoiceAnswer<E extends Enum> extends ChoiceAnswer {
  TypedChoiceAnswer._({
    required this.selected,
    required Map<E, String> keyOf,
    required super.choice,
    required super.probabilities,
    required super.confidence,
  }) : _keyOf = keyOf;

  /// Reads [raw] over [values], keyed by [byKey] or else each value's `name`.
  factory TypedChoiceAnswer.from(
    ChoiceAnswer raw,
    List<E> values, {
    Map<String, E>? byKey,
  }) {
    final keys = byKey ?? {for (final value in values) value.name: value};
    return typedChoiceAnswer(
      raw,
      byKey: keys,
      keyOf: {for (final entry in keys.entries) entry.value: entry.key},
    );
  }

  /// The option the model picked; [choice] is its wire key.
  final E selected;

  /// Value to wire key for every option offered, shared with the question.
  final Map<E, String> _keyOf;

  /// Probability per option, one entry per value the question offered, so an
  /// option the answer left out reads 0. Unmodifiable; built on first use.
  late final Map<E, double> distribution = UnmodifiableMapView({
    for (final entry in _keyOf.entries)
      entry.key: probabilities[entry.value] ?? 0.0,
  });

  /// Returns the probability of [value], or 0 when the answer left it out.
  double probabilityOf(E value) => probabilities[_keyOf[value]] ?? 0;

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is TypedChoiceAnswer<E> &&
      MapEquality<E, double>().equals(other.distribution, distribution);

  @override
  int get hashCode =>
      Object.hash(super.hashCode, MapEquality<E, double>().hash(distribution));

  @override
  String toString() =>
      'TypedChoiceAnswer<$E>(selected: $selected, confidence: $confidence, '
      'distribution: $distribution)';
}

/// Resolves [raw] to a value of [E] through the question's precomputed
/// [byKey] and [keyOf]. Not exported from the package.
TypedChoiceAnswer<E> typedChoiceAnswer<E extends Enum>(
  ChoiceAnswer raw, {
  required Map<String, E> byKey,
  required Map<E, String> keyOf,
}) {
  final selected = byKey[raw.choice];
  if (selected == null) {
    throw ResponseValidationException(
      'Expected one of ${byKey.keys.join(', ')}, got "${raw.choice}"',
      fieldPath: 'choice',
      actual: raw.choice,
    );
  }
  return TypedChoiceAnswer<E>._(
    selected: selected,
    keyOf: keyOf,
    choice: raw.choice,
    probabilities: raw.probabilities,
    confidence: raw.confidence,
  );
}

/// Answer to a `Score` question: a position on the rubric. Levels are
/// 0-indexed as sent; [score] interpolates between two level indexes.
@immutable
final class ScoreAnswer extends Answer {
  const ScoreAnswer({
    required this.score,
    required this.legend,
    required this.probabilities,
    required this.confidence,
  });

  factory ScoreAnswer.fromJson(Map<String, Object?> json) => ScoreAnswer(
    score: readDouble(json, 'score'),
    legend: {
      for (final MapEntry(:key, :value) in readObject(json, 'legend').entries)
        _levelKey('legend', key): value,
    },
    probabilities: {
      for (final MapEntry(:key, :value) in readObject(
        json,
        'probabilities',
      ).entries)
        _levelKey('probabilities', key): switch (value) {
          final num p => p.toDouble(),
          _ => invalidValue(value, 'probabilities.$key', JsonValueKind.number),
        },
    },
    confidence: readDouble(json, 'confidence'),
  );

  /// Probability-weighted mean of the level indexes (0-based), e.g. 1.4 sits
  /// between the second and third level.
  final double score;

  /// Level description the API echoed back, keyed by level index; keeps
  /// whatever shape was sent — a string or a structured JSON object.
  final Map<int, Object?> legend;

  /// Probability per level index. The values sum to roughly 1.
  final Map<int, double> probabilities;

  /// How concentrated the distribution is, in `[0, 1]`.
  final double confidence;

  /// Index of the highest-probability level; ties go to whichever comes
  /// first in [probabilities], and an empty distribution yields 0.
  int get mostLikelyLevel {
    var best = 0;
    var bestP = double.negativeInfinity;
    for (final entry in probabilities.entries) {
      if (entry.value > bestP) {
        best = entry.key;
        bestP = entry.value;
      }
    }
    return best;
  }

  /// Returns the probability of [level], or 0 when the answer did not
  /// mention it.
  double probabilityOf(int level) => probabilities[level] ?? 0;

  @override
  Map<String, Object?> get _fields => {
    'score': score,
    'legend': {for (final e in legend.entries) '${e.key}': e.value},
    'probabilities': {
      for (final e in probabilities.entries) '${e.key}': e.value,
    },
    'confidence': confidence,
  };

  @override
  bool operator ==(Object other) =>
      other is ScoreAnswer &&
      other.score == score &&
      other.confidence == confidence &&
      jsonEquals(other.legend, legend) &&
      const MapEquality<int, double>().equals(
        other.probabilities,
        probabilities,
      );

  @override
  int get hashCode => Object.hash(
    score,
    confidence,
    Object.hashAllUnordered(
      legend.entries.map((e) => Object.hash(e.key, jsonHash(e.value))),
    ),
    const MapEquality<int, double>().hash(probabilities),
  );

  @override
  String toString() =>
      'ScoreAnswer(score: $score, confidence: $confidence, '
      'probabilities: $probabilities)';

  /// Reads [key] as a level index: plain decimal digits with no sign, space
  /// or leading zero, so no two spellings of a level can collide.
  static int _levelKey(String field, String key) {
    final parsed = _isDecimalIndex(key) ? int.tryParse(key) : null;
    if (parsed == null) {
      throw ResponseValidationException(
        'Expected an integer level key, got "$key"',
        fieldPath: '$field.$key',
        actual: key,
      );
    }
    return parsed;
  }

  static bool _isDecimalIndex(String key) {
    if (key.isEmpty || (key.length > 1 && key.codeUnitAt(0) == 0x30)) {
      return false;
    }
    for (var i = 0; i < key.length; i++) {
      final unit = key.codeUnitAt(i);
      if (unit < 0x30 || unit > 0x39) {
        return false;
      }
    }
    return true;
  }
}

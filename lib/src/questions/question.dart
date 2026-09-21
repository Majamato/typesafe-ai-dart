/// Typed question handles for the System One endpoint.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/json/json_codec.dart';
import 'package:typesafe_ai_dart/src/json/json_encodable.dart';
import 'package:typesafe_ai_dart/src/json/json_entry.dart';
import 'package:typesafe_ai_dart/src/shared/judgement_type.dart';

/// One judgement to ask about a request's state, answered as a distribution
/// rather than text. [A] lets a handle return its answer subtype, no cast.
///
/// A handle encodes itself when built and reuses the bytes in every request,
/// so build it once (a `static final`, say) rather than per call.
@immutable
sealed class Question<A extends Answer> {
  Question({required this.id, required Object instructions})
    : instructions = checkJsonEntry(instructions, name: 'instructions') {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    // Subclass fields are set by now: initializer lists all run first.
    _entry =
        (BytesBuilder(copy: false)
              ..add(jsonUtf8Encoder.convert(id))
              ..addByte(0x3A) // :
              ..add(encodeJsonArgument(toJson(), name: 'question "$id"')))
            .takeBytes();
  }

  /// Key of this question in the request/response; the model never sees it,
  /// so put the full meaning in [instructions]. Must be unique per request.
  final String id;

  /// What to judge. A string, or a JSON object or array for structured
  /// instructions. Reference state fields with backticks, as in `` `ticket` ``.
  final Object instructions;

  /// Which judgement this question asks.
  JudgementType get type;

  Map<String, Object?> toJson() => {
    'type': type.name,
    'instructions': instructions,
    ..._fields,
  };

  /// Everything this question encodes apart from `type` and `instructions`.
  Map<String, Object?> get _fields;

  /// `"<id>":{...}` as UTF-8 JSON, encoded when the question is built.
  late final Uint8List _entry;

  /// Reads [raw] as this question's own answer type.
  A _adopt(Answer raw) {
    if (raw is A) {
      return raw;
    }
    throw _mismatch(raw);
  }

  ResponseValidationException _mismatch(Answer raw) =>
      ResponseValidationException(
        'Expected a ${type.name} answer, got ${raw.type.name}',
        fieldPath: 'type',
        actual: raw.type.name,
      );

  @override
  String toString() => '${type.name}($id)';
}

/// Lets `SystemOneResponse` ask [question] to read [raw] as its own answer
/// type. Not exported from the package.
A adoptAnswer<A extends Answer>(Question<A> question, Answer raw) =>
    question._adopt(raw);

/// The cached `"<id>":{...}` bytes of [question], which a request splices
/// into its body. Not exported from the package.
Uint8List encodedQuestionEntry(Question<Answer> question) => question._entry;

/// Validates a choice's [options] in place and returns it.
Map<String, Object?> _checkChoiceOptions(
  Map<String, Object?> options, {
  required String name,
}) {
  if (options.isEmpty || options.length > Choice.maxOptions) {
    throw ArgumentError.value(
      options.length,
      name,
      'must contain between 1 and ${Choice.maxOptions} options',
    );
  }
  for (final MapEntry(:key, :value) in options.entries) {
    if (value != null && !isJsonEntry(value)) {
      invalidJsonEntry(value, '$name[$key]');
    }
  }
  return options;
}

/// A yes/no question, answered with the probability the answer is yes.
/// There is no hard verdict or separate confidence — pick your own threshold.
final class Noul extends Question<NoulAnswer> {
  /// [criteria] optionally spells out what counts as yes and no; without it
  /// the model relies on [instructions] alone.
  Noul({required super.id, required super.instructions, this.criteria});

  /// Definitions of the yes and no outcomes, or `null` to leave both to the
  /// instructions.
  final NoulCriteria? criteria;

  @override
  JudgementType get type => JudgementType.noul;

  @override
  Map<String, Object?> get _fields => {'criteria': ?criteria};
}

/// Definitions of a [Noul]'s two outcomes, encoded under keys `"true"`/
/// `"false"`; a side left `null` is omitted entirely.
@immutable
final class NoulCriteria implements JsonEncodable {
  NoulCriteria({Object? whenTrue, Object? whenFalse})
    : whenTrue = _checkSide(whenTrue, 'whenTrue'),
      whenFalse = _checkSide(whenFalse, 'whenFalse');

  /// What a yes answer means, or `null` when it needs no definition.
  final Object? whenTrue;

  /// What a no answer means, or `null` when it needs no definition.
  final Object? whenFalse;

  @override
  Map<String, Object?> toJson() => {'true': ?whenTrue, 'false': ?whenFalse};

  static Object? _checkSide(Object? side, String name) {
    checkJsonEntry(side, name: name, allowNull: true);
    encodeJsonArgument(side, name: name);
    return side;
  }
}

/// A question that picks exactly one option from a set you define. The
/// model sees your option keys alongside their descriptions — name them well.
final class Choice extends Question<ChoiceAnswer> {
  Choice({
    required super.id,
    required super.instructions,
    required Map<String, Object?> criteria,
  }) : criteria = Map.unmodifiable(
         _checkChoiceOptions(criteria, name: 'criteria'),
       );

  /// Builds a [TypedChoice] over [values], so the answer comes back as the
  /// picked value rather than its key. Shorthand for that constructor.
  static TypedChoice<E> fromEnum<E extends Enum>({
    required String id,
    required Object instructions,
    required List<E> values,
    Object? Function(E value)? describe,
    String Function(E value)? encode,
  }) => TypedChoice<E>(
    id: id,
    instructions: instructions,
    values: values,
    describe: describe,
    encode: encode,
  );

  /// Largest number of options the API accepts.
  static const maxOptions = 255;

  /// Option key to description, in the order given. Unmodifiable.
  final Map<String, Object?> criteria;

  @override
  JudgementType get type => JudgementType.choice;

  @override
  Map<String, Object?> get _fields => {'criteria': criteria};

  @override
  ChoiceAnswer _adopt(Answer raw) {
    final answer = super._adopt(raw);
    if (!criteria.containsKey(answer.choice)) {
      throw ResponseValidationException(
        'Expected one of ${criteria.keys.join(', ')}, got "${answer.choice}"',
        fieldPath: 'choice',
        actual: answer.choice,
      );
    }
    return answer;
  }
}

/// A [Choice] whose options are the values of the enum [E], answered with a
/// value of [E]. Encodes exactly as a [Choice], but is not a subtype of one.
final class TypedChoice<E extends Enum> extends Question<TypedChoiceAnswer<E>> {
  TypedChoice({
    required String id,
    required Object instructions,
    required List<E> values,
    Object? Function(E value)? describe,
    String Function(E value)? encode,
  }) : this._(
         id: id,
         instructions: instructions,
         values: values,
         byKey: _keyValues(values, encode ?? _enumName),
         describe: describe,
       );

  TypedChoice._({
    required super.id,
    required super.instructions,
    required List<E> values,
    required Map<String, E> byKey,
    required Object? Function(E value)? describe,
  }) : values = List.unmodifiable(values),
       byKey = Map.unmodifiable(byKey),
       _keyOf = Map.unmodifiable({
         for (final entry in byKey.entries) entry.value: entry.key,
       }),
       criteria = Map.unmodifiable(
         _checkChoiceOptions({
           for (final entry in byKey.entries)
             entry.key: describe?.call(entry.value),
         }, name: 'values'),
       );

  /// The options, in the order given. Unmodifiable.
  final List<E> values;

  /// Wire key to value, in the order of [values]; the reverse of the
  /// question's `encode`. Unmodifiable.
  final Map<String, E> byKey;

  /// Value to wire key, the reverse of [byKey], built once for the answers.
  final Map<E, String> _keyOf;

  /// Option key to description, in the order of [values]. Unmodifiable.
  final Map<String, Object?> criteria;

  @override
  JudgementType get type => JudgementType.choice;

  @override
  Map<String, Object?> get _fields => {'criteria': criteria};

  @override
  TypedChoiceAnswer<E> _adopt(Answer raw) {
    if (raw is! ChoiceAnswer) {
      throw _mismatch(raw);
    }
    return typedChoiceAnswer(raw, byKey: byKey, keyOf: _keyOf);
  }

  static String _enumName(Enum value) => value.name;
}

/// Keys [values] by [encode], in order. A loop rather than a map literal,
/// which would collapse a key two values share without a word.
Map<String, E> _keyValues<E extends Enum>(
  List<E> values,
  String Function(E value) encode,
) {
  final byKey = <String, E>{};
  for (final value in values) {
    final key = encode(value);
    if (byKey.containsKey(key)) {
      throw ArgumentError.value(
        key,
        'values',
        'is the key of both ${byKey[key]} and $value',
      );
    }
    byKey[key] = value;
  }
  return byKey;
}

/// A question that places the state on an ordered rubric you define; levels
/// are indexed from 0 in [criteria] and [ScoreAnswer.score] interpolates.
final class Score extends Question<ScoreAnswer> {
  Score({
    required super.id,
    required super.instructions,
    required List<Object> criteria,
  }) : criteria = List.unmodifiable(criteria) {
    if (criteria.length < minLevels || criteria.length > maxLevels) {
      throw ArgumentError.value(
        criteria.length,
        'criteria',
        'must contain between $minLevels and $maxLevels levels',
      );
    }
    for (var i = 0; i < criteria.length; i++) {
      final level = criteria[i];
      if (!isJsonEntry(level)) {
        invalidJsonEntry(level, 'criteria[$i]');
      }
    }
  }

  /// Smallest number of levels the API accepts.
  static const minLevels = 2;

  /// Largest number of levels the API accepts.
  static const maxLevels = 10;

  /// Ordered level descriptions, index 0 being the lowest. Unmodifiable.
  final List<Object> criteria;

  @override
  JudgementType get type => JudgementType.score;

  @override
  Map<String, Object?> get _fields => {'criteria': criteria};
}

/// A structured [Score] level, encoded as `{"summary": ..., "signals": [...]}`
/// with `signals` left out when empty.
@immutable
final class ScoreLevel implements JsonEncodable {
  const ScoreLevel({required this.summary, this.signals = const []});

  final String summary;

  /// Concrete cues that place the state at this level.
  final List<String> signals;

  @override
  Map<String, Object?> toJson() => {
    'summary': summary,
    if (signals.isNotEmpty) 'signals': signals,
  };
}

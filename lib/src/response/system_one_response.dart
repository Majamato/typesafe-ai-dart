import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/json/json_fields.dart';
import 'package:typesafe_ai_dart/src/json/json_value_kind.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/response/usage.dart';

/// The answers to one `POST /v1/systemone` call, keyed by question id. Read
/// them through the question handles that were sent to get the concrete type.
///
/// A malformed body, a missing answer, or an answer its handle can't read
/// fails with a [ResponseValidationException] naming the field at fault,
/// e.g. `answers.tone.confidence`.
@immutable
final class SystemOneResponse {
  /// Wraps [answers] without copying it, so don't change it afterwards.
  SystemOneResponse({
    required this.model,
    required Map<String, Answer> answers,
    required this.usage,
    this.requestId,
    this.raw,
  }) : answers = UnmodifiableMapView(answers);

  /// Reads a decoded response body.
  factory SystemOneResponse.fromJson(
    Map<String, Object?> json, {
    String? requestId,
    RawResponse? raw,
  }) => SystemOneResponse(
    model: readString(json, 'model'),
    answers: {
      for (final MapEntry(:key, :value) in readObject(json, 'answers').entries)
        key: _answerAt(key, value),
    },
    usage: switch (json['usage']) {
      null => const Usage(inputTokens: 0, outputTokens: 0),
      final Map<String, Object?> usage => Usage.fromJson(usage),
      _ => invalidField(json, 'usage', JsonValueKind.object),
    },
    requestId: requestId,
    raw: raw,
  );

  /// The model version that answered, such as `jev-1.13.0`.
  final String model;

  /// Every answer keyed by question id. Unmodifiable.
  final Map<String, Answer> answers;

  /// Token usage for this call, zero when the response reported none.
  final Usage usage;

  /// Value of the `x-typesafe-request-id` header, useful in support requests.
  final String? requestId;

  /// The HTTP response this was read from: status, headers and the body
  /// bytes, as received. `null` when built by hand, or by
  /// [SystemOneResponse.fromJson] without it.
  final RawResponse? raw;

  /// Unlike `this[id]`, checks the answer's type and option against the
  /// handle, and resolves an enum choice to its value.
  A answer<A extends Answer>(Question<A> question) {
    final found = answers[question.id];
    if (found == null) {
      throw ResponseValidationException(
        'No answer for question "${question.id}"',
        fieldPath: 'answers.${question.id}',
      );
    }
    try {
      return adoptAnswer(question, found);
    } on ResponseValidationException catch (e) {
      throw nestUnder(e, 'answers.${question.id}');
    }
  }

  /// Returns the untyped answer for [id], or `null` if absent. Prefer
  /// [answer] when the question handle is at hand — it types the result.
  Answer? operator [](String id) => answers[id];

  /// Only the noul answers, keyed by question id.
  Map<String, NoulAnswer> get nouls => _ofType<NoulAnswer>();

  /// Only the choice answers, keyed by question id. Always raw: decoding
  /// never sees the questions, so [answer] is what resolves an enum option.
  Map<String, ChoiceAnswer> get choices => _ofType<ChoiceAnswer>();

  /// Only the score answers, keyed by question id.
  Map<String, ScoreAnswer> get scores => _ofType<ScoreAnswer>();

  /// [requestId] and [raw] are left out: they describe the HTTP exchange,
  /// not the body.
  Map<String, Object?> toJson() => {
    'model': model,
    'answers': {for (final e in answers.entries) e.key: e.value.toJson()},
    'usage': usage.toJson(),
  };

  static Answer _answerAt(String id, Object? value) {
    try {
      return switch (value) {
        final Map<String, Object?> json => Answer.fromJson(json),
        _ => invalidValue(value, r'$', JsonValueKind.object),
      };
    } on ResponseValidationException catch (e) {
      throw nestUnder(e, 'answers.$id');
    }
  }

  Map<String, A> _ofType<A extends Answer>() => {
    for (final entry in answers.entries)
      if (entry.value case final A answer) entry.key: answer,
  };

  @override
  bool operator ==(Object other) =>
      other is SystemOneResponse &&
      other.model == model &&
      other.usage == usage &&
      other.requestId == requestId &&
      const MapEquality<String, Answer>().equals(other.answers, answers);

  @override
  int get hashCode => Object.hash(
    model,
    usage,
    requestId,
    const MapEquality<String, Answer>().hash(answers),
  );

  @override
  String toString() =>
      'SystemOneResponse(model: $model, answers: ${answers.keys.toList()}, '
      'usage: $usage)';
}

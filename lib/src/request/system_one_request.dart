import 'dart:typed_data';

import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/json/json_codec.dart';
import 'package:typesafe_ai_dart/src/json/json_entry.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';

/// One call to `POST /v1/systemone`: the state to judge and the questions to
/// ask about it. [state] and [extra] are validated and encoded on
/// construction, so later changes to them are never sent. The [questions]
/// list is kept as given and read on every send, so don't change it.
final class SystemOneRequest {
  SystemOneRequest({
    required Object state,
    required this.questions,
    this.model,
    this.extra = const {},
  }) : state = checkJsonEntry(state, name: 'state'),
       _stateJson = encodeJsonArgument(state, name: 'state'),
       _extraJson = _encodeExtra(extra) {
    if (questions.isEmpty) {
      throw ArgumentError.value(questions, 'questions', 'must not be empty');
    }
    final seen = <String>{};
    for (final question in questions) {
      if (!seen.add(question.id)) {
        throw ArgumentError.value(
          question.id,
          'questions',
          'contains duplicate question id',
        );
      }
    }
  }

  /// The content to judge, as passed in; [encode] sends the JSON it had when
  /// this request was built.
  final Object state;

  /// [state] as UTF-8 JSON.
  final Uint8List _stateJson;

  /// Each non-reserved [extra] entry as `,"<key>":<value>`, or `null` for none.
  final Uint8List? _extraJson;

  /// The questions, in the order given; their ids were unique when this
  /// request was built. The list itself, not a copy.
  final List<Question<Answer>> questions;

  /// Model identifier, or `null` to use the client default.
  final String? model;

  /// Extra top-level body fields; `state`, `model` and `questions` always
  /// win over an entry of the same name.
  final Map<String, Object?> extra;

  /// This request in the API's JSON shape, as `jsonEncode` accepts it. The
  /// client sends [encode]'s bytes instead; this is for logging.
  Map<String, Object?> toJson({required String defaultModel}) => {
    ...extra,
    'state': state,
    'model': model ?? defaultModel,
    'questions': {for (final q in questions) q.id: q.toJson()},
  };

  /// The request body as UTF-8 JSON, spliced from bytes encoded earlier;
  /// [defaultModelJson] is the client's default model, already encoded.
  Uint8List encode({required List<int> defaultModelJson}) {
    final model = this.model;
    final body = BytesBuilder(copy: false)
      ..add(_stateKey)
      ..add(_stateJson)
      ..add(_modelKey)
      ..add(model == null ? defaultModelJson : jsonUtf8Encoder.convert(model))
      ..add(_questionsKey)
      ..add(encodedQuestionEntry(questions[0]));
    for (var i = 1; i < questions.length; i++) {
      body
        ..add(_comma)
        ..add(encodedQuestionEntry(questions[i]));
    }
    body.add(_closeBrace);
    if (_extraJson case final extra?) {
      body.add(extra);
    }
    return (body..add(_closeBrace)).takeBytes();
  }

  static Uint8List? _encodeExtra(Map<String, Object?> extra) {
    if (extra.isEmpty) {
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    for (final MapEntry(:key, :value) in extra.entries) {
      if (_reserved.contains(key)) {
        continue;
      }
      bytes
        ..add(_comma)
        ..add(jsonUtf8Encoder.convert(key))
        ..add(_colon)
        ..add(encodeJsonArgument(value, name: 'extra[$key]'));
    }
    return bytes.isEmpty ? null : bytes.takeBytes();
  }

  @override
  String toString() {
    final ids = questions.map((q) => q.id).toList();
    return 'SystemOneRequest(model: $model, questions: $ids)';
  }

  static const _reserved = {'state', 'model', 'questions'};

  // Shared chunks: `addByte` on a non-copying builder allocates each time.
  static final Uint8List _comma = _ascii(',');
  static final Uint8List _colon = _ascii(':');
  static final Uint8List _closeBrace = _ascii('}');
  static final Uint8List _stateKey = _ascii('{"state":');
  static final Uint8List _modelKey = _ascii(',"model":');
  static final Uint8List _questionsKey = _ascii(',"questions":{');

  static Uint8List _ascii(String text) => Uint8List.fromList(text.codeUnits);
}

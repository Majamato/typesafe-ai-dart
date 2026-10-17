import 'dart:convert';
import 'dart:typed_data';

import 'package:typesafe_ai_dart/src/answers/answer.dart';
import 'package:typesafe_ai_dart/src/assets/image.dart';
import 'package:typesafe_ai_dart/src/json/json_codec.dart';
import 'package:typesafe_ai_dart/src/json/json_entry.dart';
import 'package:typesafe_ai_dart/src/questions/question.dart';

/// One call to `POST /v1/systemone`: the state to judge and the questions to
/// ask about it. [state] and [extra] are validated and encoded on
/// construction, so later changes to them are never sent. The [questions]
/// list is kept as given and read on every send, so don't change it.
///
/// A request with no `Image` anywhere is sent as JSON. One with images is
/// sent as `multipart/form-data`: the JSON body as the `request` part, with
/// an `assets` map naming one file part per image. See [contentType].
final class SystemOneRequest {
  factory SystemOneRequest({
    required Object state,
    required List<Question<Answer>> questions,
    String? model,
    Map<String, Object?> extra = const {},
  }) {
    checkJsonEntry(state, name: 'state');
    final outer = startCollectingImages();
    final Uint8List stateJson;
    final List<Image>? found;
    try {
      stateJson = encodeJsonArgument(state, name: 'state');
    } finally {
      found = stopCollectingImages(outer);
    }
    final extraJson = _encodeExtra(extra);
    if (questions.isEmpty) {
      throw ArgumentError.value(questions, 'questions', 'must not be empty');
    }
    var hasImageQuestion = false;
    final seen = <String>{};
    for (final question in questions) {
      if (!seen.add(question.id)) {
        throw ArgumentError.value(
          question.id,
          'questions',
          'contains duplicate question id',
        );
      }
      if (question is Box || questionImages(question) != null) {
        hasImageQuestion = true;
      }
    }
    return SystemOneRequest._(
      state: state,
      questions: questions,
      model: model,
      extra: extra,
      stateJson: stateJson,
      extraJson: extraJson,
      multipart: found == null && !hasImageQuestion
          ? null
          : _Multipart.of(found, questions, extra),
      needsImages: found != null || hasImageQuestion,
    );
  }

  SystemOneRequest._({
    required this.state,
    required this.questions,
    required this.model,
    required this.extra,
    required Uint8List stateJson,
    required Uint8List? extraJson,
    required _Multipart? multipart,
    required bool needsImages,
  }) : _stateJson = stateJson,
       _extraJson = extraJson,
       _multipart = multipart,
       _needsImages = needsImages;

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
  /// win over an entry of the same name. It can't hold an `Image`, and an
  /// `assets` entry can't be combined with `Image` values, which make their
  /// own.
  final Map<String, Object?> extra;

  /// How the images are sent, or `null` when the request has none.
  final _Multipart? _multipart;

  /// Whether the request carries an image or asks a `Box` question, so the
  /// API needs `DangerZone.images` to read it.
  final bool _needsImages;

  /// The content type of [encode]'s bytes: `application/json`, or
  /// `multipart/form-data` with its boundary when the request has images.
  String get contentType => _multipart?.contentType ?? jsonContentType;

  /// This request in the API's JSON shape, as `jsonEncode` accepts it. The
  /// client sends [encode]'s bytes instead; this is for logging.
  Map<String, Object?> toJson({required String defaultModel}) => {
    ...extra,
    'state': state,
    'model': model ?? defaultModel,
    'questions': {for (final q in questions) q.id: q.toJson()},
    if (_multipart case final multipart?) 'assets': multipart.assets,
  };

  /// The request body, spliced from bytes encoded earlier: UTF-8 JSON, or
  /// multipart around it when the request has images (see [contentType]).
  /// [defaultModelJson] is the client's default model, already encoded.
  Uint8List encode({required List<int> defaultModelJson}) {
    final model = this.model;
    final multipart = _multipart;
    final body = BytesBuilder(copy: false);
    if (multipart != null) {
      body.add(multipart.head);
    }
    body
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
    if (multipart == null) {
      return (body..add(_closeBrace)).takeBytes();
    }
    body
      ..add(multipart.assetsJson)
      ..add(_closeBrace);
    multipart.tail.forEach(body.add);
    return body.takeBytes();
  }

  /// Throws on an `Image` in [extra]: the API looks for references only in
  /// the state, instructions and criteria, so it would reject the upload.
  static Uint8List? _encodeExtra(Map<String, Object?> extra) {
    if (extra.isEmpty) {
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    final outer = startCollectingImages();
    final List<Image>? images;
    try {
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
    } finally {
      images = stopCollectingImages(outer);
    }
    if (images != null) {
      throw ArgumentError(
        "can't hold an Image: the API reads images only in the state, "
            'instructions and criteria',
        'extra',
      );
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

/// The content type of a request without images.
const jsonContentType = 'application/json';

/// Whether [request] carries an image or asks a `Box` question. Not exported
/// from the package.
bool requestNeedsImages(SystemOneRequest request) => request._needsImages;

/// [request]'s multipart content type, or `null` when it is sent as JSON.
/// Not exported from the package.
String? multipartContentType(SystemOneRequest request) =>
    request._multipart?.contentType;

/// The multipart framing of a request with images, built once: the JSON body
/// goes between [head] and [tail], with [assetsJson] spliced in last.
final class _Multipart {
  _Multipart._(this.boundary, this.images)
    : assets = {
        for (var i = 0; i < images.length; i++)
          images[i].reference: {'type': 'image', 'part': _partName(i)},
      };

  /// Gathers every distinct image in [found] (from the state) and
  /// in the questions, and checks that no two share a reference. Returns
  /// `null` when there are none, as for a request whose only image work is
  /// a `Box` question.
  static _Multipart? of(
    List<Image>? found,
    List<Question<Answer>> questions,
    Map<String, Object?> extra,
  ) {
    final byReference = <String, Image>{};
    void add(Image image) {
      final known = byReference.putIfAbsent(image.reference, () => image);
      if (!identical(known, image)) {
        throw ArgumentError.value(
          image.reference,
          'reference',
          'is shared by two different images',
        );
      }
    }

    found?.forEach(add);
    for (final question in questions) {
      questionImages(question)?.forEach(add);
    }
    if (byReference.isEmpty) {
      return null;
    }
    if (extra.containsKey('assets')) {
      throw ArgumentError(
        "can't hold 'assets' when the request has Image values",
        'extra',
      );
    }
    return _Multipart._(
      'typesafe-${randomHex()}',
      List.unmodifiable(byReference.values),
    );
  }

  /// Separates the parts; random, so it can't occur in the content.
  final String boundary;

  /// Each image once, in the order first met.
  final List<Image> images;

  /// The `assets` map the JSON body carries: reference to file part.
  final Map<String, Object?> assets;

  String get contentType => 'multipart/form-data; boundary=$boundary';

  /// The opening boundary and the headers of the `request` part.
  late final Uint8List head = _latin1(
    '--$boundary\r\n'
    'Content-Disposition: form-data; name="request"\r\n'
    'Content-Type: $jsonContentType\r\n\r\n',
  );

  /// `,"assets":{...}`, the last entry of the JSON body.
  late final Uint8List assetsJson = Uint8List.fromList([
    ...utf8.encode(',"assets":'),
    ...jsonUtf8Encoder.convert(assets),
  ]);

  /// Each image's part, headers then bytes, and the closing boundary.
  late final List<Uint8List> tail = [
    for (var i = 0; i < images.length; i++) ...[
      _latin1(
        '\r\n--$boundary\r\n'
        'Content-Disposition: form-data; name="${_partName(i)}"; '
        'filename="${_partName(i)}.${images[i].format.name}"\r\n'
        'Content-Type: ${images[i].format.mimeType}\r\n\r\n',
      ),
      images[i].bytes,
    ],
    _latin1('\r\n--$boundary--\r\n'),
  ];

  static String _partName(int index) => 'image-$index';

  static Uint8List _latin1(String text) => latin1.encode(text);
}

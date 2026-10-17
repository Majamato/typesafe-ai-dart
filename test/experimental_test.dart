import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/src/assets/image.dart'
    show startCollectingImages, stopCollectingImages;
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import 'helpers/mock_transport.dart';
import 'helpers/multipart.dart';

final Uint8List _model = utf8.encode('"jev-test"');

/// Fails if an image recording is still open, as one an encode leaks when it
/// skips its cleanup: every image encoded afterwards would pile up in it.
void _expectNoRecording() {
  final outer = startCollectingImages();
  stopCollectingImages(outer);
  expect(outer, isNull, reason: 'an image recording was left open');
}

Map<String, Object?> _decode(String body) =>
    jsonDecode(body) as Map<String, Object?>;

/// The JSON of the `request` part of a multipart [request].
Map<String, Object?> _requestJson(SystemOneRequest request) {
  final parts = parseMultipart(
    request.encode(defaultModelJson: _model),
    request.contentType,
  );
  return jsonDecode(utf8.decode(parts.first.body)) as Map<String, Object?>;
}

const _boxBody = '''
{"model":"jev-1.14.0",
 "answers":{
   "seen":{"type":"noul","noul":0.9},
   "mug":{"type":"box","box":{"top":0.25,"bottom":0.82,"left":0.44,
          "right":0.84},"confidence":0.92}},
 "usage":{"input_tokens":290,"output_tokens":21}}
''';

void main() {
  group('Image', () {
    test('detects PNG and JPEG from the bytes', () {
      expect(Image(fakePng()).format, ImageFormat.png);
      expect(Image(fakeJpeg()).format, ImageFormat.jpeg);
      expect(ImageFormat.png.mimeType, 'image/png');
      expect(ImageFormat.jpeg.mimeType, 'image/jpeg');
    });

    test('rejects bytes that are no PNG or JPEG', () {
      for (final bytes in [
        Uint8List(0),
        Uint8List.fromList([0x89, 0x50]),
        Uint8List.fromList([0xFF, 0xD8, 0x00, 0x00]),
        Uint8List.fromList(utf8.encode('GIF89a......')),
      ]) {
        expect(() => Image(bytes), throwsArgumentError);
      }
    });

    test('makes a random reference unless given one', () {
      final a = Image(fakePng());
      final b = Image(fakePng());
      expect(a.reference, matches(RegExp(r'^image_[0-9a-f]{32}$')));
      expect(a.reference, isNot(b.reference));
      expect(Image(fakePng(), reference: 'door.jpg').reference, 'door.jpg');
      expect(() => Image(fakePng(), reference: ''), throwsArgumentError);
      expect(() => Image(fakePng(), reference: ' \t'), throwsArgumentError);
    });

    test('encodes as its reference, but prints as a description', () {
      final image = Image(fakePng(), reference: 'ref-1');
      expect(jsonEncode({'a': image}), '{"a":"ref-1"}');
      expect(image.toString(), 'Image(png, ${fakePng().length} bytes, ref-1)');
    });

    test('fromFile reads the file', () async {
      final dir = await Directory.systemTemp.createTemp('typesafe_image');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.jpg')..writeAsBytesSync(fakeJpeg());
      final image = await Image.fromFile(file.path, reference: 'a');
      expect(image.bytes, fakeJpeg());
      expect(image.format, ImageFormat.jpeg);
    });
  });

  group('TextWithImages', () {
    test('joins strings and references in order', () {
      final poster = Image(fakePng(), reference: 'POSTER');
      final parts = <Object>['Same dog as ', poster, '?'];
      final text = TextWithImages(parts);
      parts.add(' Really?');
      expect(jsonEncode(text), '"Same dog as POSTER?"');
      expect(text.parts, hasLength(3));
      expect(() => text.parts.add('x'), throwsUnsupportedError);
    });

    test('accepts only strings and images', () {
      expect(() => TextWithImages(const ['a', 1]), throwsArgumentError);
    });
  });

  group('Box', () {
    test('encodes with no criteria', () {
      final box = Box(id: 'mug', instructions: 'the mug in `photo`');
      expect(box.type, JudgementType.box);
      expect(box.toJson(), {
        'type': 'box',
        'instructions': 'the mug in `photo`',
      });
    });

    test('its answer decodes, re-encodes and compares', () {
      final json = _decode(_boxBody)['answers']! as Map<String, Object?>;
      final answer = Answer.fromJson(json['mug']! as Map<String, Object?>);
      expect(answer, isA<BoxAnswer>());
      final box = answer as BoxAnswer;
      expect(box.top, 0.25);
      expect(box.bottom, 0.82);
      expect(box.left, 0.44);
      expect(box.right, 0.84);
      expect(box.confidence, 0.92);
      expect(box.width, closeTo(0.40, 1e-9));
      expect(box.height, closeTo(0.57, 1e-9));
      expect(box.toJson(), json['mug']);
      expect(Answer.fromJson(box.toJson()), box);
      expect(Answer.fromJson(box.toJson()).hashCode, box.hashCode);
      expect(box.toString(), contains('BoxAnswer(top: 0.25'));
    });

    test('answers differing in any one value are not equal', () {
      const base = BoxAnswer(
        top: 0.1,
        bottom: 0.9,
        left: 0.2,
        right: 0.8,
        confidence: 0.5,
      );
      const others = [
        BoxAnswer(top: 0, bottom: 0.9, left: 0.2, right: 0.8, confidence: 0.5),
        BoxAnswer(top: 0.1, bottom: 1, left: 0.2, right: 0.8, confidence: 0.5),
        BoxAnswer(top: 0.1, bottom: 0.9, left: 0, right: 0.8, confidence: 0.5),
        BoxAnswer(top: 0.1, bottom: 0.9, left: 0.2, right: 1, confidence: 0.5),
        BoxAnswer(top: 0.1, bottom: 0.9, left: 0.2, right: 0.8, confidence: 1),
      ];
      for (final other in others) {
        expect(other, isNot(base));
        expect(other.hashCode, isNot(base.hashCode));
      }
    });

    test('a malformed answer names the field at fault', () {
      void expectPath(Map<String, Object?> json, String path) => expect(
        () => BoxAnswer.fromJson(json),
        throwsA(
          isA<ResponseValidationException>().having(
            (e) => e.fieldPath,
            'fieldPath',
            path,
          ),
        ),
      );
      const edges = {'top': 0, 'bottom': 1, 'left': 0, 'right': 1};
      expectPath({'type': 'box', 'confidence': 1}, 'box');
      expectPath({'type': 'box', 'box': 'x', 'confidence': 1}, 'box');
      expectPath({
        'type': 'box',
        'box': {...edges}..remove('left'),
        'confidence': 1,
      }, 'box.left');
      expectPath({
        'type': 'box',
        'box': {...edges, 'top': 'high'},
        'confidence': 1,
      }, 'box.top');
      expectPath({'type': 'box', 'box': edges}, 'confidence');
    });

    test('a response reads it through its handle, typed', () {
      final mug = Box(id: 'mug', instructions: 'the mug in `photo`');
      final seen = Noul(id: 'seen', instructions: 'Is there a mug?');
      final response = SystemOneResponse.fromJson(_decode(_boxBody));
      // `.left` compiles only because the handle types the answer.
      final box = response.answer(mug);
      expect(box.left, 0.44);
      expect(
        () => response.answer(Box(id: 'seen', instructions: 'x')),
        throwsA(isA<ResponseValidationException>()),
      );
      expect(response.answer(seen).noul, 0.9);
    });
  });

  group('a request with images', () {
    final noul = Noul(id: 'n', instructions: 'Is it a dog?');

    test('without any stays JSON, with no assets', () {
      final request = SystemOneRequest(state: 'text', questions: [noul]);
      expect(request.contentType, 'application/json');
      expect(request.toJson(defaultModel: 'm').containsKey('assets'), isFalse);
      final body = request.encode(defaultModelJson: _model);
      expect(jsonDecode(utf8.decode(body)), {
        'state': 'text',
        'model': 'jev-test',
        'questions': {'n': noul.toJson()},
      });
    });

    test('in the state is sent as multipart, the JSON part first', () {
      final photo = Image(fakePng(40), reference: 'PHOTO');
      final request = SystemOneRequest(
        state: {'photo': photo, 'note': 'found in the park'},
        questions: [noul],
        extra: const {'trace': 'abc'},
      );
      expect(
        request.contentType,
        matches(
          RegExp(r'^multipart/form-data; boundary=typesafe-[0-9a-f]{32}$'),
        ),
      );
      final parts = parseMultipart(
        request.encode(defaultModelJson: _model),
        request.contentType,
      );
      expect(parts.map((p) => p.name), ['request', 'image-0']);
      expect(parts[0].filename, isNull);
      expect(parts[0].headers['content-type'], 'application/json');
      expect(jsonDecode(utf8.decode(parts[0].body)), {
        'state': {'photo': 'PHOTO', 'note': 'found in the park'},
        'model': 'jev-test',
        'questions': {'n': noul.toJson()},
        'trace': 'abc',
        'assets': {
          'PHOTO': {'type': 'image', 'part': 'image-0'},
        },
      });
      expect(parts[1].filename, 'image-0.png');
      expect(parts[1].headers['content-type'], 'image/png');
      expect(parts[1].body, photo.bytes);
      expect(request.toJson(defaultModel: 'm')['assets'], {
        'PHOTO': {'type': 'image', 'part': 'image-0'},
      });
    });

    test('in instructions and every kind of criteria is found once each', () {
      final badge = Image(fakeJpeg(), reference: 'BADGE');
      final thumb = Image(fakePng(), reference: 'THUMB');
      final fist = Image(fakePng(8), reference: 'FIST');
      final open = Image(fakeJpeg(9), reference: 'OPEN');
      final questions = <Question<Answer>>[
        Noul(
          id: 'same',
          instructions: TextWithImages(['Same person as ', badge, '?']),
          criteria: NoulCriteria(
            whenTrue: {
              'examples': [thumb],
            },
          ),
        ),
        Choice(
          id: 'gesture',
          instructions: 'Which gesture?',
          criteria: {'thumbs_up': thumb, 'fist': fist, 'none': null},
        ),
        Score(id: 'open', instructions: 'How open?', criteria: [fist, open]),
      ];
      final request = SystemOneRequest(
        state: {'camera': badge},
        questions: questions,
      );
      final json = _requestJson(request);
      expect((json['assets']! as Map).keys, [
        'BADGE',
        'THUMB',
        'FIST',
        'OPEN',
      ]);
      final parts = parseMultipart(
        request.encode(defaultModelJson: _model),
        request.contentType,
      );
      expect(parts.skip(1).map((p) => p.body), [
        badge.bytes,
        thumb.bytes,
        fist.bytes,
        open.bytes,
      ]);
      expect(parts.skip(1).map((p) => p.filename), [
        'image-0.jpeg',
        'image-1.png',
        'image-2.png',
        'image-3.jpeg',
      ]);
      expect(
        (json['questions']! as Map)['same'],
        containsPair('instructions', 'Same person as BADGE?'),
      );
    });

    test('a question keeps its images across requests', () {
      final badge = Image(fakePng(), reference: 'BADGE');
      final same = Noul(
        id: 'same',
        instructions: TextWithImages(['As in ', badge]),
      );
      for (final state in ['one', 'two']) {
        final request = SystemOneRequest(state: state, questions: [same]);
        expect((_requestJson(request)['assets']! as Map).keys, ['BADGE']);
      }
    });

    test('rejects two different images under one reference', () {
      expect(
        () => SystemOneRequest(
          state: [Image(fakePng(), reference: 'x')],
          questions: [
            Noul(
              id: 'n',
              instructions: TextWithImages([Image(fakeJpeg(), reference: 'x')]),
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test("rejects an 'assets' extra next to images, keeps it without", () {
      expect(
        () => SystemOneRequest(
          state: Image(fakePng()),
          questions: [noul],
          extra: const {'assets': <String, Object?>{}},
        ),
        throwsArgumentError,
      );
      // Hand-made assets, as 0.1.0 allowed, still pass through untouched.
      final manual = SystemOneRequest(
        state: 'REF',
        questions: [noul],
        extra: const {
          'assets': {
            'REF': {'type': 'image', 'format': 'png', 'data_base64': 'AA=='},
          },
        },
      );
      expect(manual.contentType, 'application/json');
      expect(
        _decode(utf8.decode(manual.encode(defaultModelJson: _model))),
        containsPair('assets', {
          'REF': {'type': 'image', 'format': 'png', 'data_base64': 'AA=='},
        }),
      );
    });

    test('rejects an image in extra, which the API never reads', () {
      expect(
        () => SystemOneRequest(
          state: 'text',
          questions: [noul],
          extra: {
            'trace': {'photo': Image(fakePng())},
          },
        ),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'extra'),
        ),
      );
      _expectNoRecording();
    });

    test('a Box with no image of its own stays JSON', () {
      final request = SystemOneRequest(
        state: 'REF',
        questions: [Box(id: 'b', instructions: 'the mug')],
      );
      expect(request.contentType, 'application/json');
    });

    test('a failed encode leaves no image collection behind', () {
      expect(
        () => SystemOneRequest(
          state: {'photo': Image(fakePng()), 'bad': Object()},
          questions: [noul],
        ),
        throwsArgumentError,
      );
      _expectNoRecording();
      expect(
        () => Noul(
          id: 'x',
          instructions: [Image(fakePng()), double.nan],
        ),
        throwsArgumentError,
      );
      _expectNoRecording();
      final plain = SystemOneRequest(state: 'text', questions: [noul]);
      expect(plain.contentType, 'application/json');
    });

    test('a successful encode closes its collection too', () {
      SystemOneRequest(state: Image(fakePng()), questions: [noul]);
      _expectNoRecording();
      Noul(id: 'x', instructions: TextWithImages([Image(fakePng())]));
      _expectNoRecording();
    });

    test('an image encoded inside another encode counts toward the outer', () {
      final inner = Image(fakePng(), reference: 'INNER');
      final request = SystemOneRequest(
        state: _EncodesAQuestion(inner),
        questions: [noul],
      );
      expect((_requestJson(request)['assets']! as Map).keys, ['INNER']);
    });
  });

  group('the client', () {
    final photo = Image(fakePng(24), reference: 'PHOTO');
    final box = Box(id: 'mug', instructions: 'the mug in `photo`');
    final seen = Noul(id: 'seen', instructions: 'Is there a mug?');

    test('refuses images or a Box without DangerZone.images', () async {
      final scripted = ScriptedClient([const Step(200, body: _boxBody)]);
      final client = clientFor(scripted);
      await expectLater(
        client.systemOne(state: {'photo': photo}, questions: [seen]),
        throwsArgumentError,
      );
      await expectLater(
        client.systemOne(state: 'x', questions: [box]),
        throwsArgumentError,
      );
      await expectLater(
        client.systemOne(
          state: 'x',
          questions: [box],
          options: const RequestOptions(dangerZone: {DangerZone.longContext}),
        ),
        throwsArgumentError,
      );
      expect(scripted.requests, isEmpty);
    });

    test('sends multipart with the images header when turned on', () async {
      final scripted = ScriptedClient([const Step(200, body: _boxBody)]);
      final client = TypeSafeClient(
        apiKey: 'sk-test',
        baseUrl: 'https://api.test',
        defaultModel: 'jev-test',
        httpClient: scripted.client,
        dangerZone: const {DangerZone.images},
      );
      final response = await client.systemOne(
        state: {'photo': photo},
        questions: [seen, box],
      );
      expect(response.answer(box).confidence, 0.92);
      final request = scripted.requests.single;
      expect(request.headers['typesafe-danger-zone-images'], 'true');
      expect(request.headers['content-type'], startsWith('multipart/'));
      expect(request.headers['accept'], 'application/json');
      final parts = parseMultipart(
        request.bodyBytes,
        request.headers['content-type']!,
      );
      expect(parts.map((p) => p.name), ['request', 'image-0']);
      expect(parts[1].body, photo.bytes);
    });

    test('per call, through options or the raw header', () async {
      final scripted = ScriptedClient([const Step(200, body: _boxBody)]);
      final client = clientFor(scripted);
      await client.systemOne(
        state: {'photo': photo},
        questions: [box],
        options: const RequestOptions(
          dangerZone: {DangerZone.images, DangerZone.longContext},
        ),
      );
      await client.systemOne(
        state: {'photo': photo},
        questions: [box],
        options: const RequestOptions(
          headers: {'TypeSafe-Danger-Zone-Images': 'TRUE'},
        ),
      );
      expect(
        scripted.requests[0].headers,
        allOf(
          containsPair('typesafe-danger-zone-images', 'true'),
          containsPair('typesafe-danger-zone-long-context', 'true'),
        ),
      );
      expect(
        scripted.requests[1].headers['typesafe-danger-zone-images'],
        'TRUE',
      );
    });

    test('the raw header turns images on only when it says true', () async {
      final scripted = ScriptedClient([const Step(200, body: _boxBody)]);
      await clientFor(
        scripted,
        defaultHeaders: const {'TypeSafe-Danger-Zone-Images': 'TRUE'},
      ).systemOne(state: {'photo': photo}, questions: [box]);
      expect(
        scripted.requests.single.headers['typesafe-danger-zone-images'],
        'TRUE',
      );
      const off = {'TypeSafe-Danger-Zone-Images': 'false'};
      await expectLater(
        clientFor(
          scripted,
          defaultHeaders: off,
        ).systemOne(state: {'photo': photo}, questions: [box]),
        throwsArgumentError,
      );
      await expectLater(
        clientFor(scripted).systemOne(
          state: {'photo': photo},
          questions: [box],
          options: const RequestOptions(headers: off),
        ),
        throwsArgumentError,
      );
      expect(scripted.requests, hasLength(1));
    });

    test("a call's zones are added to its own headers", () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await clientFor(scripted).systemOne(
        state: 'text',
        questions: [seen],
        options: const RequestOptions(
          headers: {'X-Trace': 'abc'},
          dangerZone: {DangerZone.longContext},
        ),
      );
      expect(
        scripted.requests.single.headers,
        allOf(
          containsPair('x-trace', 'abc'),
          containsPair('typesafe-danger-zone-long-context', 'true'),
        ),
      );
    });

    test('a client and call with no zones send no zone header', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      final client = clientFor(scripted);
      await client.systemOne(state: 'text', questions: [seen]);
      await client.systemOne(
        state: 'text',
        questions: [seen],
        options: const RequestOptions(headers: {'X-Trace': 'abc'}),
      );
      for (final request in scripted.requests) {
        expect(
          request.headers.keys.where((k) => k.startsWith('typesafe-danger')),
          isEmpty,
        );
      }
    });

    test('long context alone adds only its header to a JSON call', () async {
      final scripted = ScriptedClient([const Step(200, body: successBody)]);
      await clientFor(scripted).systemOne(
        state: 'long text',
        questions: [seen],
        options: const RequestOptions(dangerZone: {DangerZone.longContext}),
      );
      final headers = scripted.requests.single.headers;
      expect(headers['typesafe-danger-zone-long-context'], 'true');
      expect(headers.containsKey('typesafe-danger-zone-images'), isFalse);
      expect(headers['content-type'], startsWith('application/json'));
    });

    test('a retry resends the same multipart bytes and type', () async {
      final scripted = ScriptedClient([
        const Step(503),
        const Step(200, body: _boxBody),
      ]);
      await clientFor(scripted).systemOne(
        state: {'photo': photo},
        questions: [box],
        options: const RequestOptions(dangerZone: {DangerZone.images}),
      );
      final [first, second] = scripted.requests;
      expect(second.bodyBytes, first.bodyBytes);
      expect(second.headers['content-type'], first.headers['content-type']);
      expect(second.headers['x-typesafe-retry-count'], '1');
      expect(second.headers['typesafe-danger-zone-images'], 'true');
    });

    test('ClientConfig lists danger zones only when there are some', () {
      ClientConfig config(Set<DangerZone> zones) => ClientConfig(
        apiKey: 'k',
        baseUrl: Uri.parse('https://a.test'),
        defaultModel: 'm',
        dangerZone: zones,
      );
      final plain = ClientConfig(
        apiKey: 'k',
        baseUrl: Uri.parse('https://a.test'),
        defaultModel: 'm',
      );
      expect(plain.dangerZone, isEmpty);
      expect(config(const {}).toString(), isNot(contains('dangerZone')));
      expect(
        config(const {DangerZone.images}).toString(),
        endsWith('http2: false, dangerZone: images)'),
      );
      expect(
        () => config({DangerZone.images}).dangerZone.add(DangerZone.images),
        throwsUnsupportedError,
      );
    });
  });
}

/// A state whose `toJson` builds a question around [image], so one encode
/// runs inside another, and returns plain text: the outer encode never meets
/// [image] itself, only through the inner recording.
final class _EncodesAQuestion implements JsonEncodable {
  _EncodesAQuestion(this.image);

  final Image image;

  @override
  Object? toJson() {
    Noul(id: 'inner', instructions: TextWithImages(['see ', image]));
    return 'see ${image.reference}';
  }
}

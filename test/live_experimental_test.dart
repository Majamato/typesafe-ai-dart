@Tags(['live'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/src/env/env.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

/// The square [squarePng] draws, as fractions of the image.
const ({double left, double top, double right, double bottom}) _square = (
  left: 0.25,
  top: 0.5,
  right: 0.5,
  bottom: 0.75,
);

void main() {
  final apiKey = readEnv(ClientConfig.apiKeyVariable);

  group(
    'live experimental API',
    () {
      late TypeSafeClient client;

      setUpAll(
        () => client = TypeSafeClient(
          defaultModel: 'jev-preview',
          dangerZone: {DangerZone.images},
        ),
      );
      tearDownAll(() => client.close());

      final photo = Image(squarePng(), reference: 'photo-$pid');

      test(
        'a Box finds the red square, and a Noul sees it',
        () async {
          final red = Noul(
            id: 'red',
            instructions: 'Is there a red square in `photo`?',
          );
          final square = Box(
            id: 'square',
            instructions: 'the red square in `photo`',
          );

          final response = await client.systemOne(
            state: {'photo': photo},
            questions: [red, square],
          );

          expect(response.model, startsWith('jev-1.14'));
          expect(response.answer(red).noul, greaterThan(0.5));
          final box = response.answer(square);
          for (final edge in [box.top, box.bottom, box.left, box.right]) {
            expect(edge, inInclusiveRange(0, 1));
          }
          expect(box.left, lessThan(box.right));
          expect(box.top, lessThan(box.bottom));
          // Loose on purpose: the feature is experimental. The box only has
          // to overlap the square.
          expect(box.left, lessThan(_square.right));
          expect(box.right, greaterThan(_square.left));
          expect(box.top, lessThan(_square.bottom));
          expect(box.bottom, greaterThan(_square.top));
          expect(box.confidence, inInclusiveRange(0, 1));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test(
        'an image inside instructions reaches the model',
        () async {
          final same = Noul(
            id: 'same',
            instructions: TextWithImages([
              'Is `photo` the same picture as this one: ',
              photo,
              '?',
            ]),
          );

          final response = await client.systemOne(
            state: {'photo': photo},
            questions: [same],
          );

          expect(response.answer(same).noul, inInclusiveRange(0, 1));
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );

      test('long context is accepted on a plain JSON call', () async {
        final polite = Noul(id: 'polite', instructions: 'Is `text` polite?');

        final response = await client.systemOne(
          state: {'text': 'Thank you so much for your help!'},
          questions: [polite],
          model: 'jev-latest',
          options: const RequestOptions(dangerZone: {DangerZone.longContext}),
        );

        expect(response.answer(polite).noul, greaterThan(0.5));
      });
    },
    skip: apiKey == null ? 'set TYPESAFE_API_KEY to run live tests' : false,
  );
}

/// A 400 × 400 white PNG with a red square over [_square], encoded here so
/// the test needs no image file or package.
Uint8List squarePng() {
  const size = 400;
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0); // no filter
    for (var x = 0; x < size; x++) {
      final inside =
          x >= _square.left * size &&
          x < _square.right * size &&
          y >= _square.top * size &&
          y < _square.bottom * size;
      raw.add(inside ? const [220, 30, 30] : const [255, 255, 255]);
    }
  }
  final header = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 2); // truecolour RGB
  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(_chunk('IDAT', zlib.encode(raw.takeBytes())))
        ..add(_chunk('IEND', const [])))
      .takeBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(typed));
  return Uint8List.fromList([
    ...length.buffer.asUint8List(),
    ...typed,
    ...crc.buffer.asUint8List(),
  ]);
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

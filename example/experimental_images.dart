// ignore_for_file: avoid_print, this is an example.
// Experimental: needs a 0.2.0 prerelease and Jev 1.14. Run with:
// TYPESAFE_API_KEY=... dart run example/experimental_images.dart photo.jpg
// The photo must be a PNG or JPEG file, 280 to 1568 pixels per side.
import 'dart:io';

import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

// A Box always answers with a box, even when the target isn't there, so a
// Noul alongside it says whether to trust the box at all.
final mugVisible = Noul(
  id: 'mugVisible',
  instructions: 'Is there a coffee mug in `photo`?',
);
final mug = Box(id: 'mug', instructions: 'the coffee mug in `photo`');

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('Pass the path of a PNG or JPEG photo.');
    exitCode = 64;
    return;
  }
  final Image photo;
  try {
    photo = await Image.fromFile(args.first);
  } on FileSystemException catch (e) {
    print("Can't read ${args.first}: ${e.osError?.message ?? e.message}");
    exitCode = 66;
    return;
  }

  // Images and Box questions are off unless the client turns them on.
  final client = TypeSafeClient(dangerZone: {DangerZone.images});
  try {
    final response = await client.systemOne(
      state: {'photo': photo},
      questions: [mugVisible, mug],
      model: 'jev-preview', // Box questions need Jev 1.14.
    );
    if (response.answer(mugVisible).noul < 0.5) {
      print('No mug in the photo.');
      return;
    }
    // Each edge is a fraction of the image's size, from its top-left corner.
    final box = response.answer(mug);
    print(
      'Mug at left ${box.left.toStringAsFixed(2)}, '
      'top ${box.top.toStringAsFixed(2)}, '
      'width ${box.width.toStringAsFixed(2)}, '
      'height ${box.height.toStringAsFixed(2)} '
      '(confidence ${box.confidence.toStringAsFixed(2)}).',
    );
  } on TypeSafeException catch (e) {
    print('Call failed: $e');
    exitCode = 1;
  } finally {
    client.close();
  }
}

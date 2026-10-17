/// Experimental TypeSafe features from Jev 1.14's "Danger Zone": images in
/// a request, Box questions, and the switches that turn them on.
///
/// TypeSafe doesn't call these ready for production. The request format,
/// the answers and the limits can change between releases, and so can this
/// library, without a breaking version bump. Everything here is marked
/// `@experimental`; Dart 3.11 and later report each use as an
/// `experimental_member_use` warning, which you can turn off in
/// `analysis_options.yaml`.
///
/// ```dart
/// import 'package:typesafe_ai_dart/experimental.dart';
/// import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';
/// ```
library;

export 'src/answers/answer.dart' show BoxAnswer;
export 'src/assets/image.dart' show Image, ImageFormat, TextWithImages;
export 'src/client/danger_zone.dart' show DangerZone;
export 'src/questions/question.dart' show Box;

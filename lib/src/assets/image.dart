/// Images a request carries as assets: the experimental `Image` type, text
/// that embeds images, and the bookkeeping that finds them while a request
/// encodes.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/json/json_encodable.dart';

/// The image file formats the API accepts.
@experimental
enum ImageFormat {
  png('image/png'),
  jpeg('image/jpeg')
  ;

  const ImageFormat(this.mimeType);

  /// Content type of a file in this format, as sent in a multipart part.
  final String mimeType;
}

/// A PNG or JPEG image to put wherever a request takes text: in `state`, in a
/// question's `instructions`, or in its criteria. The request uploads it once
/// as a file part and the model sees the image where its [reference] is.
///
/// Experimental: the API only reads images when the request carries the
/// `TypeSafe-Danger-Zone-Images: true` header (`DangerZone.images`), and
/// TypeSafe may change the format, the answers and the limits.
///
/// The bytes are not copied, so don't change them after building the image.
/// The API checks the size and pixel limits; this class only checks the
/// format, so a limit TypeSafe changes is never enforced here.
@experimental
@immutable
final class Image implements JsonEncodable {
  Image(this.bytes, {String? reference})
    : format = _detectFormat(bytes),
      reference = reference == null
          ? 'image_${randomHex()}'
          : _checkReference(reference);

  /// Reads the PNG or JPEG file at [path].
  static Future<Image> fromFile(String path, {String? reference}) async =>
      Image(await File(path).readAsBytes(), reference: reference);

  /// The file's bytes, sent as they are.
  final Uint8List bytes;

  /// The file format, detected from the bytes.
  final ImageFormat format;

  /// The text that stands for this image in the request. References are
  /// matched as plain text, so a custom one must not occur in your text.
  final String reference;

  /// Returns [reference], and records this image as one the request being
  /// encoded must upload.
  @override
  String toJson() {
    if (_collecting) {
      (_found ??= <Image>[]).add(this);
    }
    return reference;
  }

  /// Not the [reference]: interpolating an image into a string would lose
  /// it. Use `TextWithImages` to put an image inside a sentence.
  @override
  String toString() =>
      'Image(${format.name}, ${bytes.length} bytes, $reference)';

  static ImageFormat _detectFormat(Uint8List bytes) {
    if (_startsWith(bytes, _pngSignature)) {
      return ImageFormat.png;
    }
    if (_startsWith(bytes, _jpegSignature)) {
      return ImageFormat.jpeg;
    }
    throw ArgumentError('must be the bytes of a PNG or JPEG file', 'bytes');
  }

  static bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) {
      return false;
    }
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  static String _checkReference(String reference) {
    if (reference.trim().isEmpty) {
      throw ArgumentError.value(
        reference,
        'reference',
        'must not be empty or only whitespace',
      );
    }
    return reference;
  }

  static const _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  static const _jpegSignature = [0xFF, 0xD8, 0xFF];
}

/// Text with images inside it, such as "Is this the dog in `photo`?" followed
/// by a picture. Encodes as one string, each image replaced by its reference.
///
/// Experimental, like [Image].
@experimental
@immutable
final class TextWithImages implements JsonEncodable {
  /// [parts] are `String`s and [Image]s, joined in order with nothing added
  /// between them.
  TextWithImages(List<Object> parts) : parts = List.unmodifiable(parts) {
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part is! String && part is! Image) {
        throw ArgumentError(
          'must hold only Strings and Images, not ${part.runtimeType}',
          'parts[$i]',
        );
      }
    }
  }

  /// The strings and images, in order. Unmodifiable.
  final List<Object> parts;

  @override
  String toJson() {
    final text = StringBuffer();
    for (final part in parts) {
      text.write(part is Image ? part.toJson() : part);
    }
    return text.toString();
  }

  @override
  String toString() => 'TextWithImages(${parts.length} parts)';
}

/// Whether images that encode themselves are being recorded.
bool _collecting = false;

/// The images recorded so far, allocated only once one turns up.
List<Image>? _found;

/// Starts recording every [Image] encoded until [stopCollectingImages].
/// Encoding is synchronous, so nothing else runs in between. Returns the
/// enclosing recording's list, or `null` when there is none; pass it on to
/// [stopCollectingImages]. Not exported from the package.
List<Image>? startCollectingImages() {
  final outer = _collecting ? (_found ??= <Image>[]) : null;
  _collecting = true;
  _found = null;
  return outer;
}

/// Stops the recording [startCollectingImages] began and returns the images
/// it saw, or `null` for none. Call it in a `finally`. A nested recording's
/// images also count toward the enclosing one.
List<Image>? stopCollectingImages(List<Image>? outer) {
  final found = _found;
  if (outer == null) {
    _collecting = false;
    _found = null;
  } else {
    if (found != null) {
      outer.addAll(found);
    }
    _found = outer;
  }
  return found;
}

/// 128 random bits as 32 lower-case hex digits, for image references and
/// multipart boundaries. Not exported from the package.
String randomHex() {
  final hex = StringBuffer();
  for (var i = 0; i < 4; i++) {
    hex.write(_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0'));
  }
  return hex.toString();
}

final Random _random = Random.secure();

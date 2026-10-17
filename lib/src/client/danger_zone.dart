import 'package:meta/meta.dart';
import 'package:typesafe_ai_dart/src/http/http_headers.dart';

/// Experimental API features that TypeSafe keeps off unless a request asks
/// for them with a `TypeSafe-Danger-Zone-*` header. TypeSafe doesn't vouch
/// for them in production, and may change or drop them between releases.
@experimental
enum DangerZone {
  /// Images in a request and `Box` questions, sent as
  /// `TypeSafe-Danger-Zone-Images: true`.
  images(dangerZoneImagesHeader),

  /// A 262k-token context per request and per question instead of the
  /// default limits, sent as `TypeSafe-Danger-Zone-Long-Context: true`.
  /// Slower and less accurate, so turn it on only where it's needed.
  longContext(dangerZoneLongContextHeader);

  const DangerZone(this.header);

  /// The lower-case name of the header that turns this feature on.
  final String header;
}

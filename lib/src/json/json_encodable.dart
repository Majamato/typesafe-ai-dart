/// A helper object that knows how to render itself as JSON.
///
/// Implement this to pass typed helpers where the API accepts free-form JSON.
// ignore: one_member_abstracts, this is a structural interface, not a callback
abstract interface class JsonEncodable {
  /// Returns this object in the API's JSON shape.
  Object? toJson();
}

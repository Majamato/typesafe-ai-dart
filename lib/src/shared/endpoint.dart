/// An API endpoint, as the method and path pair the client may call. Pairing
/// them here keeps a method from being sent to the wrong path.
enum Endpoint {
  systemOne('POST', '/v1/systemone'),
  listModels('GET', '/v1/models')
  ;

  const Endpoint(this.method, this.path);

  /// HTTP method this endpoint is called with.
  final String method;

  /// Path appended to the client's base URL.
  final String path;

  /// Renders as `POST /v1/systemone`, the form used in error messages.
  @override
  String toString() => '$method $path';
}

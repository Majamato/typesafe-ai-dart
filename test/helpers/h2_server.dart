/// A scripted TLS HTTP/2 server on loopback, for driving the SDK's default
/// `Http2Client` end to end and recording what reached the wire.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/transport.dart';

import 'certs.dart';

/// How the server negotiates TLS on a new connection.
enum H2Tls {
  /// The trusted `localhost` certificate, offering ALPN `h2`.
  h2,

  /// The trusted certificate, but ALPN offers only `http/1.1`.
  withoutH2,

  /// A self-signed certificate the client does not trust.
  untrusted,
}

/// Decides what the server does with one request once its headers arrive.
typedef H2Handler = FutureOr<void> Function(H2Exchange exchange);

/// The question id [answerBody] answers, as a `noul`.
const h2QuestionId = 'q';

/// A successful System One body answering [h2QuestionId], with [model] as the
/// model name so a test can tell responses apart.
String answerBody({String model = 'jev-test'}) => jsonEncode({
  'model': model,
  'answers': {
    h2QuestionId: {'type': 'noul', 'noul': 0.5},
  },
  'usage': {'input_tokens': 1, 'output_tokens': 0},
});

/// Answers after [delay] with [answerBody], echoing a string request `state`
/// as the model, so each caller can check it got its own response.
H2Handler answer({Duration delay = Duration.zero}) => (exchange) async {
  final body = await exchange.body;
  if (delay > Duration.zero) {
    await Future<void>.delayed(delay);
  }
  exchange.respond(200, body: answerBody(model: stateOf(body) ?? 'jev-test'));
};

/// The `state` of a System One request body when it is a string.
String? stateOf(List<int> body) {
  try {
    final json = jsonDecode(utf8.decode(body));
    return json is Map<String, Object?> && json['state'] is String
        ? json['state']! as String
        : null;
  } on FormatException {
    return null;
  }
}

/// A loopback HTTP/2 server whose [handler] scripts each request. Every TCP
/// connection is accepted in plain text and upgraded to TLS by hand, so a
/// test can hold a handshake back with [stallHandshakes].
final class H2TestServer {
  H2TestServer._(
    this._socket, {
    required this.handler,
    required this.tls,
    required this.concurrentStreamLimit,
    required this.ignoreClientClose,
  });

  /// Binds to an ephemeral loopback port.
  ///
  /// [concurrentStreamLimit] is advertised to clients (`null` for none).
  /// With [ignoreClientClose], the server never closes a connection itself.
  static Future<H2TestServer> start({
    H2Handler? handler,
    H2Tls tls = H2Tls.h2,
    int? concurrentStreamLimit,
    bool ignoreClientClose = false,
  }) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = H2TestServer._(
      socket,
      handler: handler ?? answer(),
      tls: tls,
      concurrentStreamLimit: concurrentStreamLimit,
      ignoreClientClose: ignoreClientClose,
    );
    socket.listen(server._accept);
    return server;
  }

  final ServerSocket _socket;

  /// Scripts every request received from now on.
  H2Handler handler;

  /// How new connections negotiate TLS.
  final H2Tls tls;

  /// The stream limit advertised in the server's SETTINGS, or `null`.
  final int? concurrentStreamLimit;

  /// Whether the server swallows its own side's close, as a peer that
  /// ignores GOAWAY would.
  final bool ignoreClientClose;

  /// Whether newly accepted sockets are held before the TLS handshake.
  bool stallHandshakes = false;

  /// Connections that completed TLS, in accept order.
  final List<H2Connection> connections = [];

  /// Errors from TLS handshakes that failed on the server side.
  final List<Object> handshakeErrors = [];

  /// Errors a [handler] threw; each one's stream was reset.
  final List<Object> handlerErrors = [];

  final List<Socket> _stalled = [];

  /// Number of TCP connections accepted, stalled ones included.
  int accepted = 0;

  /// The port the server listens on.
  int get port => _socket.port;

  /// The URL to give the SDK; `localhost` matches the certificate's SAN.
  String get baseUrl => 'https://localhost:$port';

  /// Sockets currently held before their handshake.
  int get stalledCount => _stalled.length;

  /// Every request received, across connections, in arrival order.
  List<H2Exchange> get exchanges => [
    for (final connection in connections) ...connection.exchanges,
  ];

  /// Streams the server has neither finished nor seen reset.
  int get openStreams => connections.fold(0, (n, c) => n + c.openStreams);

  /// Handshakes the held sockets now, as if the stall cleared.
  void releaseStalled() {
    final held = List.of(_stalled);
    _stalled.clear();
    for (final socket in held) {
      unawaited(_upgrade(socket));
    }
  }

  /// Destroys the held sockets, failing their clients' handshakes.
  void dropStalled() {
    for (final socket in _stalled) {
      socket.destroy();
    }
    _stalled.clear();
  }

  /// Stops listening and destroys every connection, held ones included.
  Future<void> close() async {
    dropStalled();
    await _socket.close();
    for (final connection in connections) {
      connection.destroy();
    }
  }

  void _accept(Socket socket) {
    accepted++;
    if (stallHandshakes) {
      _stalled.add(socket);
    } else {
      unawaited(_upgrade(socket));
    }
  }

  Future<void> _upgrade(Socket socket) async {
    final SecureSocket secure;
    try {
      final alpn = tls == H2Tls.withoutH2 ? ['http/1.1'] : ['h2'];
      secure = await SecureSocket.secureServer(
        socket,
        serverContext(trusted: tls != H2Tls.untrusted, alpn: alpn),
        supportedProtocols: alpn,
      );
    } on Object catch (error) {
      handshakeErrors.add(error);
      socket.destroy();
      return;
    }
    final connection = H2Connection._(this, connections.length, secure);
    connections.add(connection);
    connection._serve();
  }
}

/// One TLS connection the server accepted, and the streams it carried.
final class H2Connection {
  H2Connection._(this._server, this.index, this.socket);

  final H2TestServer _server;

  /// Position in [H2TestServer.connections].
  final int index;

  /// The TLS socket, for [destroy] or inspection.
  final SecureSocket socket;

  /// Requests received on this connection, in arrival order.
  final List<H2Exchange> exchanges = [];

  /// Most streams this connection had open at once.
  int peakOpenStreams = 0;

  final Completer<void> _done = Completer<void>();
  ServerTransportConnection? _transport;

  /// The ALPN protocol negotiated, `h2` unless the server withheld it.
  String? get protocol => socket.selectedProtocol;

  /// Completes once the connection is gone, from either side.
  Future<void> get done => _done.future;

  /// Whether the connection is gone.
  bool get isClosed => _done.isCompleted;

  /// Streams on this connection neither finished nor reset.
  int get openStreams => exchanges.where((e) => e.isOpen).length;

  /// Sends GOAWAY; the connection closes once its open streams finish.
  Future<void> goAway() async {
    try {
      await _transport?.finish();
    } on Object {
      // Already gone.
    }
  }

  /// Kills the TCP connection without any HTTP/2 goodbye.
  void destroy() => socket.destroy();

  void _serve() {
    if (protocol != 'h2') {
      socket.listen(null, onDone: _closed, onError: (Object _) => _closed());
      return;
    }
    final outgoing = _server.ignoreClientClose ? _NoCloseSink(socket) : socket;
    final transport = ServerTransportConnection.viaStreams(
      socket,
      outgoing,
      settings: ServerSettings(
        concurrentStreamLimit: _server.concurrentStreamLimit,
      ),
    );
    _transport = transport;
    transport.incomingStreams.listen(
      _onStream,
      onError: (Object _) => _closed(),
      onDone: _closed,
    );
  }

  void _onStream(ServerTransportStream stream) {
    final exchange = H2Exchange._(this, stream);
    exchanges.add(exchange);
    final open = openStreams;
    if (open > peakOpenStreams) {
      peakOpenStreams = open;
    }
    exchange._start(_server);
  }

  void _closed() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}

/// One request/response exchange on a stream, as the server saw it.
final class H2Exchange {
  H2Exchange._(this.connection, this.stream) {
    stream.onTerminated = (code) {
      terminationCode = code;
      if (!_terminated.isCompleted) {
        _terminated.complete(code);
      }
    };
    unawaited(stream.outgoingMessages.done.catchError((Object _) {}));
  }

  /// The connection that carried this stream.
  final H2Connection connection;

  /// The underlying HTTP/2 stream.
  final ServerTransportStream stream;

  /// Request headers, pseudo-headers such as `:path` included.
  final Map<String, String> headers = {};

  /// RST_STREAM code the client sent, e.g. 8 (CANCEL), or `null`.
  int? terminationCode;

  /// Whether the server reset this stream itself.
  bool resetByServer = false;

  final BytesBuilder _body = BytesBuilder();
  final Completer<Uint8List> _bodyDone = Completer<Uint8List>();
  final Completer<int?> _terminated = Completer<int?>();
  bool _ended = false;

  /// The request body once the client ends its side; partial if it resets.
  Future<Uint8List> get body => _bodyDone.future;

  /// Completes with the client's RST_STREAM code; never if it sends none.
  Future<int?> get terminated => _terminated.future;

  /// The request's `:method`.
  String? get method => headers[':method'];

  /// The request's `:path`.
  String? get path => headers[':path'];

  /// Whether the server still owes a response and nobody reset the stream.
  bool get isOpen =>
      !_ended &&
      !resetByServer &&
      terminationCode == null &&
      !connection.isClosed;

  /// Sends a complete response.
  void respond(
    int status, {
    String body = '',
    Map<String, String> headers = const {},
  }) {
    final bytes = utf8.encode(body);
    sendHeaders(status, headers: headers, endStream: bytes.isEmpty);
    if (bytes.isNotEmpty) {
      sendData(bytes, endStream: true);
    }
  }

  /// Sends the response headers, leaving the body open unless [endStream].
  void sendHeaders(
    int status, {
    Map<String, String> headers = const {},
    bool endStream = false,
  }) {
    _guard(
      () => stream.sendHeaders([
        Header.ascii(':status', '$status'),
        for (final MapEntry(:key, :value) in headers.entries)
          Header.ascii(key, value),
      ], endStream: endStream),
    );
    if (endStream) {
      _ended = true;
    }
  }

  /// Sends one DATA frame, ending the response if [endStream].
  void sendData(List<int> bytes, {bool endStream = false}) {
    _guard(() => stream.sendData(bytes, endStream: endStream));
    if (endStream) {
      _ended = true;
    }
  }

  /// Resets the stream from the server side (RST_STREAM CANCEL).
  void reset() {
    resetByServer = true;
    _guard(stream.terminate);
  }

  void _start(H2TestServer server) {
    var dispatched = false;
    void completeBody() {
      if (!_bodyDone.isCompleted) {
        _bodyDone.complete(_body.takeBytes());
      }
    }

    stream.incomingMessages.listen(
      (message) {
        if (message is HeadersStreamMessage) {
          for (final header in message.headers) {
            headers[ascii.decode(header.name)] = utf8.decode(
              header.value,
              allowMalformed: true,
            );
          }
          if (!dispatched) {
            dispatched = true;
            unawaited(_dispatch(server));
          }
        } else if (message is DataStreamMessage) {
          _body.add(message.bytes);
        }
      },
      onError: (Object _) => completeBody(),
      onDone: completeBody,
    );
  }

  Future<void> _dispatch(H2TestServer server) async {
    try {
      await server.handler(this);
    } on Object catch (error) {
      server.handlerErrors.add(error);
      reset();
    }
  }

  static void _guard(void Function() write) {
    try {
      write();
    } on Object {
      // The stream or connection is already gone.
    }
  }
}

/// Forwards writes to a socket but never closes it, like a peer that ignores
/// GOAWAY and leaves its side of the connection open.
final class _NoCloseSink implements StreamSink<List<int>> {
  _NoCloseSink(this._socket);

  final Socket _socket;

  @override
  void add(List<int> data) {
    try {
      _socket.add(data);
    } on Object {
      // Socket already destroyed.
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() => Future<void>.value();

  @override
  Future<void> get done => Completer<void>().future;
}

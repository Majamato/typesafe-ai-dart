/// Scripted HTTP/1.1 servers on the loopback interface, for tests that need
/// real sockets: a well-behaved [H1Server] and a byte-level [RawH1Server].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Shared clock that stamps every request the servers here receive.
final Stopwatch _serverClock = Stopwatch()..start();

/// One request as [H1Server] received it; header names are lower-case.
final class ReceivedRequest {
  ReceivedRequest._({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
    required this.remotePort,
    required this.arrivedAt,
  });

  final String method;

  /// The URL path, without the query.
  final String path;

  /// Every value per header name, so a duplicated header shows up twice.
  final Map<String, List<String>> headers;

  final Uint8List body;

  /// The client's port, identifying which connection carried the request.
  final int remotePort;

  /// When the whole request had been read, on a clock shared by all servers.
  final Duration arrivedAt;

  /// Returns the single value of header [name], or `null` when absent.
  String? header(String name) => headers[name]?.single;

  /// The body decoded as UTF-8 JSON.
  Object? get json => jsonDecode(utf8.decode(body));
}

/// Answers [request] through [response]; the server closes the response once
/// this completes, so a handler that never completes never answers.
typedef H1Handler =
    FutureOr<void> Function(ReceivedRequest request, HttpResponse response);

/// A real `dart:io` [HttpServer] on 127.0.0.1 that records every request and
/// answers it with a scripted [H1Handler].
final class H1Server {
  H1Server._(this._server, this._handler) {
    _server.listen(_serve);
  }

  /// Binds to a free loopback port and starts serving with [handler].
  static Future<H1Server> start(H1Handler handler) async => H1Server._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    handler,
  );

  final HttpServer _server;
  final H1Handler _handler;

  /// Every request received so far, in arrival order.
  final List<ReceivedRequest> requests = [];

  int get port => _server.port;

  /// Base URL to hand to a client, e.g. `http://127.0.0.1:4242`.
  String get url => 'http://127.0.0.1:$port';

  /// Connections the server holds open right now, idle ones included.
  int get openConnections => _server.connectionsInfo().total;

  /// The distinct client ports seen, one per connection used.
  Set<int> get remotePorts => {for (final r in requests) r.remotePort};

  /// Stops listening and drops every open connection.
  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    try {
      final body = await request.fold(BytesBuilder(copy: false), (b, chunk) {
        b.add(chunk);
        return b;
      });
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) => headers[name] = [...values]);
      final received = ReceivedRequest._(
        method: request.method,
        path: request.uri.path,
        headers: headers,
        body: body.takeBytes(),
        remotePort: request.connectionInfo?.remotePort ?? -1,
        arrivedAt: _serverClock.elapsed,
      );
      requests.add(received);
      await _handler(received, request.response);
      await request.response.close();
    } on Object {
      // The client went away mid-exchange, which several tests cause on
      // purpose; nothing is left to answer.
    }
  }
}

/// Writes [body] as a JSON response with [status] and extra [headers].
Future<void> respondJson(
  HttpResponse response,
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  headers.forEach(response.headers.set);
  response.add(utf8.encode(body));
}

/// A request read off a raw socket by [RawConnection]; header names are
/// lower-case and a repeated header keeps its last value.
final class RawRequest {
  RawRequest._(this.requestLine, this.headers, this.body);

  /// The first line, such as `POST /v1/systemone HTTP/1.1`.
  final String requestLine;
  final Map<String, String> headers;
  final Uint8List body;
}

/// One socket accepted by [RawH1Server]: reads requests off it and writes
/// whatever bytes a test scripts, well-formed or not.
final class RawConnection {
  RawConnection._(this.socket, this.index) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    socket.listen(
      (chunk) {
        _buffer.add(chunk);
        _dataArrived?.complete();
        _dataArrived = null;
      },
      onDone: _markClosed,
      onError: (Object _) => _markClosed(),
      cancelOnError: true,
    );
  }

  final Socket socket;

  /// Zero-based order in which the server accepted this connection.
  final int index;

  final BytesBuilder _buffer = BytesBuilder();
  Completer<void>? _dataArrived;
  final Completer<void> _closed = Completer<void>();
  bool _destroyedByServer = false;

  /// Completes once the socket is closed from either end.
  Future<void> get closed => _closed.future;

  /// Whether the client closed the socket before the server destroyed it.
  bool closedByClient = false;

  /// Reads the next full request, head and `content-length` body.
  Future<RawRequest> nextRequest() async {
    while (true) {
      final bytes = _buffer.toBytes();
      final end = _headEnd(bytes);
      if (end >= 0) {
        final head = latin1.decode(bytes.sublist(0, end)).split('\r\n');
        final headers = <String, String>{
          for (final line in head.skip(1))
            if (line.contains(':'))
              line.substring(0, line.indexOf(':')).trim().toLowerCase(): line
                  .substring(line.indexOf(':') + 1)
                  .trim(),
        };
        final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
        if (bytes.length >= end + 4 + length) {
          final body = Uint8List.sublistView(bytes, end + 4, end + 4 + length);
          _buffer
            ..clear()
            ..add(bytes.sublist(end + 4 + length));
          return RawRequest._(head.first, headers, Uint8List.fromList(body));
        }
      }
      if (_closed.isCompleted) {
        throw StateError('Socket closed before a full request arrived');
      }
      final arrived = _dataArrived = Completer<void>();
      await Future.any([arrived.future, closed]);
    }
  }

  /// Writes [text] as Latin-1, which keeps every byte a test spells out.
  void write(String text) => socket.add(latin1.encode(text));

  /// Writes a complete response with [status], [body] and a correct
  /// `content-length` unless [contentLength] overrides it.
  void respond(
    int status,
    String body, {
    Map<String, String> headers = const {},
    int? contentLength,
  }) {
    final bytes = utf8.encode(body);
    write(
      'HTTP/1.1 $status X\r\n'
      'content-type: application/json\r\n'
      'content-length: ${contentLength ?? bytes.length}\r\n'
      '${headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}'
      '\r\n',
    );
    socket.add(bytes);
  }

  /// Closes the socket from the server's side without further ado.
  void destroy() {
    _destroyedByServer = true;
    socket.destroy();
  }

  void _markClosed() {
    if (!_closed.isCompleted) {
      closedByClient = !_destroyedByServer;
      _closed.complete();
      _dataArrived?.complete();
    }
  }

  static int _headEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// Drives one accepted [connection]; errors it throws are swallowed, since
/// a scripted misbehaviour often ends with the client hanging up.
typedef RawHandler = Future<void> Function(RawConnection connection);

/// A plain [ServerSocket] on 127.0.0.1 that hands each connection to a
/// [RawHandler], for responses `HttpServer` refuses to produce.
final class RawH1Server {
  RawH1Server._(this._socket, this._handler) {
    _socket.listen((socket) {
      final connection = RawConnection._(socket, connections.length);
      connections.add(connection);
      unawaited(
        Future(() => _handler(connection)).then<void>(
          (_) {},
          onError: (Object _) {},
        ),
      );
    });
  }

  /// Binds to a free loopback port and starts accepting with [handler].
  static Future<RawH1Server> start(RawHandler handler) async => RawH1Server._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    handler,
  );

  final ServerSocket _socket;
  final RawHandler _handler;

  /// Every connection accepted so far, in order.
  final List<RawConnection> connections = [];

  int get port => _socket.port;

  /// Base URL to hand to a client, e.g. `http://127.0.0.1:4242`.
  String get url => 'http://127.0.0.1:$port';

  /// Stops accepting and destroys every connection still open.
  Future<void> close() async {
    await _socket.close();
    for (final connection in connections) {
      connection.destroy();
    }
  }
}

/// Polls [condition] every few milliseconds until it holds, failing with
/// [reason] if it still doesn't after [within].
Future<void> eventually(
  bool Function() condition, {
  Duration within = const Duration(seconds: 2),
  String reason = 'condition never held',
}) async {
  final deadline = _serverClock.elapsed + within;
  while (!condition()) {
    if (_serverClock.elapsed > deadline) {
      throw TimeoutException('$reason (waited $within)');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

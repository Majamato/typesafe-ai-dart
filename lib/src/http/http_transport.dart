import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:typesafe_ai_dart/src/client/cancel_token.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/deadline_scheduler.dart';
import 'package:typesafe_ai_dart/src/response/raw_response.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

/// Performs one HTTP attempt and normalises its failures to a
/// [TypeSafeException]. A status code isn't a failure; nothing here retries.
final class HttpTransport {
  HttpTransport({
    required http.Client client,
    required Uri baseUrl,
    Duration Function()? clock,
  }) : _client = client,
       _deadlines = DeadlineScheduler(clock: clock),
       _uris = List.unmodifiable([
         for (final endpoint in Endpoint.values) _resolve(baseUrl, endpoint),
       ]);

  final http.Client _client;

  /// Times every attempt this transport makes with one shared timer.
  final DeadlineScheduler _deadlines;

  /// One URL per endpoint, indexed by [Endpoint.index].
  final List<Uri> _uris;

  /// Releases the shared deadline timer once in-flight attempts settle; the
  /// injected `http.Client` is left to its owner.
  void close() => _deadlines.close();

  /// Attempt deadlines still armed; 0 once every attempt has settled.
  int get pendingDeadlines => _deadlines.pendingCount;

  /// The URL [endpoint] is sent to: its path appended to the base URL's, so
  /// `https://host/api` + `/v1/models` gives `https://host/api/v1/models`.
  Uri uriFor(Endpoint endpoint) => _uris[endpoint.index];

  /// What one attempt got back, the body still bytes; header names are
  /// lower-case. [timeout] bounds sending and reading the whole body. A
  /// timeout or cancel aborts the request, closing its connection or stream
  /// if the client can.
  Future<RawResponse> send({
    required Endpoint endpoint,
    required Map<String, String> headers,
    required Duration timeout,
    Uint8List? body,
    CancelToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final abort = Completer<void>();
    TypeSafeException? abortReason;

    void fire(TypeSafeException reason) {
      if (!abort.isCompleted) {
        abortReason = reason;
        abort.complete();
      }
    }

    final deadline = _deadlines.schedule(
      timeout,
      () => fire(
        TypeSafeTimeoutException(
          'No response within ${timeout.inMilliseconds} ms',
          timeout: timeout,
        ),
      ),
    );
    final unregister = cancelToken == null
        ? null
        : onCancel(
            cancelToken,
            () => fire(TypeSafeCancelledException(cancelToken.reason)),
          );

    final request = http.AbortableRequest(
      endpoint.method,
      uriFor(endpoint),
      abortTrigger: abort.future,
    )..headers.addAll(headers);
    if (body != null) {
      request.bodyBytes = body;
    }

    Future<http.StreamedResponse>? sent;
    http.StreamedResponse? streamed;
    try {
      sent = _client.send(request);
      // Raced as well, for clients that ignore `abortTrigger`; listening
      // after the client lets its own abort run first.
      final aborted = abort.future.then<Never>((_) => throw abortReason!);
      final response = await Future.any([sent, aborted]);
      streamed = response;
      final bytes = await _readBody(response.stream, abort.future, aborted);
      return RawResponse(
        statusCode: response.statusCode,
        headers: _lowerCaseNames(response.headers),
        bodyBytes: bytes,
      );
    } on Exception catch (e) {
      final reason = abortReason;
      if (reason != null) {
        if (sent != null && streamed == null) {
          unawaited(_discard(sent));
        }
        throw reason;
      }
      if (e is TypeSafeException) {
        rethrow;
      }
      if (e is http.ClientException) {
        throw TypeSafeConnectionException(e.message, cause: e);
      }
      throw TypeSafeConnectionException('Request failed: $e', cause: e);
    } finally {
      deadline.cancel();
      unregister?.call();
    }
  }

  /// Collects [body], cancelling it once [abort] fires so the client can
  /// reset the stream rather than read a reply nobody wants.
  static Future<Uint8List> _readBody(
    Stream<List<int>> body,
    Future<void> abort,
    Future<Never> aborted,
  ) {
    final bytes = BytesBuilder(copy: false);
    final result = Completer<Uint8List>();
    final subscription = body.listen(
      bytes.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!result.isCompleted) {
          result.complete(bytes.takeBytes());
        }
      },
      cancelOnError: true,
    );
    unawaited(
      abort.then((_) {
        if (!result.isCompleted) {
          unawaited(subscription.cancel());
          result.complete(aborted);
        }
      }),
    );
    return result.future;
  }

  /// Cancels the body of a response that arrives after its request was
  /// abandoned, releasing the connection or stream it holds.
  static Future<void> _discard(Future<http.StreamedResponse> sent) => sent.then(
    (response) => response.stream.listen(null).cancel(),
    onError: (Object _) {},
  );

  /// Returns [headers] itself when every name is lower-case already, as
  /// `IOClient` and HTTP/2 deliver them, else a lower-cased copy.
  static Map<String, String> _lowerCaseNames(Map<String, String> headers) {
    for (final name in headers.keys) {
      for (var i = 0; i < name.length; i++) {
        final unit = name.codeUnitAt(i);
        if (unit >= 0x41 && unit <= 0x5A) {
          return {
            for (final MapEntry(:key, :value) in headers.entries)
              key.toLowerCase(): value,
          };
        }
      }
    }
    return headers;
  }

  static Uri _resolve(Uri baseUrl, Endpoint endpoint) {
    var base = baseUrl.path;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return baseUrl.replace(path: '$base${endpoint.path}');
  }
}

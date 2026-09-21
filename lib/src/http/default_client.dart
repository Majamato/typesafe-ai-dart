import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http2/client.dart';

/// The client used when the caller injects none, and how to close it so
/// in-flight requests finish: HTTP/1.1, or pooled HTTP/2 when [http2] is set.
({http.Client client, void Function() close}) defaultHttpClient({
  required bool http2,
}) {
  if (http2) {
    // Opt-in only, because upstream marks Http2Client experimental.
    // ignore: experimental_member_use
    final client = Http2Client();
    return (client: client, close: client.close);
  }
  // IOClient.close() forces its sockets shut; closing the HttpClient itself
  // lets requests already in flight complete.
  final io = HttpClient();
  return (client: IOClient(io), close: io.close);
}

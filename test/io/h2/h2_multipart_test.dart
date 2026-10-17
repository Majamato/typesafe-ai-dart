@Tags(['h2'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/certs.dart';
import '../../helpers/h2_server.dart';
import '../../helpers/multipart.dart';

void main() {
  setUpAll(trustTestCa);

  test('an image crosses an HTTP/2 stream intact', () async {
    final received = <({Map<String, String> headers, Uint8List body})>[];
    final server = await H2TestServer.start(
      handler: (exchange) async {
        final body = await exchange.body;
        received.add((headers: {...exchange.headers}, body: body));
        exchange.respond(200, body: answerBody());
      },
    );
    addTearDown(server.close);
    final client = TypeSafeClient(
      apiKey: 'sk-test',
      baseUrl: server.baseUrl,
      http2: true,
      defaultModel: 'jev-test',
      dangerZone: const {DangerZone.images},
    );
    addTearDown(client.close);
    final photo = Image(fakeJpeg(512 * 1024), reference: 'PHOTO');

    await client.systemOne(
      state: {'photo': photo},
      questions: [Noul(id: h2QuestionId, instructions: 'A dog in `photo`?')],
    );

    final request = received.single;
    expect(request.headers['typesafe-danger-zone-images'], 'true');
    final parts = parseMultipart(
      request.body,
      request.headers['content-type']!,
    );
    expect(parts.map((p) => p.name), ['request', 'image-0']);
    expect(
      (jsonDecode(utf8.decode(parts[0].body)) as Map)['state'],
      {'photo': 'PHOTO'},
    );
    expect(parts[1].headers['content-type'], 'image/jpeg');
    expect(parts[1].body, photo.bytes);
  });
}

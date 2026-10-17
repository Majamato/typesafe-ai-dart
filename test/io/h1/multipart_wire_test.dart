@Tags(['h1'])
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../../helpers/h1_server.dart';
import '../../helpers/mock_transport.dart' show successBody;
import '../../helpers/multipart.dart';
import 'h1_support.dart';

void main() {
  test('a large image crosses a real socket intact, retry included', () async {
    var calls = 0;
    final server = await H1Server.start((request, res) async {
      final ok = ++calls == 2;
      await respondJson(res, ok ? successBody : '{}', status: ok ? 200 : 503);
    });
    addTearDown(server.close);
    final client = h1Client(server.url, retryPolicy: quickRetry);
    // Every byte value, so nothing in the body is mistaken for text.
    final photo = Image(fakePng(3 * 1024 * 1024), reference: 'PHOTO');

    await client.systemOne(
      state: {'photo': photo},
      questions: [billing],
      options: const RequestOptions(dangerZone: {DangerZone.images}),
    );

    expect(server.requests, hasLength(2));
    final [first, second] = server.requests;
    expect(second.body, first.body);
    expect(second.header('content-type'), first.header('content-type'));
    expect(second.header('x-typesafe-retry-count'), '1');
    for (final request in server.requests) {
      expect(request.header('typesafe-danger-zone-images'), 'true');
      expect(request.header('content-length'), '${request.body.length}');
      final parts = parseMultipart(
        request.body,
        request.header('content-type')!,
      );
      expect(parts.map((p) => p.name), ['request', 'image-0']);
      final json = jsonDecode(utf8.decode(parts[0].body)) as Map;
      expect(json['state'], {'photo': 'PHOTO'});
      expect(json['assets'], {
        'PHOTO': {'type': 'image', 'part': 'image-0'},
      });
      expect(parts[1].body, photo.bytes);
    }
  });
}

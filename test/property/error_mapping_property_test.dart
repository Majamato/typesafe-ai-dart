@Tags(['property'])
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/http/http_error_mapper.dart';
import 'package:typesafe_ai_dart/src/http/http_retry_after.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/fuzz.dart';
import '../helpers/gen.dart';
import '../helpers/mock_transport.dart';

/// Retry-After values a hostile or broken server might send.
const retryAfterValues = [
  '0',
  '5',
  '1.5',
  '-1',
  ' 7 ',
  '',
  '0x10',
  'NaN',
  'Infinity',
  '-Infinity',
  '1e400',
  '999999999999999999999999',
  'Wed, 21 Oct 2015 07:28:00 GMT',
  'Fri, 31 Dec 9999 23:59:59 GMT',
  'Mon, 99 Foo 2026 00:00:00 GMT',
  'soon',
];

/// One error response: status, body text and headers.
typedef ErrorReply = ({int status, String body, Map<String, String> headers});

String randomErrorBody(Random random) {
  Object? message() => switch (random.nextInt(6)) {
    0 => randomString(random),
    1 => {'message': randomJson(random)},
    2 => [
      for (var i = random.nextInt(4); i > 0; i--)
        switch (random.nextInt(4)) {
          0 => randomString(random),
          1 => {
            'msg': randomString(random),
            'loc': [randomString(random), random.nextInt(9)],
          },
          2 => {'message': randomJson(random)},
          _ => randomJson(random),
        },
    ],
    3 => null,
    4 => randomJson(random),
    _ => '',
  };
  return switch (random.nextInt(6)) {
    0 => '',
    1 => randomString(random, maxLength: 400),
    2 => '<html><body>${randomString(random)}</body></html>',
    3 => '{"error": ${jsonEncode(randomString(random))}',
    4 => '${randomString(random)}😀' * random.nextInt(80),
    _ => jsonEncode({
      if (random.nextBool()) 'error': message(),
      if (random.nextBool()) 'message': message(),
      if (random.nextBool()) 'detail': message(),
    }),
  };
}

ErrorReply randomReply(Random random) {
  var status = 100 + random.nextInt(900);
  if (status >= 200 && status < 300) {
    status += 200;
  }
  return (
    status: status,
    body: randomErrorBody(random),
    headers: {
      if (random.nextBool())
        'retry-after':
            retryAfterValues[random.nextInt(retryAfterValues.length)],
      if (random.nextBool())
        'retry-after-ms':
            retryAfterValues[random.nextInt(retryAfterValues.length)],
      if (random.nextBool()) 'x-typesafe-request-id': randomString(random),
    },
  );
}

/// The exception class AGENTS.md and `mapErrorResponse` promise per status.
Type expectedType(int status) => switch (status) {
  400 => BadRequestException,
  401 => AuthenticationException,
  403 => PermissionDeniedException,
  404 => NotFoundException,
  422 => UnprocessableEntityException,
  429 => RateLimitException,
  >= 500 && <= 599 => InternalServerException,
  _ => UnknownApiException,
};

/// Whether [text] has no unpaired UTF-16 surrogate.
bool wellFormed(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (i + 1 < text.length) {
        final next = text.codeUnitAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          i++;
          continue;
        }
      }
      return false;
    }
    if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

String describe(ErrorReply r) =>
    'status=${r.status} headers=${r.headers} body=${jsonEncode(r.body)}';

void main() {
  test('mapErrorResponse never throws and picks the right class', () async {
    await forAll(randomReply, describe: describe, (r) {
      final e = mapErrorResponse(
        statusCode: r.status,
        body: r.body,
        headers: r.headers,
        endpoint: Endpoint.systemOne,
      );
      expect(e.runtimeType, expectedType(r.status));
      expect(e.statusCode, r.status);
      expect(e.body, r.body);
      expect(e.requestId, r.headers['x-typesafe-request-id']);
      if (e.errorJson == null && wellFormed(r.body)) {
        expect(wellFormed(e.message), isTrue, reason: 'message: ${e.message}');
      }
      if (e case RateLimitException(:final retryAfter?)) {
        expect(retryAfter, greaterThanOrEqualTo(Duration.zero));
      }
      expect('$e', startsWith('${expectedType(r.status)}: HTTP ${r.status}'));
    }, runs: fuzzRuns(1000));
  });

  test(
    'a call against any error reply fails with a TypeSafeException',
    () async {
      await forAll(randomReply, describe: describe, (r) async {
        final client = TypeSafeClient(
          apiKey: 'sk-test',
          baseUrl: 'https://api.test',
          retryPolicy: fastRetry.copyWith(
            maxRetries: 1,
            maxRetryAfter: Duration.zero,
          ),
          httpClient: MockClient(
            (request) async => http.Response.bytes(
              utf8.encode(r.body),
              r.status,
              headers: r.headers,
            ),
          ),
        );
        Object? error;
        try {
          await client.systemOne(
            state: 's',
            questions: [Noul(id: 'n', instructions: 'x')],
          );
        } on Object catch (e) {
          error = e;
        }
        expect(error, isA<TypeSafeException>());
      });
    },
  );

  group('S1: a non-finite Retry-After is ignored, not a crash', () {
    for (final value in ['NaN', 'Infinity', '-Infinity', '1e400']) {
      for (final header in ['retry-after', 'retry-after-ms']) {
        test('$header: $value', () {
          expect(parseRetryAfter({header: value}), isNull);
        });
      }
    }
  });

  group('D8: messages survive hostile error bodies', () {
    test('the 200-character cut never splits a surrogate pair', () {
      for (var pad = 195; pad <= 201; pad++) {
        final body = '${'a' * pad}${'😀' * 10}';
        final e = mapErrorResponse(
          statusCode: 418,
          body: body,
          headers: const {},
          endpoint: Endpoint.systemOne,
        );
        expect(wellFormed(e.message), isTrue, reason: 'pad $pad');
      }
    });

    test('a deeply nested validation loc does not overflow the stack', () {
      const depth = 100000;
      final body =
          '{"detail":[{"msg":"bad","loc":${'[' * depth}${']' * depth}}]}';
      expect(
        () => mapErrorResponse(
          statusCode: 422,
          body: body,
          headers: const {},
          endpoint: Endpoint.systemOne,
        ),
        returnsNormally,
      );
    });
  });
}

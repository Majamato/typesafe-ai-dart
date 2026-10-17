import 'package:test/test.dart';
import 'package:typesafe_ai_dart/src/exceptions/exceptions.dart';
import 'package:typesafe_ai_dart/src/http/http_error_mapper.dart';
import 'package:typesafe_ai_dart/src/shared/endpoint.dart';

TypeSafeApiException map(
  int status, {
  String body = '',
  Map<String, String> headers = const {},
}) => mapErrorResponse(
  statusCode: status,
  body: body,
  headers: headers,
  endpoint: Endpoint.systemOne,
);

void main() {
  group('mapErrorResponse', () {
    test('maps every documented status to its class', () {
      expect(map(400), isA<BadRequestException>());
      expect(map(401), isA<AuthenticationException>());
      expect(map(403), isA<PermissionDeniedException>());
      expect(map(404), isA<NotFoundException>());
      expect(map(422), isA<UnprocessableEntityException>());
      expect(map(429), isA<RateLimitException>());
      expect(map(500), isA<InternalServerException>());
      expect(map(529), isA<InternalServerException>());
      expect(map(418), isA<UnknownApiException>());
    });

    test('extracts messages in the official order', () {
      expect(map(400, body: '{"error":"bad"}').message, 'bad');
      expect(map(400, body: '{"error":{"message":"bad"}}').message, 'bad');
      expect(map(400, body: '{"message":"bad"}').message, 'bad');
      expect(map(400, body: '{"detail":"bad"}').message, 'bad');
      expect(
        map(
          422,
          body:
              '{"detail":[{"loc":["body","state"],"msg":"required"},'
              '{"msg":"other"}]}',
        ).message,
        'body.state: required; other',
      );
    });

    test('falls back to documented defaults and plain text', () {
      expect(map(401).message, contains('API key'));
      expect(map(429).message, contains('rate limit'));
      expect(map(529).message, contains('overloaded'));
      expect(
        map(503, body: 'Service Unavailable').message,
        'Service Unavailable',
      );
      expect(map(503, body: '<html>').message, 'HTTP 503');
      expect(map(503, body: '{not json').message, 'HTTP 503');
    });

    test('names the error_type when the body has no message', () {
      // The API's reply to a request over the model's context length.
      const tooLong = '{"detail":{"error_type":"max_tokens_exceeded"}}';
      expect(map(400, body: tooLong).message, 'max_tokens_exceeded');
      expect(
        map(400, body: '{"error":{"error_type":"x_failed"}}').message,
        'x_failed',
      );
      expect(map(400, body: '{"error_type":"y_failed"}').message, 'y_failed');
      // A message, or the status's own sentence, still wins over the code.
      expect(
        map(
          400,
          body: '{"detail":{"error_type":"api_usage_error","message":"bad"}}',
        ).message,
        'bad',
      );
      expect(
        map(401, body: '{"detail":{"error_type":"auth"}}').message,
        contains('API key'),
      );
      expect(
        map(400, body: '{"detail":{"error_type":""}}').message,
        'HTTP 400',
      );
      expect(map(400, body: '{"detail":{"error_type":7}}').message, 'HTTP 400');
    });

    test('carries body, headers, request id and retry-after', () {
      final e = map(
        429,
        body: '{"error":"slow down"}',
        headers: const {
          'x-typesafe-request-id': 'req_9',
          'retry-after-ms': '1200',
        },
      );
      expect(e, isA<RateLimitException>());
      expect(
        (e as RateLimitException).retryAfter,
        const Duration(milliseconds: 1200),
      );
      expect(e.requestId, 'req_9');
      expect(e.errorJson, {'error': 'slow down'});
      expect(e.body, '{"error":"slow down"}');
      expect(e.endpoint, Endpoint.systemOne);
      expect(
        e.toString(),
        'RateLimitException: HTTP 429 from POST /v1/systemone, request req_9: '
        'slow down',
      );
    });
  });
}

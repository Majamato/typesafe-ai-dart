import 'dart:io';

import 'package:test/test.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

import '../helpers/mock_transport.dart';

/// The README's error-handling `switch`, copied verbatim: it must keep
/// compiling and stay exhaustive over the sealed hierarchy.
// ignore_for_file: unused_local_variable
String readmeSwitch(TypeSafeException e) {
  switch (e) {
    case RateLimitException(:final retryAfter):
    // wait, then retry
    case AuthenticationException():
    // fix the key
    case TypeSafeApiException(:final statusCode, :final requestId):
    // any other HTTP error; quote requestId to support
    case TypeSafeTimeoutException():
    case TypeSafeConnectionException():
    // network
    case TypeSafeCancelledException():
    // you cancelled
    case ResponseValidationException(:final fieldPath):
    // the API returned an unexpected shape
  }
  return switch (e) {
    RateLimitException() => 'rate',
    AuthenticationException() => 'auth',
    TypeSafeApiException() => 'api',
    TypeSafeTimeoutException() => 'timeout',
    TypeSafeConnectionException() => 'connection',
    TypeSafeCancelledException() => 'cancelled',
    ResponseValidationException() => 'validation',
  };
}

/// doc/guide.md's metrics `switch`, copied verbatim, returning what it would
/// print: it must keep compiling and stay exhaustive over the events.
String? readmeRecord(TypeSafeEvent event) {
  String? printed;
  void print(Object line) => printed = '$line';
  switch (event) {
    case CallFinished(:final error?):
      print('call failed: $error');
    case CallFinished(:final elapsed, :final usage):
      print('call took $elapsed, ${usage?.totalTokens ?? 0} tokens');
    case RetryScheduled(:final reason):
      print('retrying after $reason');
    case AttemptStarted() || AttemptResponded() || AttemptFailed():
      break;
  }
  return printed;
}

void main() {
  test('exports exactly the documented symbols', () {
    final source = File('lib/typesafe_ai_dart.dart').readAsStringSync();
    final shown = {
      for (final match in RegExp(r'show\s+([^;]+);').allMatches(source))
        ...match[1]!.split(',').map((name) => name.trim()),
    };
    expect(RegExp('^export ', multiLine: true).allMatches(source).length, 18);
    expect(
      RegExp("^export '[^']+';", multiLine: true).hasMatch(source),
      isFalse,
      reason: 'every export names its symbols with `show`',
    );
    expect(shown, {
      'Answer', 'ChoiceAnswer', 'NoulAnswer', 'ScoreAnswer', //
      'TypedChoiceAnswer', 'CancelToken', 'ClientConfig', 'RequestOptions',
      'RetryPolicy', 'TypeSafeClient', 'AuthenticationException',
      'BadRequestException', 'InternalServerException', 'NotFoundException',
      'PermissionDeniedException', 'RateLimitException',
      'ResponseValidationException', 'TypeSafeApiException',
      'TypeSafeCancelledException', 'TypeSafeConnectionException',
      'TypeSafeException', 'TypeSafeTimeoutException', 'UnknownApiException',
      'UnprocessableEntityException', 'JsonEncodable', 'ModelCard', 'Choice',
      'Noul', 'NoulCriteria', 'Question', 'Score', 'ScoreLevel',
      'TypedChoice', 'SystemOneRequest', 'SystemOneResponse', 'Usage',
      'Endpoint', 'JudgementType', 'packageVersion', 'TypeSafeEvent',
      'AttemptStarted', 'AttemptResponded', 'AttemptFailed', 'RetryScheduled',
      'CallFinished', 'RawResponse',
    });
  });

  test("the README's error switch covers every exception", () {
    const api = (
      statusCode: 400,
      body: '',
      headers: <String, String>{},
      endpoint: Endpoint.systemOne,
    );
    final cases = <TypeSafeException, String>{
      RateLimitException(
        'm',
        statusCode: 429,
        body: api.body,
        headers: api.headers,
        endpoint: api.endpoint,
      ): 'rate',
      AuthenticationException(
        'm',
        statusCode: 401,
        body: api.body,
        headers: api.headers,
        endpoint: api.endpoint,
      ): 'auth',
      UnknownApiException(
        'm',
        statusCode: 418,
        body: api.body,
        headers: api.headers,
        endpoint: api.endpoint,
      ): 'api',
      const TypeSafeTimeoutException('m', timeout: Duration.zero): 'timeout',
      const TypeSafeConnectionException('m'): 'connection',
      const TypeSafeCancelledException(): 'cancelled',
      const ResponseValidationException('m', fieldPath: r'$'): 'validation',
    };
    for (final MapEntry(key: e, value: kind) in cases.entries) {
      expect(readmeSwitch(e), kind);
    }
  });

  test("the guide's metrics switch handles every event", () async {
    final events = <TypeSafeEvent>[];
    final client = clientFor(
      ScriptedClient([
        const Step(503, body: 'down'),
        const Step(200, body: successBody),
      ]),
      onEvent: events.add,
    );
    await client.systemOne(
      state: 'x',
      questions: [Noul(id: 'billing', instructions: 'Billing?')],
    );
    final printed = events.map(readmeRecord).toList();
    expect(printed[2], startsWith('retrying after InternalServerException'));
    expect(printed.last, contains('120 tokens'));
    expect(printed.whereType<String>(), hasLength(2));
  });

  test('packageVersion matches pubspec.yaml and the user-agent', () async {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec)![1];
    expect(packageVersion, version);

    final scripted = ScriptedClient([const Step(200, body: modelsBody)]);
    await clientFor(scripted).listModels();
    expect(scripted.requests.single.headers, {
      ...scripted.requests.single.headers,
      'user-agent': 'typesafe_ai_dart/$version',
      'x-typesafe-sdk': 'typesafe_ai_dart/$version',
    });
  });

  test('the CHANGELOG documents the current version', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    expect(changelog, contains('## $packageVersion'));
  });
}

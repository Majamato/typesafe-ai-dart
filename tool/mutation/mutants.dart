/// A deliberate bug: in `file`, the single occurrence of `from` becomes `to`;
/// `id` names it in the report and `why` says what the tests must catch.
typedef Mutant = ({String id, String file, String from, String to, String why});

Mutant _m(String id, String file, String from, String to, String why) =>
    (id: id, file: file, from: from, to: to, why: why);

const _policy = 'lib/src/client/retry_policy.dart';
const _runner = 'lib/src/http/http_retry_runner.dart';
const _scheduler = 'lib/src/http/deadline_scheduler.dart';
const _transport = 'lib/src/http/http_transport.dart';
const _retryAfter = 'lib/src/http/http_retry_after.dart';
const _mapper = 'lib/src/http/http_error_mapper.dart';
const _client = 'lib/src/client/typesafe_client.dart';
const _token = 'lib/src/client/cancel_token.dart';

/// Hand-picked mutants of the logic most likely to break quietly.
final List<Mutant> mutants = [
  // Retry policy.
  _m(
    'policy-status-and',
    _policy,
    'retryOnStatuses.contains(statusCode) ||',
    'retryOnStatuses.contains(statusCode) &&',
    '408/429 alone retry',
  ),
  _m(
    'policy-5xx-edge',
    _policy,
    'statusCode <= 599',
    'statusCode < 599',
    '599 is a server error',
  ),
  _m(
    'policy-double-once-more',
    _policy,
    ': initial << attempt;',
    ': initial << (attempt + 1);',
    'backoff starts at backoffInitial',
  ),
  _m(
    'policy-jitter-adds',
    _policy,
    'final factor = 1 - ',
    'final factor = 1 + ',
    'jitter only shortens a delay',
  ),
  _m(
    'policy-retry-after-cap',
    _policy,
    'retryAfter <= maxRetryAfter',
    'retryAfter < maxRetryAfter',
    'a Retry-After equal to the cap counts',
  ),
  _m(
    'policy-timeout-flag',
    _policy,
    '? retryOnTimeout\n      : retryOnConnectionError',
    '? retryOnConnectionError\n      : retryOnTimeout',
    'timeouts consult retryOnTimeout',
  ),
  _m(
    'policy-jitter-clamp',
    _policy,
    'jitter.clamp(0.0, 1.0)',
    'jitter',
    'jitter is clamped (D11)',
  ),
  // Retry runner.
  _m(
    'runner-status-off-by-one',
    _runner,
    'attemptNumber >= policy.maxRetries) {\n          throw error;',
    'attemptNumber > policy.maxRetries) {\n          throw error;',
    'maxRetries bounds status retries',
  ),
  _m(
    'runner-error-off-by-one',
    _runner,
    '!policy.shouldRetryError(e) || attemptNumber >= policy.maxRetries',
    '!policy.shouldRetryError(e) || attemptNumber > policy.maxRetries',
    'maxRetries bounds error retries',
  ),
  _m(
    'runner-no-clamp',
    _runner,
    'attemptTimeout = remaining < timeout ? remaining : timeout;',
    'attemptTimeout = timeout;',
    'attempts are clamped to the budget',
  ),
  _m(
    'runner-skip-all-retries',
    _runner,
    'delay >= deadline - _clock()',
    'delay >= Duration.zero',
    'a retry within budget still happens',
  ),
  _m(
    'runner-budget-or',
    _runner,
    '(attemptTimeout < timeout || _clock() >= deadline)',
    '(attemptTimeout < timeout && _clock() >= deadline)',
    'a clamped timeout reports the budget',
  ),
  _m(
    'runner-close-no-wake',
    _runner,
    'if (closing != null) onCancel(closing, wake),',
    '',
    'close() wakes a call in backoff (D12)',
  ),
  _m(
    'runner-timer-kept',
    _runner,
    '      timer?.cancel();\n',
    '',
    'a cancel stops the backoff timer (S5)',
  ),
  _m(
    'runner-no-saturation',
    _runner,
    'totalTimeout > _forever - now ? _forever : now + totalTimeout',
    'now + totalTimeout',
    'a huge budget does not overflow (D5)',
  ),
  // Deadline scheduler.
  _m(
    'scheduler-no-rearm',
    _scheduler,
    'if (_timer == null || entry._at < _timerAt) {',
    'if (_timer == null) {',
    'an earlier deadline re-arms the timer',
  ),
  _m(
    'scheduler-floor-ms',
    _scheduler,
    'wait ~/ 1000 + (wait % 1000 == 0 ? 0 : 1)',
    'wait ~/ 1000',
    'a timer never wakes before its deadline',
  ),
  _m(
    'scheduler-stop-when-idle',
    _scheduler,
    'if (_closed && _pending == 0) {',
    'if (_pending == 0) {',
    'the timer stays armed until close (perf)',
  ),
  _m(
    'scheduler-caller-zone',
    _scheduler,
    '_timer = _zone.createTimer(',
    '_timer = Zone.current.createTimer(',
    'timers live in the scheduler zone (D3)',
  ),
  _m(
    'scheduler-no-saturation',
    _scheduler,
    'final at = micros > _never - now ? _never : now + micros;',
    'final at = now + micros;',
    'a huge delay means never (D5)',
  ),
  // Transport.
  _m(
    'transport-body-not-cancelled',
    _transport,
    '          unawaited(subscription.cancel());\n',
    '',
    'a timeout mid-body cancels the stream',
  ),
  _m(
    'transport-no-discard',
    _transport,
    'unawaited(_discard(sent));',
    '',
    'a late response is discarded',
  ),
  _m(
    'transport-no-race',
    _transport,
    'await Future.any([sent, aborted]);',
    'await sent;',
    'a client ignoring abort still times out',
  ),
  _m(
    'transport-deadline-leak',
    _transport,
    '      deadline.cancel();\n',
    '',
    'every deadline is cancelled',
  ),
  _m(
    'transport-listener-leak',
    _transport,
    '      unregister?.call();\n',
    '',
    'a finished call leaves no cancel listener',
  ),
  _m(
    'transport-headers-as-is',
    _transport,
    'headers: _lowerCaseNames(response.headers),',
    'headers: response.headers,',
    'header names are lower-cased (LC)',
  ),
  // Retry-After.
  _m(
    'retry-after-infinite',
    _retryAfter,
    'return parsed != null && parsed.isFinite ? parsed : null;',
    'return parsed;',
    'NaN/Infinity are ignored (S1)',
  ),
  _m(
    'retry-after-ms-ignored',
    _retryAfter,
    'final ms = headers[retryAfterMsHeader];',
    'final ms = headers[retryAfterHeader];',
    'retry-after-ms wins',
  ),
  _m(
    'retry-after-past-date',
    _retryAfter,
    'return delta.isNegative ? Duration.zero : delta;',
    'return delta;',
    'a past date means no wait',
  ),
  // Error mapping.
  _m(
    'mapper-422',
    _mapper,
    '422 => UnprocessableEntityException(',
    '423 => UnprocessableEntityException(',
    '422 has its own class',
  ),
  _m(
    'mapper-message-order',
    _mapper,
    "_messageOf(json['message']) ??\n      _messageOf(json['detail'])",
    "_messageOf(json['detail']) ??\n      _messageOf(json['message'])",
    'message beats detail',
  ),
  // Client.
  _m(
    'client-retry-count-on-first',
    _client,
    'if (attempt > 0) retryCountHeader:',
    'if (attempt >= 0) retryCountHeader:',
    'no retry count on attempt 0',
  ),
  _m(
    'client-keeps-reserved',
    _client,
    'if (!_droppedHeaders.contains(name)) {',
    'if (name.isNotEmpty) {',
    'SDK-owned headers win (S3/N5)',
  ),
  _m(
    'client-close-not-signalled',
    _client,
    '    _closing.cancel();\n',
    '',
    'close() fails new calls fast (S8)',
  ),
  _m(
    'client-no-request-id',
    _client,
    'requestId: response.headers[requestIdHeader],',
    'requestId: null,',
    'the request id is read',
  ),
  _m(
    'client-timeout-unchecked',
    _client,
    'if (timeout <= Duration.zero) {',
    'if (timeout < Duration.zero) {',
    'a zero timeout is rejected (RO)',
  ),
  // Parsing and values.
  _m(
    'answer-lenient-level',
    'lib/src/answers/answer.dart',
    '_isDecimalIndex(key) ? int.tryParse(key) : null',
    'int.tryParse(key)',
    'level keys are strict (D7)',
  ),
  _m(
    'answer-typed-equals-raw',
    'lib/src/answers/answer.dart',
    '      other.runtimeType == runtimeType &&\n',
    '',
    'a typed answer never equals its raw one',
  ),
  _m(
    'question-choice-unchecked',
    'lib/src/questions/question.dart',
    'if (!criteria.containsKey(answer.choice)) {',
    'if (answer.choice.isEmpty) {',
    'a choice outside the criteria is rejected',
  ),
  _m(
    'request-reserved-extra',
    'lib/src/request/system_one_request.dart',
    'if (_reserved.contains(key)) {',
    'if (key.isEmpty) {',
    'documented fields win over extra',
  ),
  _m(
    'fields-no-widening',
    'lib/src/json/json_fields.dart',
    'final num value => value.toDouble(),',
    'final double value => value,',
    'a JSON integer reads as a double',
  ),
  _m(
    'equality-missing-key',
    'lib/src/json/json_equality.dart',
    '          if (!n.containsKey(key)) {\n'
        '            return false;\n'
        '          }\n',
    '',
    'maps with different keys differ',
  ),
  _m(
    'token-listeners-kept',
    _token,
    '    _listeners.clear();\n',
    '',
    'a cancelled token drops its listeners',
  ),
  // Events and the raw response.
  _m(
    'runner-no-retry-event',
    _runner,
    'trace?.retrying(delay, error, policy.maxRetries);',
    '',
    'a retry is reported before its wait',
  ),
  _m(
    'client-no-usage',
    _client,
    'trace?.finished(usage: result.usage);',
    'trace?.finished();',
    'CallFinished carries the token usage of the call',
  ),
  _m(
    'client-raw-dropped',
    _client,
    'raw: response,',
    'raw: null,',
    'a response keeps the raw reply it came from',
  ),
  _m(
    'usage-infinite',
    'lib/src/response/usage.dart',
    'value is num && value.isFinite ? value.toInt() : 0',
    'value is num ? value.toInt() : 0',
    'a non-finite count reads 0 (D1)',
  ),
];

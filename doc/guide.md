# Guide

How to use `typesafe_ai_dart` beyond the [README](../README.md). The reasons
behind these choices are in the [design notes](design.md).

## Questions and answers

| Question | Answer | What you get |
| --- | --- | --- |
| `Noul` | `NoulAnswer` | `noul`: probability of yes in `[0, 1]` |
| `Choice` | `ChoiceAnswer` | `choice`, `probabilities` per option, `confidence` |
| `TypedChoice<E>` | `TypedChoiceAnswer<E>` | `selected` as a value of `E`, `distribution` per option, `confidence` |
| `Score` | `ScoreAnswer` | `score` (weighted mean level), `mostLikelyLevel`, `probabilities` and `legend` per level index, `confidence` |

The `id` is the key in the request and the response. The model never sees
it, so put the full meaning in `instructions`. Refer to state fields in
backticks, as in `` `ticket.messages[0].text` ``. Instructions and criteria
take strings, or structured JSON (`Map`, `List`) when definitions,
exclusions or examples help.

- `Choice.fromEnum(values: MyEnum.values)` builds a `TypedChoice<MyEnum>`.
  Its answer gives `selected` and `probabilityOf(MyEnum.x)`, already typed.
  Keys default to the enum `name`. Pass `encode: (v) => ...` when the API
  expects other keys, such as `snake_case`, and `describe: (v) => ...` to
  tell the model what each option means.
- A plain `Choice` fits options only known at runtime. Its
  `probabilityOfKey('...')` takes a raw option key and returns 0 for an
  unknown one.
- `NoulCriteria(whenTrue: ..., whenFalse: ...)` defines the two outcomes.
- `ScoreLevel(summary: ..., signals: [...])` describes one rubric level.

A `Choice` takes 1 to 255 options, and a `Score` 2 to 10 levels.

A `Noul` has no verdict of its own. Pick the threshold that fits the cost of
being wrong. `confidence` on a choice or score says how concentrated the
distribution is, not how likely the answer is to be right.

Read answers through the handle you sent to get static types, or through
`response['id']`, `response.nouls`, `response.choices` and
`response.scores` for dynamic access.

`example/typesafe_ai_dart_example.dart` asks all three question types about one
ticket.

## Configuration

```dart
final client = TypeSafeClient(
  apiKey: '...',
  baseUrl: 'https://api.typesafe.ai',
  defaultModel: 'jev-latest',
  defaultHeaders: {'x-app': 'demo'},
  timeout: Duration(seconds: 10),
  totalTimeout: Duration(seconds: 15),
  retryPolicy: RetryPolicy(maxRetries: 3),
  httpClient: myHttpClient,
  onEvent: print,
);
```

`apiKey`, `baseUrl` and `defaultModel` fall back to the `TYPESAFE_API_KEY`,
`TYPESAFE_BASE_URL` and `TYPESAFE_DEFAULT_MODEL` environment variables, then
to `--define` values of the same names. An empty value counts as unset.
`TypeSafeClient.withConfig(ClientConfig(...))` skips the environment and the
built-in defaults.

The key must be visible ASCII. A key read from a file with a trailing
newline is rejected with an `ArgumentError` that never echoes it, so `trim()`
it. Header names must be HTTP tokens, and header values may hold visible
ASCII, spaces and tabs. Header names match in any case. The SDK owns
`authorization`, `accept`, `content-type`, `user-agent`, `x-typesafe-sdk`
and `x-typesafe-retry-count`. The HTTP client
owns framing and hop-by-hop headers such as `host`, `content-length` and
`accept-encoding`. The SDK drops any of these a caller passes.

`listModels()` returns the models your account can use.

### Transport

By default the SDK builds an `IOClient` (HTTP/1.1 with keep-alive). To tune
its pool, inject your own:

```dart
final client = TypeSafeClient(
  httpClient: IOClient(HttpClient()..maxConnectionsPerHost = 32),
);
```

For pooled HTTP/2, pass `http2: true`. It needs an `https` base URL and
can't be combined with `httpClient`. Read
[HTTP/1.1 or HTTP/2](design.md#http11-or-http2) first.

```dart
final client = TypeSafeClient(http2: true);
```

`close()` shuts down whichever client the SDK built. It lets attempts
already on the wire finish, and fails new calls and pending retries at once
with `TypeSafeConnectionException`. A client you inject is yours to close.

## Per-call options

```dart
final token = CancelToken();
final response = await client.systemOne(
  state: text,
  questions: [q],
  model: 'jev-1.13.0',
  options: RequestOptions(
    timeout: Duration(seconds: 3),
    totalTimeout: Duration(seconds: 5),
    retryPolicy: RetryPolicy.none,
    headers: {'x-trace': 'abc'},
    cancelToken: token,
  ),
);
```

`token.cancel()` fails the pending call with `TypeSafeCancelledException`,
aborts its request and stops further retries. A request already on the wire
may still reach the server, and its result is discarded. One token can be
shared by any number of calls, such as a shutdown signal, without growing
with them.

`extra` adds fields to the request body. `state`, `model` and `questions`
win over `extra` keys of the same name. A request encodes `state` and
`extra` when it is built, so changes to them after that are never sent. A
`SystemOneRequest` keeps your `questions` list and reads it on every send,
so don't change the list afterwards.

## Retries and timeouts

The defaults are two retries, backoff from 500 ms doubling to 5 s with 25%
jitter, and retries on HTTP 408, 429 and 5xx and on connection or timeout
errors. A server `Retry-After` or `retry-after-ms` header is honoured up to
60 s. Tune any of this with `RetryPolicy`, or turn retries off with
`RetryPolicy.none`.

`timeout` is per attempt, and retries don't share it. With the defaults a
call can hold the caller for 3 × 10 s plus 0.5 s and 1 s of backoff, about
31.5 s, before a timeout or connection error surfaces. On a 429 or 5xx path
with a 60 s `Retry-After` it is about 150 s.

`totalTimeout` bounds the whole call instead. Each attempt is clamped to
what remains, and a retry whose backoff would overrun the budget is skipped.
The call then throws the last error in hand, or `TypeSafeTimeoutException`
with `timeout` equal to the budget once it is spent. It defaults to `null`,
which keeps the per-attempt behaviour.

A timed-out or cancelled attempt aborts its request. Over HTTP/1.1 the SDK
closes the socket at any point. With `http2: true` it resets the stream only
once response headers have arrived.

## Bad arguments

Bad arguments are an `ArgumentError`. Question constructors and the client
constructor throw it right away, so a bad handle or key fails at startup.
`systemOne` delivers it through the returned `Future`. That covers non-JSON
anywhere in `state` or `extra` (a `DateTime`, a `Set`, `NaN`), a repeated
question id, a bad per-call header, and a timeout that isn't positive. With
`send`, the `SystemOneRequest` constructor throws the `state`, `extra` and
id errors right away, and `send` delivers the header and timeout errors
through its `Future`.

`state` itself must be a String, a `Map<String, Object?>`, a `List` or a
`JsonEncodable`. Inside it, and in `extra` values, an object with a
`toJson()` method is encoded through that method, and any other non-JSON
object fails. Messages name the argument and the offending type. They never echo
the API key, a header value or the contents of `state`.

## Logging and metrics

Pass `onEvent` to see what each call does. The client reports a typed event
for every step:

| Event | When | Use it for |
| --- | --- | --- |
| `AttemptStarted` | an attempt is about to be sent | tracing; `attempt` counts from 1, `timeout` is the time it gets |
| `AttemptResponded` | an attempt got a whole response, any status | per-attempt latency and status; `response` is the raw reply |
| `AttemptFailed` | an attempt got no response: timeout, connection error or cancel | network trouble |
| `RetryScheduled` | the call waits `delay`, then retries after `reason` | spotting rate limits (HTTP 429) and outages |
| `CallFinished` | the call is over | one log line per call: `elapsed`, `attempts`, `usage`, `error` |

Every event of a call carries the same `callId`, and each prints as one line:

```text
#12 POST /v1/systemone <- 200 in 143ms (request req_abc)
#13 POST /v1/systemone retrying in 500ms (retry 1/2) after HTTP 429
#13 POST /v1/systemone <- 200 in 671ms after 2 attempts (request req_abd)
```

One line per call:

```dart
final client = TypeSafeClient(
  onEvent: (event) {
    if (event is CallFinished) stdout.writeln(event);
  },
);
```

Metrics, with the types doing the work:

```dart
void record(TypeSafeEvent event) {
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
}

final client = TypeSafeClient(onEvent: record);
```

- **Free when unset.** Without `onEvent`, a call builds no events and reads
  no extra clock. The cost is a null check. An event formats its log line
  only when you call `toString`.
- **Synchronous, in the caller's zone.** Zone values you set with
  `runZoned`, such as a request id, are visible in the callback. Keep it
  quick and hand slow work, like shipping logs, to a queue.
- **It can't break a call.** Anything the callback throws is caught and
  ignored. Wrap it if you need to see those errors. An `async` callback's
  own errors are not caught.
- **Exactly one `CallFinished`** for every call that ends with a result or
  a `TypeSafeException`. A call that fails before sending (a closed client,
  a token already cancelled) reports only that, with `attempts: 0`. Bad
  arguments (`ArgumentError`) report nothing.
- A `RetryScheduled` can still end the call without a new attempt, when a
  cancel or `close()` lands during the wait.

## Raw response

`response.raw` is the HTTP response the answers came from: `statusCode`,
`headers` with lower-case names, `bodyBytes` as received, and `body`,
decoded from UTF-8 only when you read it. The SDK has all of these anyway,
so keeping them costs nothing, but holding a response keeps its bytes alive.
It is `null` for a response you build yourself. `AttemptResponded.response`
gives the same for every attempt, retried ones included. Token usage per
call is `response.usage`.

```dart
final response = await client.systemOne(state: text, questions: [q]);
final raw = response.raw!;
print('${raw.statusCode}, ${raw.bodyBytes.length} bytes, ${raw.requestId}');
print('${response.usage.inputTokens} input tokens');
```

## Testing your own code

Pass a `MockClient` from `package:http/testing.dart` as `httpClient`. No
network, no real key:

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

TypeSafeClient fakeClient(Map<String, Object?> answers) => TypeSafeClient(
  apiKey: 'test',
  httpClient: MockClient(
    (request) async => http.Response(
      jsonEncode({
        'model': 'jev-test',
        'answers': answers,
        'usage': {'input_tokens': 10, 'output_tokens': 1},
      }),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
);

final client = fakeClient({
  'isAngry': {'type': 'noul', 'noul': 0.92},
});
```

## Experimental: images, Box and long context

These come from Jev 1.14's "Danger Zone". TypeSafe doesn't call them ready
for production, and their request format, answers and limits can change
between releases. They ship only in `0.2.0` prereleases, under their own
import:

```dart
import 'package:typesafe_ai_dart/experimental.dart';
```

Everything there is marked `@experimental`, so it can change in a release
that isn't a breaking one. Dart 3.11 and later report each use as an
`experimental_member_use` warning. Turn it off in `analysis_options.yaml`
with `analyzer: errors: experimental_member_use: ignore`.

### Turning features on

Each feature is off until a request sends its `TypeSafe-Danger-Zone-*`
header. `DangerZone` names them:

| Value | Header | What it turns on |
| --- | --- | --- |
| `DangerZone.images` | `TypeSafe-Danger-Zone-Images: true` | Images in a request, and `Box` questions |
| `DangerZone.longContext` | `TypeSafe-Danger-Zone-Long-Context: true` | 262k tokens per request and per question, instead of the defaults |

Turn one on for every call with `TypeSafeClient(dangerZone: {...})`, or for
one call with `RequestOptions(dangerZone: {...})`. Sending the header in
`headers` works too. A request with an `Image` or a `Box` but without
images turned on fails with an `ArgumentError` before it is sent, instead
of a 400 from the API. Long context is slower and less accurate than the
default limits, so turn it on only for the calls that need it.

### Images

`Image(bytes)` takes the bytes of a PNG or JPEG file, and
`Image.fromFile(path)` reads one. Put an image anywhere a request takes
text:

- in `state`, where every question sees it. Refer to it by path, as in
  `` `photo` `` or `` `frames[2].frame` ``;
- in a question's `instructions`, sent only with that question:
  `` TextWithImages(['Is the person in `door` the same as ', badge, '?']) ``;
- in criteria, as an example for a `Choice` option, a `Score` level or a
  `Noul` outcome: `criteria: {'thumbs_up': thumb, 'none': 'No hand.'}`.

Each image stands in the request as its `reference`, a random string that
can't occur in your text by accident. You can pick one with
`Image(bytes, reference: ...)`, but it is matched as plain text, so it must
not appear anywhere else in the request. Interpolating an image into a
string (`'$image'`) doesn't work; use `TextWithImages`.

A request with images goes out as `multipart/form-data`, as TypeSafe
recommends. The JSON body is the first part, named `request`, with an
`assets` map pointing each reference at a file part. Then comes each image,
sent once even when it appears in several places. Each extra place still
counts against the request limits, so an image several questions need
belongs in `state`. `SystemOneRequest.contentType` gives the content type
of `encode()`'s bytes.

The client checks only that an image is a PNG or JPEG file. The API
enforces the limits, which TypeSafe may change: currently 16 MiB per file,
280 to 1568 pixels per side, and 32 MiB for the whole request. Resize
images and rotate them upright before sending, because the API drops EXIF
data, orientation included. See
[TypeSafe's image guide](https://docs.typesafe.ai/images).

An image's bytes are not copied, so don't change them after building the
`Image`. Don't put an image in `extra`: the API looks for images only in
the state, instructions and criteria, so the request rejects one there.
Don't combine images with an `assets` entry in `extra` either. Without
images, an `assets` entry in `extra` is sent as before, as when you build
assets by hand.

### Box

`Box(id: ..., instructions: ...)` finds one thing in an image. Its
`BoxAnswer` has `top`, `bottom`, `left` and `right`, each a fraction of the
image's size from its top-left corner, plus `width`, `height` and
`confidence`. Multiply by the image's size in pixels to draw or crop it.

- Box questions need Jev 1.14: `model: 'jev-preview'` or `'jev-1.14.0'`.
- A Box always answers with a box, even when the target isn't there. Ask a
  `Noul` such as "Is there a mug in `photo`?" in the same request, and
  ignore the box when it is low.
- There is no recommended `confidence` threshold yet. Tune one on your own
  images.

`example/experimental_images.dart` runs a Box and a Noul on a photo.

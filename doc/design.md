# Design notes

Why `typesafe_ai_dart` works the way it does. For how to use it, see the
[guide](guide.md).

Two rules decide every trade-off here. Answers stay typed as far as Dart
allows, and a call does no work it doesn't need. A feature that returned
typed answers at the cost of extra decoding didn't get in. Neither did a
fast path that handed back untyped maps.

## Typed without code generation

- A question is a `Question<A>` whose type parameter is its answer type.
  `response.answer(handle)` returns that `A`, so reading an answer needs no
  cast and no string key.
- `Choice.fromEnum` carries your enum through the request and back.
  `selected` is a value of your enum, and `probabilityOf` takes one, so a
  misspelled option is a compile error. If the API ever answers with an
  option you didn't offer, the SDK throws `ResponseValidationException`
  instead of mapping it to something.
- `Question`, `Answer`, `TypeSafeException` and `TypeSafeEvent` are
  sealed, so the analyzer checks a `switch` over any of them for
  exhaustiveness. A few subtypes below them stay open, such as
  `TypeSafeConnectionException` and `ChoiceAnswer`, so your own subclass of
  one lands in its parent's case.
- Questions and clients validate their input when you build them. A bad
  question fails at startup, not on the first request that uses it.
- No code generation means no `build_runner` step and no generated files to
  keep in sync.

## Little work per call

Everything that can happen once, happens once:

- A question encodes itself to UTF-8 JSON bytes when constructed. Every
  request splices those bytes into its body.
- Per call, only `state` and `extra` are encoded, straight to UTF-8, plus
  the `model` string when the call names one. Retries reuse the same body
  bytes.
- Responses decode from bytes with a fused UTF-8 and JSON decoder, without
  an intermediate `String`.
- Typed views are built on first use. `TypedChoiceAnswer.distribution` is
  built when you read it, and `RawResponse.body` is decoded only if you ask.
- One `Timer` per client serves every in-flight attempt timeout, instead of
  one per attempt. A retry's backoff waits on a timer of its own.
- Without `onEvent`, a call builds no events and reads no extra clock.
- Questions, requests, `ClientConfig` and `RequestOptions` skip `==` and
  `hashCode`. Nothing on the hot path needs them. `RetryPolicy` has both,
  so two policies with the same settings compare equal.

`benchmark/sdk_overhead.dart` swaps the network for an in-memory client that
answers at once, so it measures only the SDK. Compiled AOT, fastest of 7
runs, on 2026-09-26, compared with a call that has a small `state`:

| Call | SDK time per call |
| --- | --- |
| small `state` (one short field) | baseline |
| 2 KB `state` | about 3.5 times the baseline |
| small `state` with an empty `onEvent` | about 7% more |

A call to the real API spends tens to hundreds of milliseconds on the
network, depending on where you are, so even the 2 KB case is a fraction of
a percent of a call. Measure the SDK on your own machine:

```sh
dart run benchmark/sdk_overhead.dart
dart compile exe benchmark/sdk_overhead.dart -o /tmp/b && /tmp/b   # AOT
```

### Ideas that didn't pay off

The SDK's share of a call is a fraction of a percent. A change that saves a few more microseconds is worth it only if it
costs nothing else.
These two didn't clear that bar.

**A faster JSON library.** [Crimson](https://pub.dev/packages/crimson) is a
fast JSON library for Dart. It is at its best with generated code that
parses JSON straight into your own classes and skips the fields you don't
read. Its generic reader and writer can also stand in for `dart:convert`,
which is the part measured here. Crimson's time compared with
`dart:convert` as the SDK uses it, compiled AOT, fastest of 5 runs, Crimson
0.4.0+1 on Dart 3.13.4, on 2026-09-26:

| Work | Crimson |
| --- | --- |
| decode a 458-byte response | about the same |
| decode 1.8 KB | about 20% slower |
| encode 458 bytes | about 40% less time |
| encode 1.8 KB | about 45% less time |

Decoding gains nothing. On the VM, `utf8.decoder.fuse(json.decoder)`
already parses the bytes directly, with no `String` in between. Encoding
takes less time, but questions are encoded once, when you build them, so
per call the saving applies to `state` alone and comes to a few
microseconds.

Crimson also assumes its input is valid JSON, which is a fair trade for a
parser built for speed. This SDK wants a malformed response to fail with
`ResponseValidationException`. Crimson's reader returns `{a: 1}` for
`{"a":1} trailing`, and its writer emits `NaN` as the bare word `NaN`, which
the server then rejects. `dart:convert` throws on both. Keeping that
behaviour would mean adding checks around the faster parser, for no gain on
the decoding side.

**Decoding in a background isolate.** Moving JSON decoding off the main
isolate is common advice for Flutter apps, where decoding a large body can
drop frames. A response here is about 500 bytes and decodes in a few
microseconds.
Sending the bytes to another isolate and the result back costs more than
that, so every call would get slower.

HTTP/2 looks like a third idea of this kind, and is closer to a real
trade-off. It has [its own section](#http11-or-http2).

## HTTP/1.1 or HTTP/2

HTTP/2 looks like the obvious default for a server SDK, since one connection
carries many calls. It isn't the default here, for two reasons:

- **`Http2Client` is experimental upstream.** `package:http2`, from the
  Dart team, marks it `@experimental`, and it first shipped in `http2`
  3.1.0, so its API may change in a minor release.
- **It has [known limitations](#known-limitations)** that hurt long-running
  servers on networks that drop idle connections without closing them.
  HTTP/1.1 has none of them.

So the SDK uses `IOClient` from `package:http`. That is HTTP/1.1 with
keep-alive, one TLS connection per concurrent call, each kept for reuse
until it has sat idle for 15 seconds (`HttpClient.idleTimeout`). With
`http2: true` it uses `Http2Client` instead, which multiplexes up to 100
concurrent calls, or the server's own limit, over one pooled connection.

What HTTP/2 buys is the TLS handshakes it skips when many calls start at
once on a cold client. Once connections are warm the two perform about the
same. Measured on 2026-09-26 from one developer machine against the real
API. Each run makes 5 rounds of N concurrent `GET /v1/models` calls on a
fresh client, and "cold" is the first round. Each figure is HTTP/2's time
compared with HTTP/1.1's, using the median of 3 runs for each. A negative
figure means HTTP/2 took less time.

| Concurrent calls | Cold p50 | Warm p50 | Warm p99 | Total |
| ---: | ---: | ---: | ---: | ---: |
| 1 | +3% | +2% | +1% | +1% |
| 16 | -19% | -2% | -1% | -10% |
| 64 | -53% | -6% | -8% | -32% |

`systemOne` calls add model time on top, so the gap there is smaller still.
Your figures depend on your machine and your distance to the API, so
measure your own:

```sh
TYPESAFE_API_KEY=... dart run benchmark/live_transport.dart 64 5
```

Pick HTTP/2 if you often start dozens of calls at once and can accept the
known limitations. Otherwise keep the default.

### Known limitations

These apply only with `http2: true`. They come from `Http2Client` in
`package:http2`, which the SDK can't reach into. They don't show in normal
traffic, and each has a test pinning it, so an upstream fix surfaces as a
test failure.

- **No abort before response headers.** A call that times out or is
  cancelled before the server answers fails on time, but its HTTP/2 stream
  stays open until the server responds. If the connection has silently died
  (a NAT or load balancer dropping it without a close), that is never. 100
  calls time out before the pool opens a new connection, the dead one is
  never released, and `close()` can't finish, so the process doesn't exit on
  its own.
- **No TLS handshake timeout.** Calls queue behind a handshake that never
  completes and time out. 50 such handshakes wedge the pool until the OS
  gives up on them.
- **A call that timed out during a slow handshake is still sent** once the
  handshake completes. Its result is discarded.
- **A call racing a server's GOAWAY** spends one retry instead of being
  replayed for free. With `RetryPolicy.none` it fails.

The default HTTP/1.1 client has none of these. Over HTTP/1.1, a timeout or
cancel closes the socket at any point.

## Retries and time budgets

Retry defaults, retry decisions and `Retry-After` parsing are ported from
the official JavaScript SDK (`typesafe-sdk-js`), so a service calling the
API from Dart and from JavaScript sees the same behaviour. The numbers are
in the [guide](guide.md#retries-and-timeouts). The JavaScript SDK has no
budget for a whole call, so `totalTimeout` is an addition.

The default `timeout` is per attempt, which makes the worst case long. About
31.5 s against a silent server, and about 150 s under rate limiting with a
60 s `Retry-After`. `totalTimeout` exists for callers with a budget. It caps
the whole call, retries and backoff included, and skips a retry whose
backoff would overrun it. Budgets run on a monotonic clock, so a wall-clock
change can't stretch or cut them.

## Errors

- Every runtime failure is a subclass of the sealed `TypeSafeException`.
  Status routing, the order fields are read to find the message, and the
  default messages are ported from the official JavaScript SDK, and the
  classes mirror its errors. `UnknownApiException` (unexpected statuses)
  and `ResponseValidationException` (a response that doesn't match the
  documented shape) are additions.
- A programming mistake is an `ArgumentError`, never a `TypeSafeException`,
  so it can't be mistaken for something to retry.
- Error messages end up in logs, so they never echo the API key, header
  values or the contents of `state`. They name the argument and the
  offending type.

## Events instead of a logger

Servers already have a logging and metrics setup, so the SDK doesn't bring
another one with levels and formats to configure. It reports typed events
through `onEvent` and lets you route them.

- Without `onEvent` the cost is one null check per step.
- Each event formats its one-line log text only when you call `toString`.
- The callback runs synchronously in the caller's zone, so zone values such
  as a request id are visible.
- Whatever the callback throws is caught, so an observer can't change the
  result of a call.
- Every call that ends with a result or a `TypeSafeException` reports
  exactly one `CallFinished`, with its latency, attempts, status, request id
  and token usage.

## How it's tested

The suite is built to find what normal tests miss. Besides unit tests it
has:

- contract tests that pin documented behaviour, including worst-case timing
  on a fake clock
- seeded property tests. Set `TYPESAFE_FUZZ_SEED` to replay a failure and
  `TYPESAFE_FUZZ_RUNS` to run more cases.
- real HTTP/1.1 and HTTP/2 servers on loopback that stall, drop
  connections and send broken replies
- subprocess tests for process exit, memory, AOT builds and a
  `pub publish` dry run
- stress tests with load, cancel storms and leak checks
- a mutation run that breaks the code 47 ways, to check the tests notice

```sh
dart test               # unit, contract, property, loopback servers,
                        # subprocesses
dart test -P io         # only the loopback-server tests
dart test -P stress     # load, cancel storms, leak and memory checks
dart test -P mutation   # the 47 mutants
dart run coverage:test_with_coverage -- -x live   # line coverage of lib/
```

Live tests call the real API and skip themselves unless `TYPESAFE_API_KEY`
is set. Run only those with `dart test -t live`.

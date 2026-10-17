# typesafe_ai_dart

A typed Dart client for the [TypeSafe AI](https://docs.typesafe.ai) System
One API, built for servers.

Unofficial and not affiliated with TypeSafe. AI agents: start with
[AGENTS.md](AGENTS.md).

Experimental image and Box support (Jev 1.14) is in the 0.2.0 prereleases.
See [Experimental](#experimental-images-and-box-jev-114).

## How it's built

Two rules shaped every decision. Keep answers typed as far as Dart allows,
and do no work per call that isn't needed.

- **Typed end to end, no code generation.** A question's type carries its
  answer type, so `response.answer(handle)` needs no cast. An enum choice
  answers with your enum, so a misspelled option fails at compile time.
- **No parsing you don't need.** Questions are encoded to bytes once, when
  you build them. Each call encodes only `state` and `extra`, and responses
  decode straight from bytes into typed answers. The SDK's own work is a
  fraction of a percent of a call. The rest is the network.
- **HTTP/1.1 by default.** The Dart team's HTTP/2 client (`Http2Client` in
  `package:http2`) is marked experimental and has open issues that hurt
  long-running servers. HTTP/2 is one flag away, and in our measurements it
  only pays off when dozens of calls start at once on a cold client.
- **Failures are typed too.** One sealed exception hierarchy, retries that
  honour `Retry-After`, and a `totalTimeout` that caps the whole call.
- **Behaves like the official JavaScript SDK.** Its retry defaults,
  `Retry-After` parsing and mapping from HTTP errors to exceptions are
  ported from it, so the same failure is retried the same way and raises the
  matching exception. `totalTimeout` and typed events are additions.
- **Logging is free until you turn it on.** `onEvent` reports every attempt,
  retry and finished call as a typed event. Without it, a call builds none.

[doc/design.md](doc/design.md) has the reasoning, the measurements and the
known limitations.

## Example

```dart
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

enum Department { billing, technical, other }

final department = Choice.fromEnum(
  id: 'department',
  instructions: 'Which department should handle `ticket`?',
  values: Department.values,
);
final isAngry = Noul(
  id: 'isAngry',
  instructions: 'Is the author of `ticket` angry?',
);

Future<void> main() async {
  // Reads TYPESAFE_API_KEY from the environment. To load the key from
  // somewhere else, pass it as apiKey:.
  final client = TypeSafeClient();

  final response = await client.systemOne(
    state: {'ticket': 'I was charged twice. Fix it today or I cancel.'},
    questions: [department, isAngry],
  );

  final Department route = response.answer(department).selected;
  final double angry = response.answer(isAngry).noul; // probability of yes
  if (angry > 0.8) print('escalate to ${route.name}');

  client.close();
}
```

## Install

```sh
dart pub add typesafe_ai_dart
```

Needs Dart 3.10 or later. Pass your API key as `apiKey:`, or set
`TYPESAFE_API_KEY` and leave it out.

It is built and tested for the Dart VM on Linux, macOS and Windows. Flutter
apps on Android, iOS and desktop should work too, since they have
`dart:io`, but they aren't tested, and an API key shipped inside an app can
be extracted from it. Calling the API from your own backend is safer. The
web isn't supported, because the client needs `dart:io`.

## Questions

| Question | Answer | You read |
| --- | --- | --- |
| `Noul` | `NoulAnswer` | `noul`, the probability of yes |
| `Choice` | `ChoiceAnswer` | `choice`, `probabilities`, `confidence` |
| `Choice.fromEnum` | `TypedChoiceAnswer<E>` | `selected` as your enum, `distribution`, `confidence` |
| `Score` | `ScoreAnswer` | `score`, `mostLikelyLevel`, `probabilities`, `confidence` |

The model never sees a question's `id`, so put the whole question in
`instructions`.

## On a server

- Create one `TypeSafeClient` per process, share it, and call `close()` on
  shutdown. Calls already on the wire finish, and new ones fail at once.
- Declare questions as top-level or `static final` values, so each one is
  encoded once.
- Put independent questions in one call. They run in parallel over the same
  state.
- Set `totalTimeout` when the caller has a latency budget. Without it, a
  call can retry for about 31.5 s, or about 150 s when rate limited.

## Errors

Every failure is a `TypeSafeException`. The hierarchy is sealed, so this
`switch` covers all of them:

```dart
try {
  await client.systemOne(state: text, questions: [q]);
} on TypeSafeException catch (e) {
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
}
```

A bad argument is an `ArgumentError`, which is a bug to fix, not a failure
to retry.

## Experimental: images and Box (Jev 1.14)

TypeSafe's Jev 1.14 adds "Danger Zone" features that it doesn't yet call
ready for production: images in a request, `Box` questions that find
something in an image, and long context. Their request format, answers and
limits can change between releases.

They ship only in prereleases of this package, so `^0.1.0` never picks them
up. To try them:

```sh
dart pub add 'typesafe_ai_dart:^0.2.0-dev.1'
```

Then import `experimental.dart` next to the main library:

```dart
import 'package:typesafe_ai_dart/experimental.dart';
import 'package:typesafe_ai_dart/typesafe_ai_dart.dart';

final mugVisible = Noul(
  id: 'mugVisible',
  instructions: 'Is there a coffee mug in `photo`?',
);
final mug = Box(id: 'mug', instructions: 'the coffee mug in `photo`');

Future<void> main() async {
  final client = TypeSafeClient(dangerZone: {DangerZone.images});
  final photo = await Image.fromFile('kitchen.jpg');

  final response = await client.systemOne(
    state: {'photo': photo},
    questions: [mugVisible, mug],
    model: 'jev-preview', // Box needs Jev 1.14
  );
  // A Box always answers, even when nothing is there: check the Noul first.
  if (response.answer(mugVisible).noul > 0.5) {
    final box = response.answer(mug);
    print('mug: left ${box.left}, top ${box.top}, width ${box.width}');
  }
  client.close();
}
```

- Put an `Image` anywhere a request takes text: in `state`, in
  `instructions`, or in criteria. Use `TextWithImages` to put one inside a
  sentence.
- A request with an image or a `Box` needs `DangerZone.images`, on the
  client or in `RequestOptions(dangerZone: ...)`. Without it, the call fails
  with an `ArgumentError` before anything is sent.
- `DangerZone.longContext` raises the context limit to 262k tokens. It is
  slower and less accurate, so turn it on only per call.
- Everything in `experimental.dart` is marked `@experimental`, so Dart 3.11
  and later warn on each use (`experimental_member_use`). The guide shows
  how to turn that off.
- In Flutter, `Image` clashes with the `Image` widget. Import the library
  with a prefix: `import 'package:typesafe_ai_dart/experimental.dart' as ts;`.

Calls without these features behave exactly as in 0.1.0. The
[guide](https://github.com/Majamato/typesafe-ai-dart/blob/jev-1-14/doc/guide.md#experimental-images-box-and-long-context)
has the details.

## Learn more

- [Guide](doc/guide.md) covers configuration, per-call options, retries and
  timeouts, logging and metrics, raw responses, and testing your own code.
- [Design notes](doc/design.md) explain why it's built this way, with
  benchmarks, the HTTP/1.1 or HTTP/2 trade-off, and known limitations.
- [AGENTS.md](AGENTS.md) describes the package for AI coding agents.
- [TypeSafe docs](https://docs.typesafe.ai), and the official SDKs for
  [Python](https://docs.typesafe.ai/sdk/python) and
  [JavaScript](https://docs.typesafe.ai/sdk/javascript).

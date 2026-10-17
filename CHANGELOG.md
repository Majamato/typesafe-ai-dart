## 0.2.0-dev.1

A prerelease with TypeSafe's experimental Jev 1.14 "Danger Zone" features.
`^0.1.0` never resolves to it; depend on `^0.2.0-dev.1` to try it.

- **Breaking:** `JudgementType` gains `box`, and the sealed `Answer` and
  `Question` gain `BoxAnswer` and `Box`. An exhaustive `switch` over any of
  them needs a new case. A request without images still sends the same
  bytes and headers as 0.1.0.
- **Experimental**, in `package:typesafe_ai_dart/experimental.dart`:
  - `Image`: PNG or JPEG images anywhere a request takes text (`state`,
    `instructions`, criteria). A request with images is sent as
    `multipart/form-data`, each image once. An image in `extra`, where
    the API never looks, fails with an `ArgumentError`.
  - `TextWithImages`, for an image inside a sentence.
  - `Box` questions and `BoxAnswer`: the edges of a box around something
    in an image. They need `jev-preview` or `jev-1.14.0`.
  - `DangerZone.images` and `DangerZone.longContext`, set on the client
    (`dangerZone:`) or per call (`RequestOptions.dangerZone`), which send
    the `TypeSafe-Danger-Zone-*` headers. A request with an image or a Box
    fails with an `ArgumentError` before sending unless images are on.
- `SystemOneRequest.contentType`: `application/json`, or multipart when the
  request has images.
- An API error whose body has an `error_type` code but no message now uses
  the code as its message, instead of `HTTP <status>`. A request over the
  context length, which images make easier to reach, now fails with a
  `BadRequestException` saying `max_tokens_exceeded`. Errors that already
  had a message keep it.

## 0.1.1

- README.md and AGENTS.md point to the experimental 0.2.0 prereleases,
  which add images and `Box` questions from TypeSafe's Jev 1.14. No code
  changes.

## 0.1.0

- Initial release.

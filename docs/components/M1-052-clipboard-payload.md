# M1-052 ClipboardPayload and UTF-8 Text Codec

## Outcome

`KVMContracts` now carries the V1 clipboard value rules that frozen contract
C-007 requires: plain text is UTF-8 only, size and encoding failures are
explicit and typed, and no failure path can carry clipboard content. The
behaviour is pure value logic. It introduces no pasteboard access, no wire
format, no hashing, no transport, and no Barrier or platform semantics.

## What this Issue does and does not own

`ClipboardPayload` itself was frozen by M1-013 and lives in `KVMEvent.swift`.
M1-052 does not move, duplicate, or restructure it; it adds the codec and the
size-validation behaviour alongside it in a new file, so the M1-013 coding
shape and `KVMEvent.clipboard` remain byte-for-byte unchanged.

Deliberately not introduced here:

- a default, minimum, or global maximum clipboard size;
- content hashing or hash verification, even though `ClipboardPayload` carries
  a `contentHash` field;
- a pasteboard representation or type-negotiation enum;
- loop detection, transaction sequencing, or origin policy;
- any wire encoding, frame, or Barrier clipboard message.

Each of those belongs to a later Issue. Adding any of them here would either
guess at a frozen value or create public API this Issue has no contract for.

## Caller-supplied byte limit

`ClipboardByteLimit` is a `Hashable`, `Sendable` wrapper over a strictly
positive `Int` byte count. It has one failable initializer, which returns
`nil` for zero, negative, and `Int.min` inputs.

C-007 freezes that clipboard content is bounded. It does not freeze a number.
A limit depends on pasteboard behaviour, transport framing, and configuration
that no Issue has produced evidence for yet, so M1-052 takes the limit from
the caller on every call instead of inventing a constant that every later
Issue would be bound to.

Rejection is a `nil` initializer result rather than a thrown error on purpose.
The frozen `ClipboardErrorCode` allowlist is `unsupportedType`, `invalidUTF8`,
`oversized`, and `loopRejected`. None of them describes a misconfigured limit,
and M1-052 must not extend a frozen allowlist, so the type makes the invalid
state unrepresentable instead. A validated `ClipboardByteLimit` therefore
cannot reach the codec in an invalid state at all.

## Codec

`ClipboardTextCodec` is a caseless enum with two pure static functions.

`encode(_:limit:)` measures `text.utf8.count` and rejects an oversized value
before producing any buffer, then returns the UTF-8 bytes.

`decode(_:limit:)` runs two checks in a fixed order:

1. `data.count` against the limit. Oversized input is rejected here, before any
   decoding or allocation, which is the Architecture Guardrails requirement
   that unknown or oversize input is bounded before allocation. An input that
   is both oversized and malformed is therefore reported as `oversized`, and a
   test pins that ordering rather than leaving it incidental.
2. Well-formedness, using `Unicode.UTF8.ForwardParser`. Overlong encodings,
   surrogate code points, scalars above U+10FFFF, truncated sequences, and
   stray continuation bytes are all rejected as `invalidUTF8`.

Only then are the bytes converted with `String(decoding:as:)`, which cannot
lose or repair anything because the bytes are already known to be well formed.

Malformed input is never repaired into U+FFFD. Silent repair would turn a
detectable encoding failure into a wrong-content success.

The decoder is byte-faithful, and this is a real constraint rather than a
stylistic one. `String(data:encoding:.utf8)` silently strips a leading U+FEFF,
so a decode/encode cycle through it loses three bytes and cannot be used as
half of a lossless codec. `String(validating:as:)` is strict and faithful but
is only available from macOS 15, above this package's macOS 14 deployment
target, so the parser-based check is used instead. A test asserts exact byte
preservation for a BOM-prefixed input, an already-present U+FFFD, an embedded
NUL, and the maximum scalar U+10FFFF.

`decode` accepts a `Data` slice with a non-zero start index without
misreading or trapping; a test pins both the success and the oversized path
for a slice.

## Payload validation

`ClipboardPayload.utf8ByteCount` reports size in UTF-8 bytes, and
`validate(against:)` enforces a caller-supplied limit against that count.
Character count is not a size: a single emoji is one `Character` and four
bytes, and a test pins the distinction.

Only size is validated. `utf8Text` is a Swift `String` and is therefore always
well-formed Unicode, so there is no encoding check to perform on it, and
`contentHash` is not verified because hashing is not part of this Issue.

## Failure taxonomy and privacy

Both failures are the frozen M1-015 `CoreError` value with a clipboard code,
`warning` severity, `never` retry, and `notRequired` cleanup, and no
underlying diagnostic code.

`never` is the correct retry disposition because both failures are terminal
and content-caused: the same input can only fail the same way, so an automatic
retry would be a busy loop. `notRequired` cleanup is correct because both
checks run before anything is acquired; the codec owns no task, buffer,
connection, pasteboard handle, or input state, so there is nothing to release
on any path.

Only `oversized` and `invalidUTF8` can be produced. `unsupportedType` belongs
to the platform backend that reads pasteboard types, and `loopRejected` to the
loop-suppression Issue. This codec has no representation parameter, so there
is no way for a caller to request a non-UTF-8 type and no `unsupportedType`
condition for it to report.

Privacy holds structurally rather than by redaction. `CoreError` has no
message, description, payload, or free-text field, so a clipboard failure has
nowhere to carry text or a hash even accidentally. The codec performs no
logging at all. A test renders every failure through `String(describing:)`,
`String(reflecting:)`, and JSON encoding and asserts that a distinctive
synthetic probe text, its hash sentinel, and its non-ASCII scalars appear in
none of them.

## Determinism, concurrency, and cleanup

Every declaration is an immutable value or a pure static function. There is no
stored mutable state, clock, timer, sleep, retry, randomness, I/O, or
concurrency anywhere in the file, so repeated calls are identical and a
failure leaves nothing behind for a later call to observe. A test asserts that
success and failure both repeat exactly and that a failure does not perturb a
subsequent success.

The Issue template asks for a cancel/cleanup/idempotency test "if there is
async, state, or resource". There is none of the three here, so no such test
was written. Writing one would have meant inventing an async wrapper purely to
have something to cancel, which would add untested public API and prove
nothing. Purity and the absence of owned resources are asserted directly
instead.

## Validation coverage

Nineteen tests cover: UTF-8 round trip across 1-, 2-, 3-, and 4-byte
sequences; exact byte-preservation for BOM, U+FFFD, NUL, and U+10FFFF inputs;
`Data` slices with a non-zero start index; content exactly at the limit; one
byte over the limit with multibyte content, in both directions; bytes counted
rather than characters; a one-byte limit; `Int.max` without overflow; empty
content; every non-positive limit rejected; twelve malformed UTF-8 shapes;
oversize enforced before decoding; payload size validation; the frozen
taxonomy and dispositions; failure renderings free of text and hash; the
unchanged M1-013 `ClipboardPayload` and `KVMEvent` coding shape; and codec
purity.

## Architecture and scope boundaries

No Barrier or native message code, socket or network object, pasteboard or OS
type, UI state, logging sink, timer, retry loop, or trust decision is
introduced. `KVMEvent.swift`, `CoreErrors.swift`, and every other existing
file are unmodified.

## Rollback

Delete `Packages/KVMContracts/Sources/KVMContracts/ClipboardPayload.swift`,
its test file, this document, and `evidence/issues/M1-052/`, or revert the
M1-052 commits. Nothing else depends on the new declarations yet, the frozen
M1-013 and M1-015 surfaces are untouched, and no wire format, persisted state,
migration, trust state, or platform input state is involved, so rollback needs
no cleanup.

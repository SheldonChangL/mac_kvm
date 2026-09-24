# M1-054 Clipboard Loop Guard and Size Limit

## Outcome

`KVMCore` now has `ClipboardLoopGuard`, a caller-owned value that decides
whether a clipboard payload may be sent to a peer or applied locally. It
rejects oversized payloads as `clipboard.oversized` and rejects payloads that
would travel back toward their origin, replay a transaction, or repeat
already-synchronized content as `clipboard.loopRejected`. It consumes only the
frozen M1-013 `ClipboardPayload`, the M1-052 `ClipboardByteLimit`, and the
M1-015 `CoreError`.

No public contract is added or changed. Every new declaration is `package` or
narrower. `ClipboardPayload`, `ClipboardByteLimit`, `ClipboardErrorCode`, and
every other existing file are unmodified.

## API

Package surface, in `ClipboardLoopGuard.swift`:

| Declaration | Purpose |
| --- | --- |
| `package struct ClipboardLoopGuard: Equatable, Sendable` | the guard state |
| `package init()` | a guard that remembers nothing |
| `package mutating func admitOutbound(_:limit:) throws(CoreError)` | admit a payload about to be sent |
| `package mutating func admitInbound(_:limit:) throws(CoreError)` | admit a received payload before it is applied |
| `package mutating func reset()` | forget the remembered payload; idempotent |

`description`, `debugDescription`, and `customMirror` are redacted; see
Privacy.

## Design

The guard is a value, not an actor, cache, or service. It remembers exactly one
identity: the `transactionID` and `contentHash` of the last payload it admitted
in either direction. It never stores `utf8Text`.

This is the smallest state that suppresses the echo loop without inventing
policy. A window of several remembered identities would need a capacity, and
an expiry would need a duration; the frozen sources specify neither, so both
would be invented constants. One slot has no capacity to choose, and it is
replaced rather than grown, so retained state is bounded by construction.

Admission checks run in a fixed order, and the first failing check decides:

1. **Size.** `utf8ByteCount` above the caller-supplied `ClipboardByteLimit` is
   `clipboard.oversized`. Size is checked first so that a payload that is both
   oversized and a loop is reported as oversized, and a test pins the order.
   Size is UTF-8 bytes, never characters, and exactly-at-limit is accepted.
2. **Origin.** `admitOutbound` requires `.local`; `admitInbound` requires
   `.remote`. A remote payload offered for sending would be sent back toward a
   peer, and a local-origin payload arriving from a peer is this machine's own
   content returning. Both are `clipboard.loopRejected`. Any remote device is
   accepted inbound; no per-device policy is introduced.
3. **Transaction.** A `transactionID` equal to the remembered one is a replay
   or echo of that transaction, even if its content differs, and is
   `clipboard.loopRejected`.
4. **Hash.** A `contentHash` equal to the remembered one carries content that
   is already synchronized and is `clipboard.loopRejected`. This is what stops
   the main loop: applying an inbound payload changes the local pasteboard,
   the caller observes that as a new local payload with a fresh transaction but
   the same hash, and `admitOutbound` refuses to send it back. The same check
   stops a peer from echoing our outbound content under a new transaction.

Only an admitted payload replaces the remembered identity. Every rejection
leaves the state unchanged, so a rejected payload cannot disturb later
decisions.

The same content is admitted again once different content has been admitted in
between, so copying A, then B, then A again sends A twice, as the user expects.

### Intended use

The single owner of a clipboard link, such as a session actor, keeps one
`ClipboardLoopGuard` and:

- calls `admitOutbound` before sending a locally observed payload;
- calls `admitInbound` before applying a received payload to the pasteboard;
- calls `reset()` if applying an admitted inbound payload fails, so the
  unapplied content is not treated as synchronized, and whenever the owner
  decides the link's clipboard history no longer applies.

When to reset on disconnect or reconnect is left to that owner. No session or
lifecycle Issue has frozen that choice, so the guard does not make it.

## Content hash

`ClipboardPayload.contentHash` is caller-provided and no hash algorithm is
frozen in the sources. The guard therefore treats it as opaque identity
metadata and compares it for exact `String` equality with no normalization. It
does not compute, verify, or freeze an algorithm, and it does not change
`ClipboardPayload`.

Integrity and trust limitations:

- The hash is not checked against `utf8Text`. A peer that sends a wrong hash
  can make new content look like a duplicate, which suppresses that transfer,
  or make a duplicate look new, which lets one extra echo through before the
  next check sees the remembered hash. It cannot bypass the origin or size
  checks.
- Loop suppression is only as good as hash consistency. The callers that build
  outbound and inbound payloads must derive the hash the same way for the same
  text, or an applied inbound payload will not match its local echo.
- The hash is not a security property. Authenticity and integrity belong to the
  trust and transport layers, not this guard.
- The remembered hash string's length is whatever the caller supplied; the
  guard bounds the number of remembered identities, not the hash length.

## Failure taxonomy

Both rejections are exactly the value the M1-052 codec produces for clipboard
failures: the clipboard code, `warning` severity, `never` retry, and
`notRequired` cleanup, with no underlying diagnostic code. A test asserts the
oversized value equals the one `ClipboardTextCodec.encode` throws.

`never` is correct because the same payload against the same state is rejected
the same way every time; a later, different payload is a new admission, not a
retry. `notRequired` is correct because every check runs before anything is
acquired, and the guard owns no resource.

Only `oversized` and `loopRejected` are produced. `unsupportedType` and
`invalidUTF8` belong to the platform backend and the codec.

## Privacy

- The guard performs no logging and emits no diagnostic event.
- `CoreError` has no free-text field, so a rejection cannot carry text, a hash,
  a byte count, a transaction ID, or a device ID. A test renders both
  rejections through `String(describing:)`, `String(reflecting:)`,
  interpolation, and JSON, asserts no probe text, non-ASCII probe scalar, hash
  sentinel, transaction UUID, device UUID, or byte count appears, and asserts
  the JSON has exactly the four taxonomy keys.
- The guard itself remembers a transaction ID and hash, so its `description`,
  `debugDescription`, interpolation, `dump`, and reflection are redacted and
  its mirror has no children. A test checks each rendering.

## Determinism, concurrency, and cleanup

The file contains no clock, timer, sleep, retry, randomness, I/O, lock, task,
global mutable state, protocol message, network, pasteboard, or UI code. Every
decision is a pure function of the current state and the payload, so replaying
the same sequence yields the same results and the same final state; a test
asserts this over an eight-step script covering every rule.

`ClipboardLoopGuard` is a `Sendable` value. Concurrency safety comes from
ownership rather than synchronization: each owner mutates its own copy, and
copies are independent. Tests run the guard in `Task.detached`, run sixteen
independent owners concurrently in a task group with identical results, and
send sixteen concurrent same-content payloads through one owning actor to show
exactly one is admitted and fifteen are rejected.

There is nothing asynchronous to cancel and no resource to release. Cleanup is
`reset()`, which is idempotent and restores the initial state; tests cover
repeated resets on empty and non-empty state, reset followed by re-admission of
the same payload, and state being unchanged by every rejection kind.

## Validation coverage

Tests cover: first outbound and inbound admission; successive distinct payloads
in both directions; content admitted again after other content; exactly at the
limit and one byte over in both directions; bytes counted rather than
characters; empty text; oversized equality with M1-052; size checked before
origin and identity; remote payloads never sent back; local-origin inbound
rejected; any remote device accepted; local echo of an applied inbound payload
suppressed; peer echo by transaction and by hash suppressed; a repeated
transaction with new content rejected; a repeated hash under a new transaction
rejected; the exact same payload rejected twice; duplicate content from another
device suppressed; hashes compared as opaque exact values; only the last
identity remembered; rejection leaves state unchanged; reset and its
idempotency; value independence of copies; determinism; `Sendable`; detached,
task-group, and actor-owned concurrency; and privacy of rejections and of the
guard's renderings.

## Verification status

The author session had no command execution, so none of the Required
Commands have been run by the author. The files were checked only by static
review: line length, import allowlist, and expected results traced by hand.
Reviewer validation must run the Required Commands plus
`make code-quality-check` and `make docs-check`.

`KVMCore` and `KVMCoreTests` are targets of the repository-root manifest. The
Codex root reviewer ran the exact command `swift test --package-path
Packages/KVMCore` outside the managed sandbox. It resolved the repository-root
`Package.swift` and passed: 47 passed, 0 failures, 1 system opt-in skipped.

## Known limitations and risks

- **One remembered identity.** A delayed echo of a superseded transaction, for
  example our payload A echoed after we already sent B, is not detected and
  would be admitted. Detecting it needs a history window whose size the frozen
  sources do not specify.
- **Opaque, unverified hash.** See Content hash.
- **Duplicate suppression across devices.** Content identical to the remembered
  content is rejected even when it comes from a different remote device, since
  applying it would change nothing locally.
- **Reset policy is the caller's.** A missed `reset()` after a failed apply
  leaves unapplied content treated as synchronized until different content is
  admitted.
- **`warning` severity for expected suppression.** Loop rejection is routine,
  but the M1-052 clipboard severity is reused rather than inventing a
  different one; a caller that logs must use allowlisted metadata only.

## Scope exclusions

- No protocol message, wire format, networking, pasteboard access, or UI.
- No hash computation, algorithm, or verification.
- No default, minimum, or maximum byte limit.
- No history window, capacity, expiry, timer, or retry.
- No change to any frozen contract or existing file.

## Rollback

Remove or revert the three M1-054 Exact Files:
`Packages/KVMCore/Sources/KVMCore/ClipboardLoopGuard.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ClipboardLoopGuardTests.swift`, and this
document. Nothing else depends on them, and there is no persisted state,
migration, wire format, or runtime resource to clean up.

# M1-030 Barrier Handshake Fragmentation, Timeout and Mismatch Tests

## Outcome

`BarrierHandshakeTestsTests.swift` adds 11 Swift Testing tests that drive the M1-029
`BarrierClientHandshake` through the M1-022 `BarrierFrameReassembler`, the way the
transport owner hands stream bytes to the handshake. They cover every byte-boundary
fragmentation of the frozen server hello frame, the caller-injected timeout and
cancellation at every byte boundary, and the fixed unsupported-version error.

M1-030 is test and documentation only. No production Swift, `Package.swift`, fixture,
ADR, wire byte, public API or contract is changed.

## System under test and frozen inputs

| Input | Source | Used as |
|---|---|---|
| `BarrierClientHandshake`, `BarrierClientHandshakeError` | M1-029, `docs/components/M1-029-barrier-client-handshake.md` | System under test; module-internal, reached with `@testable import` |
| `BarrierFrameReassembler` | M1-022, `docs/components/M1-022-barrier-frame-reassembler.md` | The stream-to-payload hand-off in front of the handshake |
| Server hello frame `00 00 00 0B 42 61 72 72 69 65 72 00 01 00 06` | `docs/adr/M1-025-barrier-client-wire-contract.md` (`BARRIER-EVID-0002` run 0) | The 15-byte input that is fragmented |
| HelloBack frame for `m1-client` (28 bytes) | `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` (`BARRIER-EVID-0004`) | The only acceptable output |
| `.serverHelloRejected(.unsupportedVersion)` | M1-027 `BarrierServerHelloError` through M1-029 | The fixed unsupported-version error |
| `.timedOut`, `.cancelled` | M1-029 `BarrierClientHandshakeError` | The fixed timeout and cancellation errors |

The golden bytes are copied by hand from the same evidence that M1-027, M1-028 and
M1-029 use. No byte is inferred.

## Test cases

| Test | Covers |
|---|---|
| `fragmentedHelloCompletesTheHandshakeForEverySplitOfTheFrame` | Happy path for all 2^14 = 16384 fragmentations of the 15-byte frame (every subset of the 14 inner byte boundaries, from one chunk to one-byte chunks). Before the last chunk: no frame, no error, state `awaitHello`. After it: exactly the golden HelloBack, `sendHelloBack`, nothing left buffered, then `protocolConnected` |
| `oneByteChunksWithEmptyAppendsKeepTheHandshakeWaitingUntilTheLastByte` | One-byte chunks with a zero-length append before each byte; per-byte buffered count and `awaitHello` until byte 15 |
| `helloAtExactlyThePayloadLimitCompletesAndOneBelowNeverReachesTheHandshake` | Boundary: reassembler limit 11 (exact hello length) connects; limit 10 throws `oversize(limit: 10)`, the handshake receives nothing and ends only through the timeout signal |
| `unsupportedVersionFailsWithTheFixedErrorAtEveryFragmentationBoundary` | Every one-byte change of every version byte (4 × 255) split at each of the 14 inner boundaries: 14280 runs, each exactly one `.serverHelloRejected(.unsupportedVersion)`, no frame, state latched |
| `unsupportedMultiByteVersionsFailWithTheSameFixedError` | Neighbouring and extreme multi-byte versions (`00 01 00 05`, `00 01 00 07`, `00 02 00 06`, `00 00 00 06`, `00 00 00 00`, `FF FF FF FF`, `06 00 01 00`) give the same error; the error case carries no associated value |
| `unsupportedVersionDoesNotProceedForAnyLaterEvent` | Version is rejected before an also-invalid screen name; a later supported hello, `helloBackSent()`, timeout and cancel cannot revive or overwrite the rejection |
| `timeoutAtEveryByteBoundaryEndsWithTimedOutAndNoLaterOutput` | Timeout after 0 to 14 delivered bytes; repeated timeout and a later cancel keep `.timedOut`; the late rest of the frame yields `.timedOut` and no HelloBack; `helloBackSent()` and `start()` rethrow `.timedOut` |
| `timeoutAfterTheHelloButBeforeHelloBackIsSentNeverConnects` | Timeout in `sendHelloBack` (byte 15 delivered, frame not yet reported as written) never reaches `protocolConnected` |
| `cancelAtEveryByteBoundaryEndsWithCancelledAndNoLaterOutput` | Cancel after 0 to 15 delivered bytes; repeated cancel and a later timeout keep `.cancelled`; no later frame |
| `timeoutAndCancelLeaveNoRetainedStringOrReferenceAtAnyByteBoundary` | Cleanup: after timeout or cancel at every boundary the handshake's reflected value graph holds no `String` (the screen name) and no reference-typed value. A positive control shows the check detects the screen name of a waiting handshake |
| `lateTimeoutAfterAFragmentedHandshakeCompletesKeepsProtocolConnected` | Idempotency after completion: a fragmented handshake that reached `protocolConnected` ignores late timeout and cancel and retains nothing |

## Deterministic timeout and cleanup method

The M1-029 handshake has no clock: timeout and cancellation are non-throwing signals
(`timeOut()`, `cancel()`) that the caller injects. The tests inject those signals at
an exact byte position, so the moment of the timeout is fixed by the test, not by a
clock, a scheduler or wall time. No test uses `sleep`, a retry, a polling loop, a
`Task`, `async` code or a timing tolerance.

The M1-020 harness (`Tools/async-harness/async-harness.py`) is Python tooling for
cooperative-scheduler scenarios and is not linkable into a Swift test target. The
Swift `TestKVMClock` (M1-018) lives in `KVMContracts`, which is not a direct dependency
of the `BarrierCompatibilityTests` target, and the handshake has no clock to replace.
Adding either would require changing `Package.swift` or production code, which is
outside the Exact Files. The injected-signal pattern is the deterministic method
M1-029 already established for this type and satisfies C-004 (no arbitrary sleep).

"No leaked task" is established in two parts:

- Structurally: `BarrierClientHandshake.swift` contains no `Task`, `async`, `await`,
  timer, dispatch queue, thread or clock (`grep` recorded in the evidence). The handshake
  is a `Sendable` value type whose API is synchronous, so it cannot start or own work
  that outlives a call.
- Behaviourally: after timeout or cancel at every byte boundary, later bytes produce no
  HelloBack, every later throwing event rethrows the latched error, and the reflected
  value graph contains no screen name and no reference-typed value.

## Test-first outcome

The tests were written before any other M1-030 file and run against the unchanged
M1-029 source. All 11 passed on the first run: M1-029 already implements the required
behavior. No RED phase is claimed.

To show that the tests can fail, three single-line mutants of
`BarrierClientHandshake.swift` were run in a throw-away copy of the packages outside
the repository (the repository source was not edited):

| Mutant | Failing M1-030 tests |
|---|---|
| Unsupported version is ignored and the handshake proceeds | 3 (all unsupported-version tests) |
| `timeOut()` and `cancel()` are ignored in `awaitHello` | 4 (timeout, cancel, cleanup and the payload-limit boundary test) |
| Terminal signals keep the screen name | 1 (the cleanup test) |

## Architecture boundary

- The test file lives in `BarrierCompatibilityTests` and imports only `Testing` and
  `BarrierCompatibility`. No KVMCore, KVMContracts, platform, UI or networking import.
- Barrier-specific types stay in `BarrierCompatibility` (Frozen Decision 4); this is
  why the M1-030-SCOPE-001 correction moved these tests out of KVMCore.

## Security and privacy

- Tests use only the synthetic `m1-client` name and frozen evidence bytes; no host
  name, user name, endpoint, typed text, clipboard data or secret.
- The tests add no log site.

## Non-claims

- No transport, socket, TLS, trust, timer, reconnect or session-adapter behavior is
  tested; those are owned elsewhere.
- No claim about real Barrier interoperability beyond the frozen evidence bytes.
- No Windows execution or compatibility claim. Tests ran on macOS arm64 only.
- No version negotiation, downgrade or fallback exists or is tested.
- Messages after HelloBack are not frozen and are not tested.

## Validation

Run from the repository root:

```bash
swift test --package-path Packages/BarrierCompatibility --filter BarrierHandshakeTestsTests
swift test --package-path Packages/BarrierCompatibility
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
python3 Tools/Backlog/validate_package.py
make architecture-check
make docs-check
```

Results, timestamps and environment notes are in `evidence/issues/M1-030/`.

## Known limitations

- Golden bytes are copied by hand, as in M1-021 to M1-029.
- Fragmentation is exhaustive for the single 15-byte supported hello frame. Unsupported
  versions are split at every single boundary, not every multi-boundary subset.
- "No leaked task" for this synchronous value type rests on the source grep plus the
  behavioural checks; there is no runtime task registry to inspect.
- The cleanup check uses `Mirror`, which reflects stored values; it is the same
  technique M1-029 uses for screen-name release.

## Rollback

Delete `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierHandshakeTestsTests.swift`,
this document and `evidence/issues/M1-030/`, or revert the M1-030 commit. No production
code, runtime resource, persisted data or migration is involved.

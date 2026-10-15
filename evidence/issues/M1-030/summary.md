# M1-030 Evidence Summary — Barrier Handshake Fragmentation, Timeout and Mismatch Tests

GitHub Issue: #53 (canonical M1-030, corrected by M1-030-SCOPE-001 / #317).

Base commit: `3a75589acb7028fb8148c85b62c508bcc1fd3368` (PR #318 merged)

Branch: `codex/m1-030-barrier-handshake-tests`

Authorship: implementation author Claude Code (--model opus); independent review is
assigned to a separate Codex executor and is not recorded here.

Status: **author-verified; reviewer rerun of SwiftPM without `--disable-sandbox`,
`xcodebuild` and `make verify` is required.**

## Preconditions

- M1-020 (#32) and M1-029 (#47) are closed and merged; their sources and evidence are
  readable (`Tools/async-harness/`, `docs/tooling/M1-020-async-harness.md`,
  `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientHandshake.swift`,
  `evidence/issues/M1-029/`).
- The hello frame is frozen by `docs/adr/M1-025-barrier-client-wire-contract.md` and the
  HelloBack frame by `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md`.
- M1-030 adds no public contract; `contract_refs` is empty.

## Changed files

Exact Files:

- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierHandshakeTestsTests.swift`
  (new, 11 Swift Testing tests)
- `docs/components/M1-030-barrier-handshake-tests.md` (new)

Evidence (authorized by Expected Evidence/Deliverables):

- `evidence/issues/M1-030/summary.md`
- `evidence/issues/M1-030/commands.json`
- `evidence/issues/M1-030/tests/barrier-handshake-tests.json`
- `evidence/issues/M1-030/tests/swift-testing-xunit-swift-testing.xml`

No production Swift, `Package.swift`, fixture, ADR, backlog source, manifest,
traceability file or later Issue was changed.

## Test-first outcome

The test file was written first and run against the unchanged M1-029 source:
**all 11 tests passed on the first run.** M1-029 already implements the behavior M1-030
requires, so no RED phase is claimed.

To show the tests are not vacuous, three one-line mutants of
`BarrierClientHandshake.swift` were run in a throw-away copy outside the repository
(the repository source was never edited):

| Mutant | Result |
|---|---|
| Unsupported version ignored, handshake proceeds | 3 tests failed (42858 issues) |
| `timeOut()`/`cancel()` ignored in `awaitHello` | 4 tests failed (196 issues) |
| Terminal signals keep the screen name | 1 test failed (30 issues) |

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Every byte-boundary fragmentation | `fragmentedHelloCompletesTheHandshakeForEverySplitOfTheFrame`: all 16384 subsets of the 14 inner boundaries of the 15-byte hello frame, including one chunk and one-byte chunks; `oneByteChunksWithEmptyAppendsKeepTheHandshakeWaitingUntilTheLastByte` |
| Timeout with no leaked task | `timeoutAtEveryByteBoundaryEndsWithTimedOutAndNoLaterOutput` (bytes 0 to 14), `timeoutAfterTheHelloButBeforeHelloBackIsSentNeverConnects`, `timeoutAndCancelLeaveNoRetainedStringOrReferenceAtAnyByteBoundary`; the source grep in `commands.json` shows the handshake has no task, async code, timer, queue, thread or clock |
| Unsupported version has a fixed error code | `unsupportedVersionFailsWithTheFixedErrorAtEveryFragmentationBoundary` (14280 runs), `unsupportedMultiByteVersionsFailWithTheSameFixedError`, `unsupportedVersionDoesNotProceedForAnyLaterEvent`: always `.serverHelloRejected(.unsupportedVersion)`, no associated value, no HelloBack |
| Happy-path test | `fragmentedHelloCompletesTheHandshakeForEverySplitOfTheFrame`, `oneByteChunksWithEmptyAppendsKeepTheHandshakeWaitingUntilTheLastByte`, `lateTimeoutAfterAFragmentedHandshakeCompletesKeepsProtocolConnected` |
| Boundary/limit test | `helloAtExactlyThePayloadLimitCompletesAndOneBelowNeverReachesTheHandshake`; zero-length appends; timeout/cancel at byte 0 and the last byte |
| Invalid input/failure test | The three unsupported-version tests; reassembler `oversize` hand-off |
| Cancel/cleanup/idempotency test | `cancelAtEveryByteBoundaryEndsWithCancelledAndNoLaterOutput`, `timeoutAndCancelLeaveNoRetainedStringOrReferenceAtAnyByteBoundary`, repeated/mixed signals keep the first reason, `lateTimeoutAfterAFragmentedHandshakeCompletesKeepsProtocolConnected` |
| Public behavior consistent with CONTRACT_CATALOG/frozen ADR, no implied API | Tests use only the M1-029/M1-022 module-internal API through `@testable import`; no source or contract change; expected bytes are the frozen evidence bytes |
| Architecture checker, lint, build, unit tests, no new warnings | `make architecture-check` pass; `swift format lint --strict` pass; SwiftPM 151/151 pass, also with `-warnings-as-errors`; `xcodebuild` not verified in this environment (see below) |
| No sensitive logging | No log site added; only the synthetic `m1-client` name and frozen evidence bytes are used |

## Deterministic method

Timeout and cancellation are M1-029's caller-injected signals, injected at an exact byte
position. No sleep, retry, polling, `Task`, `async` code or timing tolerance is used. The
M1-020 Python harness and the M1-018 `TestKVMClock` are not applicable: the handshake has
no clock, and wiring either into `BarrierCompatibilityTests` would require changes
outside the Exact Files. Details are in
`docs/components/M1-030-barrier-handshake-tests.md`.

## Validation

Exact commands, timestamps and exit codes are in `commands.json`.

- `swift test ... --filter BarrierHandshakeTestsTests`: plain run failed with the
  SwiftPM nested-sandbox error; with `--disable-sandbox` 11/11 passed.
- `swift test --disable-sandbox --package-path Packages/BarrierCompatibility`: 151/151
  passed (140 existing + 11 new); also passed with `-Xswiftc -warnings-as-errors`.
- `swift format lint --strict` on the new test file: pass, no output.
- `python3 Tools/Backlog/validate_package.py`: `PACKAGE OK: 217 issues, 5 milestones, 17 epics`.
- `make architecture-check`: `architecture check OK`.
- `make docs-check`: `docs check OK` (tracked files); see `commands.json` for the
  direct check of the new files.
- `xcodebuild ... build`: **not verified.** Exit 66, `'MacKVM.xcworkspace' is not a
  workspace file`, after CoreSimulator XPC and log-file `Operation not permitted`
  errors from the author sandbox. The workspace is unchanged from the base commit and
  no M1-030 file is in the app target.
- `make verify`: manifest-validation, docs-check and architecture-check passed;
  code-quality failed on the SwiftPM nested-sandbox error and later gates did not run.
  The code-quality SwiftPM step passed when rerun with `--disable-sandbox`.

## Scope and hygiene

- Only the files listed above were created. `git status` shows no modified tracked file.
- `MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` were not read, modified or staged.
- No secret, credential, token, private key, endpoint, typed text, clipboard data or
  personal data is recorded.
- No Windows execution or compatibility claim.

## Known limitations

- Golden bytes are copied by hand, as in M1-021 to M1-029.
- Unsupported versions are split at every single boundary, not every subset of
  boundaries; the supported hello is covered exhaustively.
- "No leaked task" for a synchronous value type rests on the source grep plus the
  behavioural and `Mirror` checks; there is no runtime task registry to inspect.
- `xcodebuild` and full `make verify` were not verified in the author environment.

## Follow-ups

- None required by M1-030. The Barrier session adapter that owns transport and timer
  wiring remains a separate Issue.

## Rollback

Delete the test file, the component doc and `evidence/issues/M1-030/`, or revert the
M1-030 commit. No production code, runtime resource, persisted data or migration is
involved.

## Reviewer requirements

Tier A, risk high. A reviewer must rerun outside the author sandbox:

- `swift test --package-path Packages/BarrierCompatibility` (without `--disable-sandbox`);
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`;
- `python3 Tools/Backlog/validate_package.py` and `make architecture-check`;
- `make verify`, and `make docs-check` plus `git diff --cached --check` after staging.

No model may merge autonomously.

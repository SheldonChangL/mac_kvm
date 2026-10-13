# M1-029 Evidence Summary — Barrier Client Handshake State Machine

Base commit: `6d99333` (M1-028 HelloBack writer merged)

Branch: `codex/m1-029-barrier-client-handshake`

Status: **implemented; reviewer SwiftPM tests, `xcodebuild`, package, docs and
architecture gates pass.**

Implementation commit: `2a2502388438ab39847eca86aca2f8af7b26e058`

## Preconditions

- M1-016 (`KVMProtocolSession` interface), M1-027 (server hello validation) and
  M1-028 (HelloBack writer) are merged; M1-022 (frame reassembler) is merged.
- The server hello payload is frozen by `docs/adr/M1-025-barrier-client-wire-contract.md`
  (`BARRIER-EVID-0002` run 0) and the HelloBack frame by
  `docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md` (`BARRIER-EVID-0004`).
- Messages after HelloBack are not frozen; M1-029 does not handle them.

## Deliverables (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierClientHandshake.swift`:
  module-internal `BarrierClientHandshake` (`start()`, `receiveServerHello(payload:)`,
  `helloBackSent()`, `timeOut()`, `cancel()`, read-only `state`), its `State`
  (`connected`, `awaitHello`, `sendHelloBack`, `protocolConnected`, `failed`) and typed
  `BarrierClientHandshakeError` (`serverHelloRejected`, `helloBackRejected`, `timedOut`,
  `cancelled`, `outOfOrderEvent`, `alreadyConnected`).
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierClientHandshakeTests.swift`:
  26 Swift Testing tests.
- `docs/components/M1-029-barrier-client-handshake.md`.
- `evidence/issues/M1-029/` (this package: `summary.md`, `commands.json`,
  `tests/barrier-client-handshake-tests.json`).

No `Package.swift`, KVMContracts, KVMCore, M1-021/022/026/027/028 source, Tools,
register, ADR, fixture or other file was changed. The untracked
`MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` in the working tree are unrelated to
M1-029 and are not part of this change.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Focus items have locatable implementation/test | `connected → awaitHello → sendHelloBack → protocolConnected`: `handshakeProgressesThroughEveryStateToProtocolConnected`; timeout: `handshakeTimesOutFromEveryPendingState`; cancel: `handshakeCancelsFromEveryPendingState`; version mismatch: `handshakeFailsClosedOnUnsupportedVersion`; no UI: the module imports no UI framework |
| Happy path test | `handshakeProgressesThroughEveryStateToProtocolConnected`, `handshakeEmitsGoldenHelloBackFrameForM1xExactly`, `handshakeEmitsSameBytesAsTheHelloBackWriter` |
| Boundary/limit test | `handshakeAcceptsScreenNameAtExactlyTheConfiguredLimit`, `handshakeFailsForScreenNameOneByteOverTheConfiguredLimit`, `handshakeAcceptsSingleByteScreenNameAtMinimumLimit`; truncated payload at every length |
| Invalid input/failure test | `handshakeFailsClosedOnUnsupportedMarker`, `handshakeFailsClosedOnUnsupportedVersion`, `handshakeFailsClosedOnTruncatedHelloPayload`, `handshakeFailsClosedOnHelloWithTrailingBytes`, `handshakeFailsClosedOnInvalidScreenNames`, `handshakeValidatesServerHelloBeforeScreenName`, `handshakeRejectsHelloBeforeStart`, `handshakeRejectsOutOfOrderEvents`, `handshakeRejectsEventsAfterProtocolConnectedWithoutChangingState` |
| Cancel/cleanup/idempotency test | `handshakeCancelAndTimeoutAreIdempotentAndKeepTheFirstTerminalReason`, `handshakeFailureIsStickyForEveryLaterEvent`, `handshakeLateCancelAndTimeoutDoNotTearDownProtocolConnected`, `handshakeReleasesScreenNameOnEveryTerminalState`, `handshakeRunsAreDeterministic` |
| Golden/conformance bytes equal exactly | The returned HelloBack frame is compared byte-for-byte with the `BARRIER-EVID-0004` `m1-client` and `m1x` frames; hello input is the `BARRIER-EVID-0002` payload |
| Fragmentation/coalescing/truncation test | `handshakeAcceptsHelloReassembledFromByteByByteFragments`, `handshakeConsumesOnlyTheHelloFromCoalescedFrames`, `truncatedHelloFrameNeverReachesTheHandshakeAndTimeoutTerminates` (M1-022 hand-off) |
| Consistent with frozen ADR, no implied API | Internal access only; no new wire bytes, message code, version negotiation, default bound or public contract; frame identical to the M1-028 writer |
| No sensitive logging | No log site; `handshakeErrorsCarryOnlyAllowlistedMetadata` (only `Int` counts/limits in errors, no screen name in error or state description) and `handshakeReleasesScreenNameOnEveryTerminalState` |
| Architecture checker, lint, build, unit tests, no new warnings | SwiftPM tests pass (140/140, authoring and reviewer runs); `xcodebuild`, `swift format lint --strict`, `swift build --build-tests`, `validate_package.py`, `make architecture-check` and `make docs-check` pass |

## Tests and validation performed

All results are recorded in `commands.json`; the machine-readable test report is
`tests/barrier-client-handshake-tests.json`.

- Claude authoring run: plain `swift test --package-path Packages/BarrierCompatibility`
  failed only because SwiftPM cannot nest its sandbox inside the authoring session's
  sandbox; `swift test --disable-sandbox --package-path Packages/BarrierCompatibility`
  then passed, 140 tests (114 existing + 26 M1-029). `--disable-sandbox` does not
  change compilation or test selection.
- Codex reviewer rerun: `swift test --package-path Packages/BarrierCompatibility` —
  pass, 140 Swift Testing tests. Reviewer also regenerated raw xUnit at
  `tests/swift-testing-xunit-swift-testing.xml`.
- Evidence pass (this pass): `python3 Tools/Backlog/validate_package.py` — pass;
  `make architecture-check` — pass; `make docs-check` — pass (it scans tracked files
  only, so the untracked M1-029 Markdown/JSON files were also checked with the same
  docs-check rules directly); `git diff --no-index --check /dev/null <file>` for every
  untracked M1-029 file — no whitespace errors.
- Reviewer rerun: `swift format lint --strict --no-color-diagnostics` on both
  M1-029 Swift files — pass, no output.
- Reviewer rerun:
  `swift build --build-tests --package-path Packages/BarrierCompatibility` —
  pass, build complete.
- Reviewer rerun:
  `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`
  — pass, `** BUILD SUCCEEDED **`.
- Not run in this pass: `make verify` (not a Required Command for M1-029; PR CI
  will run repository gates).

## Known limitations

- Golden bytes are copied by hand into the tests, as in M1-021/M1-022/M1-026/M1-027/M1-028.
- The handshake does not conform to `KVMProtocolSession` and does not map its errors to
  `CoreError`/`DisconnectReason`; that belongs to the Barrier session adapter.
- Timeout and cancellation are caller-injected signals; the duration and clock are
  owned by the caller.
- No messages after HelloBack are handled; they are not frozen.
- No default screen-name bound is chosen; the caller configures the writer.
- Per-test status in the report is derived from the aggregate result, not from a raw
  per-case xUnit file.

## Follow-ups

1. M1-030 (handshake tests) and the Barrier session adapter consume
   `BarrierClientHandshake`, own transport/timer wiring and map errors into the
   M1-015/M1-016 taxonomy.
2. Optional: add `BarrierClientHandshakeTests` to the M1-023 evidence register
   consumer links if the register owner requires it.

## Rollback

Revert the M1-029 change (the two Swift files, the component doc and this evidence
directory). No runtime resource, persisted data or migration is involved, and no
production code consumes the state machine yet.

## Reviewer requirements

Completed:

- `swift test --package-path Packages/BarrierCompatibility` (without
  `--disable-sandbox`) — pass, 140 tests (Codex reviewer rerun).
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`
  — pass.
- `swift format lint --strict` on both M1-029 Swift files — pass.
- `swift build --build-tests --package-path Packages/BarrierCompatibility` —
  pass.
- `python3 Tools/Backlog/validate_package.py`, `make architecture-check` and
  `make docs-check` — pass.

Still required before PR merge:

- record the implementation commit hash in `commands.json`;
- the repository CI/PR checks after the PR is opened. No model may merge
  autonomously (tier B).

Final staged-file reviewer gate completed:

- M1-029 files were staged and `git diff --cached --check` passed.
- `swift test --package-path Packages/BarrierCompatibility` passed after staging,
  140 tests.
- `python3 Tools/Backlog/validate_package.py`, `make architecture-check` and
  `make docs-check` passed after staging.

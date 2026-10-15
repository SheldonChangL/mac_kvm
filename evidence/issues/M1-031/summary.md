# M1-031 Evidence Summary — Barrier Control Message Decoder

Issue: M1-031 (GitHub Issue #42)

Author: Claude Code (--model opus); independent review: Codex.

Base commit: `5277134a75b1fcea9370203b08d65d1d213bdaf4` (M1-030 merged)

Branch: `codex/m1-031-barrier-control-messages`

Status: **implemented; author SwiftPM tests, warnings-as-errors, format lint,
backlog validator and architecture check pass. `xcodebuild` and `make verify`
could not complete in the authoring environment and require a reviewer rerun.**

## Preconditions

- M1-025 (#38) and M1-026 (#39) are closed and merged; M1-022 (reassembler) is
  merged.
- `docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md` is Accepted for
  M1-031 only; `BARRIER-EVID-0005` fixture metadata and sanitized bytes exist
  under `Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/`.
- This evidence is not used for M1-032, M1-033, M1-034 or M1-041.

## Deliverables (Exact Files only)

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierControlMessages.swift`:
  module-internal `BarrierControlDecoder` (`init(maximumPayloadLength:)`,
  `decode(payload:direction:)`, read-only `state`), `BarrierControlDirection`,
  `BarrierControlToken`, `BarrierControlOutcome` (`event`, `keepalive`,
  `skipped`), `BarrierControlEvent`, `BarrierKeepalive`, `BarrierScreenInfo`,
  `BarrierEnter`, opaque `BarrierEnterSequence`/`BarrierEnterModifierMask`,
  `BarrierSetupControl`, `BarrierExcludedFrameDiagnostic` and typed
  `BarrierControlMessageError`.
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierControlMessagesTests.swift`:
  34 Swift Testing tests.
- `docs/components/M1-031-barrier-control-messages.md`.
- `evidence/issues/M1-031/` (`summary.md`, `commands.json`,
  `tests/barrier-control-messages-tests.json`,
  `tests/swift-testing-xunit-swift-testing.xml`).

No `Package.swift`, existing source or test, fixture, ADR, register, backlog,
manifest, traceability, `KVMEvent` or later-Issue file was changed. The untracked
`MacKVM_M1-001_unblock.zip` and `mackvm-unblock/` are unrelated and untouched.

## Design summary

- Payloads from both directions are passed with an explicit direction. Checks
  run in order: payload limit, token, direction, exact body length, field
  rules, session state, then CINN containment in the current screen.
- DINF: 14-byte body; signed BE origin; width/height raw `1...0x7fff`; reserved
  zero; cursor raw `0...0x7fff` inside `[origin, origin + size)` computed in
  `Int`. CINN: 10-byte body; coordinates raw `0...0x7fff` inside the current
  screen; sequence and modifier mask opaque. DSOP: exactly four zero bytes.
- Minimal state rule: `setup(screen?)` → `active` → `inactive`; enter requires a
  current valid DINF; setup frames only before the first enter; geometry changes
  only while not active; repeated enter and leave without enter fail closed.
  Failures are sticky; a new session needs a new decoder.
- CALV/CNOP are `.keepalive` outcomes; `BarrierControlEvent` has no keepalive
  case. DCLP/DKDN/DKUP (server-to-client only) are skipped with
  token/direction/byte-count/reason metadata only. Unknown tokens fail closed.
- No imports, no logging, no I/O, no timer, no resource; cancellation does not
  apply (documented); reset/idempotency is tested.

## Acceptance criteria mapping

| Criterion | Evidence |
| --- | --- |
| Focus items have locatable implementation/test | control packet → control event: `observedControlSequenceDecodesEveryAllowedTokenInItsDirection`; coordinate/size bounds: `dinfAcceptsOnlyPositiveNonZeroSizesUpTo0x7fff`, `dinfCursorMustBeRawNonNegativeAndInsideItsOwnRectangle`, `cinnCoordinatesMustBeRawNonNegativeAndInsideTheCurrentScreen`; keepalive outside input pipeline: `keepaliveAndNoOpAreNeverControlEvents`, `controlEventTypeHasNoKeepaliveOrExcludedCase` |
| Happy path test | `observedControlSequenceDecodesEveryAllowedTokenInItsDirection`, `goldenDinfDecodesToTheObservedFieldsAndItsPayloadBytesAreConsumedExactly`, `goldenCinnDecodesToTheObservedFieldsWithOpaqueSequenceAndMask`, `enterIsAcceptedAgainAfterLeaveAndValidatedAgainstTheReplacedScreen` |
| Boundary/limit test | size `1`/`0x7fff`/`0x8000`; first/last cell inside and one past outside; `origin = 0x7fff`/`-32768` without overflow; `payloadLimitIsInclusiveAndCheckedBeforeDispatch` |
| Invalid input/failure test | `dinfBodyMustBeExactlyFourteenBytes`, `cinnBodyMustBeExactlyTenBytes`, `tokenOnlyFramesRejectAnyBody`, `dsopAcceptsOnlyAFourByteZeroBody`, `dinfRejectsEveryNonZeroReservedValue`, `tokensFailClosedInTheDirectionTheyWereNotObservedIn`, `unknownTokensAndShortPayloadsFailClosedWithOnlyAByteCount`, `cinnFailsClosedWithoutACurrentScreen`, `stateRulesFailClosedOnUnobservedSequences` |
| Cancel/cleanup/idempotency test | No async/state resource exists (no I/O, timer, task, lock), so cancellation does not apply. Session state reset/idempotency: `failureIsStickyAndEveryLaterFrameRethrowsTheFirstError`, `keepaliveAndExcludedFramesNeverChangeStateInAnyLiveState`, `freshDecodersAreIndependentAndRunsAreDeterministic` |
| Golden/conformance bytes equal exactly | `goldenFramesEqualTheBarrierEvid0005FixtureBytesExactly` (fixture base64 bytes == ADR bytes for all 10 consumable frames); golden DINF/CINN re-serialize to the exact frames; `everySingleBitFlipOfTheGoldenDinfAndCinnIsDetected` |
| Fragmentation/coalescing/truncation test | `coalescedAndFragmentedStreamsYieldTheSameOutcomes` (coalesced, byte-by-byte, every 2-way split), `clientStreamDecodesThroughTheReassemblerByteByByte`, `truncatedStreamNeverHandsAPartialFrameToTheDecoder`, `oversizeExcludedFrameIsRejectedByTheReassemblerBeforeBuffering` |
| Consistent with frozen ADR, no implied API | Internal access only; only ADR tokens/layouts; opaque sequence/mask; no DINF writer, no KVMEvent mapping, no public contract |
| Architecture checker, lint, build, unit tests, no new warnings | SwiftPM 185/185 and warnings-as-errors 185/185 (`--disable-sandbox`); `swift format lint --strict` on both files pass; repository-wide format lint inside code-quality pass; `validate_package.py` and `make architecture-check` pass; **`xcodebuild` not completed (environment, exit 66) — reviewer rerun required** |
| No sensitive logging | No log site and no imports (`productionSourceImportsNothingAndNeverNamesKVMCoreTypes`); `errorsAndStatesForFailuresCarryOnlyAllowlistedMetadata`; `knownExcludedFramesAreSkippedWithAContentFreeDiagnostic` |

## RED / GREEN

- RED: tests written first; `swift test --disable-sandbox ... --filter
  BarrierControlMessagesTests` at 2026-10-15T03:01:33Z failed to compile (exit 1,
  468 compiler error lines; types under test absent).
- First GREEN attempt (03:02:53Z): 31/34; three test-construction defects fixed
  without weakening assertions (see the test report).
- GREEN (03:03:09Z): 34/34. Full package (03:03:23Z): 185/185.
- Mutation: 11/11 one-line mutants in `/tmp` copies killed (direction check,
  DSOP zero, reserved field, exclusive edge, raw coordinate bound, sticky
  failure, payload limit, keepalive as event, QINF while active, enter while
  active, zero width).
- Fresh-context Claude review (before Codex): no Critical/High/Medium; three
  Low test-strength findings fixed in the test file only (all 8 bits flipped per
  golden byte, fixed-width integers rejected by the privacy reflection,
  exhaustive error list) plus doc wording. Post-review: focused 34/34
  (03:12:34Z), full 185/185 (03:12:45Z), warnings-as-errors 185/185, mutants
  11/11 again.

## Unmet environmental commands

- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`:
  exit 66, "'MacKVM.xcworkspace' is not a workspace file" with CoreSimulator
  service failures, also outside the harness sandbox. M1-031 does not touch the
  workspace or any Xcode project file.
- `make verify`: code-quality's plain `swift test` hits the nested SwiftPM
  sandbox; later gates were not run. Manual substitutes passed where possible;
  `Tests/Contracts` had 9 failures, all nested-sandbox failures of verifier
  scripts.
- `make docs-check` scans tracked files only; it passed inside `make verify`
  before the M1-031 files were tracked. See `commands.json` for the final
  author-side checks of the new files.

## Known limitations

- Fail-closed state rules may reject unobserved but valid Barrier traffic
  (geometry or setup frames while active, repeated enter, late DSOP).
- The payload limit is caller-supplied (minimum 18); no default is chosen.
- The decoder relies on the caller for direction and for passing the client's
  own DINF.
- Golden bytes are hand-copied, cross-checked against the fixture file.
- Mapping to `KVMEvent`, DINF composition and keepalive replies are not
  implemented.

## Follow-ups

1. Barrier session adapter: wire the decoder after `BarrierClientHandshake`,
   configure the reassembler with the same limit, map `enter`/`leave` into
   `KVMEvent`, map errors into the M1-015/M1-016 taxonomy, and own keepalive
   replies/timeouts.
2. DINF writer for the client's reply to QINF (needs an owning Issue).
3. New evidence before widening state rules (screen change while active,
   repeated enter, sequence semantics, modifier-mask meaning).

## Rollback

Revert the M1-031 change (two Swift files, the component doc and this evidence
directory). No runtime resource, persisted data or migration is involved, and no
production code consumes the decoder yet.

## Reviewer requirements

Tier B, risk high: independent Codex review is required and no model may merge.
The reviewer must rerun `swift test --package-path Packages/BarrierCompatibility`
without `--disable-sandbox`, the `xcodebuild` workspace build, `make verify` and
`make docs-check` once the files are tracked.

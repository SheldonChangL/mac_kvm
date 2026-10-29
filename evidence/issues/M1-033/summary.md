# M1-033 Evidence Summary

Issue: M1-033 (GitHub issue #44), the Barrier `DMDN`/`DMUP` button decoder: wire button
to `KVMEvent.mouseButton`.

Base commit: `76f4045415d298612384a4348c4046e7ff0b88d7` (`origin/main`).

Branch: `codex/m1-033-mouse-button-decoder`.

The consumer is the first-party Linux client (`docs/adr/M4-SCOPE-001-linux-client-first.md`),
through the client session M1-029-FOLLOWUP-001. The issue is filed under the M1 milestone, but
M4-SCOPE-001 makes the Linux client the approved path. The contract it implements is
`docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md`
(`BARRIER-EVID-0006-CLAIM-002`).

## Scope

Files:

- `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseButtonDecoder.swift`
- `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierMouseButtonDecoderTests.swift`
- `docs/components/M1-033-barrier-mouse-button-decoder.md`
- `evidence/issues/M1-033/summary.md` and `evidence/issues/M1-033/commands.json`

No `Package.swift`, existing source or test, fixture, ADR, register, backlog, manifest,
`KVMContracts` or later-issue file was changed. The decoder is module-internal, is not called by
any production code yet, and imports only `KVMContracts`.

## RED

The tests were written first, against a stub that compiles and behaves wrongly on purpose: every
type exists, `decode` always throws `unknownToken`, `mouseButton(wireValue:)` returns `nil` and
the token bytes are empty.

`timeout 900 swift test --package-path Packages/BarrierCompatibility --filter BarrierMouseButtonDecoderTests`
built and ran, and failed (exit 1): `Test run with 20 tests in 1 suite failed after 1.791 seconds
with 51 issues.` Sixteen tests failed. Four passed against the stub, for reasons that do not need
the decoder:

- `productionSourceImportsOnlyKVMContracts` and `productionSourceDeclaresNothingPublic` read the
  source, which the stub already satisfied;
- `goldenButtonFramesEqualTheBarrierEvid0006FixtureBytesExactly` compares hand-copied bytes with
  the fixture and does not call the decoder;
- `unknownAndShortTokensFailClosedWithOnlyAByteCount` expects exactly what the stub always does.

The RED log was captured with stdout and stderr merged. It is the first entry of `commands.json`,
with the merged stream in `stdout` and an empty `stderr`. Its `startedAt` and `endedAt` are the
creation and last-write times of the log file.

## GREEN

- `swift test --package-path Packages/BarrierCompatibility --filter BarrierMouseButtonDecoderTests`:
  `Test run with 20 tests in 1 suite passed`.
- `swift test --package-path Packages/BarrierCompatibility`: `Test run with 267 tests in 9 suites
  passed`. Before this change the same command reported 247 tests in 8 suites, so the decoder adds
  20 tests and one suite and breaks none.
- No compiler warning appears in either build output.
- The fragmentation test runs the capture's whole server-to-client stream (284 frames, 3,849
  bytes) through `BarrierFrameReassembler` at 3,850 chunkings (coalesced, one byte at a time and
  3,848 two-way splits) and at 3,849 truncation lengths. That one test takes about 4 seconds,
  nearly all of the suite's run time.

## Mutation checks

Each mutant was applied to `BarrierMouseButtonDecoder.swift` as one exact-string replacement. The
suite was run, and the file was restored from a backup copy before the next mutant. After every
restore, the file's diff against the index was empty and the file was byte-identical to the
backup. The unmutated run, as a control, passed 20 of 20. The first six rows are the mutations the
dispatch required; the rest are extra.

| Id | Mutation | Result |
| --- | --- | --- |
| R1 | map the wire value with `MouseButton(rawValue:)` | failed 7: `wireValuesFollowTheEncodersTableNotMouseButtonRawValues`, `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder`, `capturedButtonFramesDecodeInOrderWithButtonFiveDropped`, `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows`, `releaseWithoutAPressIsStillEmitted`, `decoderIsStatelessAndDeterministic`, `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| R2 | decode wire 5 as `.auxiliary` instead of dropping it | failed 6, including `wireValueFiveIsDroppedAsUnrepresentableForDownAndUp`, `capturedButtonFramesDecodeInOrderWithButtonFiveDropped`, `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows`, `outcomeEventsAreAlwaysMouseButton` |
| R3 | decode `DMUP` as a press | failed 11, including `tokenBytesAreTheFrozenAsciiTokensAndPhases`, `capturedButtonFramesDecodeInOrderWithButtonFiveDropped`, `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder`, `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue` |
| R4a | accept wire 0 (as `.left`) | failed 3: `wireValuesOutsideOneToFiveAreDroppedForDownAndUp`, `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows`, `outcomeEventsAreAlwaysMouseButton` |
| R4b | accept wire 6 (as `.auxiliary`) | failed the same 3 tests as R4a |
| R4c | accept wires 0 and 6 together (as `.left`) | failed the same 3 tests as R4a |
| X1 | treat 0 to 6 as the contract range (0 and 6 reported as unrepresentable) | failed 2: `wireValuesOutsideOneToFiveAreDroppedForDownAndUp`, `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows` |
| X2 | drop every `DMUP` | failed 11, including `capturedButtonFramesDecodeInOrderWithButtonFiveDropped`, `releaseWithoutAPressIsStillEmitted`, `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue` |
| X3 | skip the direction check | failed 2: `clientToServerDirectionFailsClosedBeforeTheBody`, `decoderIsStatelessAndDeterministic` |
| X4 | accept a body of one byte or more | failed 1: `bodyMustBeExactlyOneByte` |
| X5 | judge the body length before the direction | failed 1: `clientToServerDirectionFailsClosedBeforeTheBody` |
| X6 | report wire 5 as out of contract | failed 5, including `wireValueFiveIsDroppedAsUnrepresentableForDownAndUp`, `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` |
| X7 | emit `DMDN` 5 as an auxiliary press while `DMUP` 5 stays dropped (a dropped release that leaves a button held) | failed 8, including `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue`, `wireValueFiveIsDroppedAsUnrepresentableForDownAndUp`, `dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata` |

All 13 mutants were killed. The runner's stdout is the `run-mutations.py` entry of
`commands.json`. The runner script is a producer-side tool and is not committed; each row above
can be reproduced by hand with the single replacement it names.

## Acceptance mapping

Every checkbox of `MacKVM_Implementation_Package_v2/issues/M1/M1-033-barrier-mouse-button-decoder.md`
maps to a test or a recorded command. Scope first, then the acceptance criteria, then the automated
tests.

| Criterion | Evidence |
| --- | --- |
| Scope: down/up/button mapping | `tokenBytesAreTheFrozenAsciiTokensAndPhases` (`DMDN` is down, `DMUP` is up); `wireValuesFollowTheEncodersTableNotMouseButtonRawValues` (1 left, 2 middle, 3 right, 4 auxiliary, and the raw-value trap); `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder`; `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` |
| Scope: unknown button policy | `wireValueFiveIsDroppedAsUnrepresentableForDownAndUp`; `wireValuesOutsideOneToFiveAreDroppedForDownAndUp`; `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows` (all 256 values, both tokens); `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue` (every emitted press can be released by an emitted `DMUP` of the same value, so a dropped release never strands a press of its own value) |
| Scope: does not update macOS state | The decoder returns a value and imports only `KVMContracts` (`productionSourceImportsOnlyKVMContracts`); it keeps no state (`decoderIsStatelessAndDeterministic`) |
| Scope: only the Exact Files; E03 and the architecture guardrails | The file list in "Scope"; `make architecture-check` in `commands.json` |
| Scope: success, boundary, error and cancellation/cleanup tests | See the automated-test rows below |
| AC1: every Focus item has an implementation or a test | The three Scope rows above, and `docs/components/M1-033-barrier-mouse-button-decoder.md` |
| AC2: happy path | `capturedButtonFramesDecodeInOrderWithButtonFiveDropped`; `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder` |
| AC2: boundary | `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows` (0, 1, 4, 5, 6 and 255 included); `wireValuesOutsideOneToFiveAreDroppedForDownAndUp` |
| AC2: invalid input | `bodyMustBeExactlyOneByte`; `clientToServerDirectionFailsClosedBeforeTheBody`; `unknownAndShortTokensFailClosedWithOnlyAByteCount` |
| AC2: error, cancel and cleanup | `decoderIsStatelessAndDeterministic` (a failure does not latch; the decoder owns no I/O, timer, task or resource, so cancellation does not apply); `releaseWithoutAPressIsStillEmitted`; `aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue` |
| AC3: behavior consistent with the frozen ADR, no implicit API | `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` and the table tests pin the ADR's rules; `productionSourceDeclaresNothingPublic` (nothing `public`, `open` or `package`); `KVMContracts` is unchanged |
| AC4: architecture checker, lint, build, unit tests, no new warning | `make architecture-check`, `swift format lint --strict` on both files and repository-wide, `xcodebuild`, `swift test` (267 tests, no warning) and `make verify` in `commands.json` |
| AC5: no sensitive data in production logs | The decoder logs nothing and imports nothing else (`productionSourceImportsOnlyKVMContracts`); `dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata` (only enums and `Int` counts, never the button value) |
| Test: happy path | `capturedButtonFramesDecodeInOrderWithButtonFiveDropped` |
| Test: boundary or limit | `everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows`; `bodyMustBeExactlyOneByte` (0, 2, 3, 4 and 9 bytes around the exact length 1) |
| Test: invalid input or failure | `bodyMustBeExactlyOneByte`; `clientToServerDirectionFailsClosedBeforeTheBody`; `unknownAndShortTokensFailClosedWithOnlyAByteCount` |
| Test: cancel, cleanup or idempotency (only if async, state or resource) | None exists: the decoder is a caseless enum of static functions. Idempotency and no latching: `decoderIsStatelessAndDeterministic` |
| Test: golden bytes exactly equal | `goldenButtonFramesEqualTheBarrierEvid0006FixtureBytesExactly` (hand-copied frames equal the fixture's, byte for byte, in order); `everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder` (each encoder frame equals the captured frame byte for byte, and decodes back) |
| Test: fragmentation, coalescing and truncation | `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` (coalesced, byte by byte, every two-way split, every truncation length); `heldButtonSpansPointerMovesInTheFixtureStream` |
| Required commands | `swift test --package-path Packages/BarrierCompatibility`, `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`, `python3 Tools/Backlog/validate_package.py` and `make architecture-check`, all in `commands.json` |
| Expected evidence | This file, `commands.json` and the component doc. The issue also lists `evidence/issues/M1-033/tests/`; as in M1-060, the test output is recorded in `commands.json` instead, because the dispatch listed exactly this file set |

## Known limitations

- **Wire button 5 is dropped.** `DMDN` 5 and `DMUP` 5 are in the contract's range but
  `MouseButton` has four cases, so both are dropped with reason `unrepresentableButton`. This is
  the lead's decision for this issue, not the Product Owner's. It is not a contract change. Supporting five buttons needs a
  new `KVMContracts` case and changes to the Mac capture and the server encoder.
- **Pairing is by value, not by state.** A server that sent `DMDN` 1 and then a `DMUP` with
  another value would leave the left button held until a `DMUP` 1 or the session's terminal-path
  cleanup (M1-063-FOLLOWUP-001). The contract's observed pairs carry equal values. A release is
  never dropped for lack of a press.
- **The `MouseButton` names are first-party.** The contract gives the wire values 1 to 5 and their
  capture pairing with the driver's X buttons, but not their names. The table is the first-party
  encoder's, which equals the captured frames byte for byte. The M2-035 automated smoke (`evidence/issues/M2-035/automated-smoke/x-events.txt`) exercised
  left, right and middle against a real `barrierc`, not the auxiliary button.
- **No session consumes the decoder yet.** Routing by token prefix and mapping thrown errors to the
  protocol-violation taxonomy belong to M1-029-FOLLOWUP-001.
- **The register is not updated.** `consumingTests` of `BARRIER-EVID-0006` do not list this suite;
  `evidence/registers/M1-023.json` is outside the Exact Files, so this is a follow-up for the
  register owner.
- **`commands.json` shortens one log.** The `xcodebuild` entry keeps its last 8 lines only, with a
  line that says how many earlier lines were omitted, because the log is mostly absolute paths
  (a clean build is more than a thousand lines). It also masks the home directory there as
  `<home>`.
- The golden bytes are hand-copied into the test and cross-checked against the fixture.

## Independent review

No Critical, High or Medium finding. The four Low findings are resolved in the commit that adds
this file:

- the doc now cites the M2-035 automated smoke as smoke evidence;
- the doc labels the button-5 drop and the unpaired-release rule as first-party decoder policy;
- `commands.json` now has a `note`, a `toolchain` and a `date`;
- the mutation runner and its output are committed under `mutations/`.

The report is in `independent-review.md`. The machine-readable test report is in `tests/`
(267 tests, 0 failures).

## Reviewer requirements

An independent review and the Product Owner's merge are required. No model merges.

Full gates are in `commands.json`.

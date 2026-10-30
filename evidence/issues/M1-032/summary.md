# M1-032 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseMoveDecoder.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierMouseMoveDecoderTests.swift`,
`docs/components/M1-032-barrier-mouse-move-decoder.md`.

The decoder turns a Barrier `DMMV` frame into `KVMEvent.mouseMove`: a raw coordinate must be in
`0x0000…0x7FFF` and inside the client's own `DINF` rectangle, or the frame is dropped, never
clamped; `normalized = (pixel − origin) / (extent − 1)`, the inverse of
`BarrierServerInputEncoder`. Its consumer is the first-party Linux client session
(M4-SCOPE-001); nothing wires it yet.

## RED

Against a compiling stub: 16 tests ran, 14 failed and 2 passed by construction, with 7530
recorded issues.

## GREEN

- Focused: `✔ Test run with 16 tests in 1 suite passed after 3.640 seconds.`
- Full package at `039299e`: 263 tests in 9 suites passed, in the implementer's runs (also with
  `-Xswiftc -warnings-as-errors`) and again in the run that wrote `tests/`.

## Mutation checks

Each mutant is one edit to `BarrierMouseMoveDecoder.swift`. The file was backed up, the suite was
run against the mutant, and the file was restored from the backup. After the last mutant the file
was equal to the backup byte for byte and `git diff` showed no change to it. Every run compiled,
ran 16 tests and exited 1. R1 to R4 are the required checks.

| # | Mutation (one edit to `BarrierMouseMoveDecoder.swift`) | Result | Failing tests |
|---|---|---|---|
| R1 | normalize by `extent` instead of `extent - 1`: `Double(Int(extent) - 1)` becomes `Double(Int(extent))` | failed | `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`, `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder`, `coordinatesOutsideTheScreenAreDroppedNotClamped`, `decoderIsPureAndScreensAreIndependent`, `edgesAndCenterRoundTripThroughTheEncoder`, `everyReachablePixelRoundTripsDecodeThenEncode`, `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated`, `normalizedIsThePixelOffsetOverExtentMinusOneAndZeroForASinglePixel`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| R2 | remove the `0x0000...0x7FFF` bound: the `guard x <= maximumRawCoordinate, y <= ...` block is deleted | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| R3 | remove the client-rectangle check: the `guard screen.contains(x:y:)` block is deleted, so an outside value is not dropped | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `decoderIsPureAndScreensAreIndependent`, `dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata`, `outcomeEventsAreAlwaysMouseMove`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| R4 | swap x and y: the first wire field is read as y and the second as x | failed | `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`, `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder`, `coordinatesOutsideTheScreenAreDroppedNotClamped`, `decoderIsPureAndScreensAreIndependent`, `edgesAndCenterRoundTripThroughTheEncoder`, `everyReachablePixelRoundTripsDecodeThenEncode`, `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| E1 | swap x and y on the output point only | failed | `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`, `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder`, `coordinatesOutsideTheScreenAreDroppedNotClamped`, `decoderIsPureAndScreensAreIndependent`, `edgesAndCenterRoundTripThroughTheEncoder`, `everyReachablePixelRoundTripsDecodeThenEncode`, `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| E2 | check the rectangle before the raw bound | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| E3 | raw bound `<` instead of `<=`: 0x7FFF is rejected | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `everyReachablePixelRoundTripsDecodeThenEncode`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| E4 | raw bound 0x8000 instead of 0x7FFF: 0x8000 is accepted | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| E5 | body length `>= 4` instead of `== 4` | failed | `bodyMustBeExactlyFourBytes` |
| E6 | the direction is not checked | failed | `clientToServerDirectionFailsClosedBeforeTheBody` |
| E7 | the one-pixel-axis guard is removed: 0 / 0 | failed | `normalizedIsThePixelOffsetOverExtentMinusOneAndZeroForASinglePixel` |
| E8 | the screen origin is ignored when normalizing | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `decoderIsPureAndScreensAreIndependent`, `edgesAndCenterRoundTripThroughTheEncoder`, `everyReachablePixelRoundTripsDecodeThenEncode`, `normalizedIsThePixelOffsetOverExtentMinusOneAndZeroForASinglePixel`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |
| E9 | an out-of-range value is reported as `coordinateOutsideScreen` | failed | `coordinatesOutsideTheScreenAreDroppedNotClamped`, `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment` |

## Acceptance mapping

Criteria of `MacKVM_Implementation_Package_v2/issues/M1/M1-032-barrier-mouse-move-decoder.md`:

| Criterion | Evidence |
| --- | --- |
| Every Focus item has a locatable implementation, test or sign-off (the issue has no Focus section; its Scope bullets stand in) | (a) wire coordinate to domain event: `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`, `outcomeEventsAreAlwaysMouseMove`. (b) invalid coordinate typed error: a typed, content-free `.dropped(BarrierMouseMoveDropDiagnostic)` with the closed reasons `coordinateOutOfRange` and `coordinateOutsideScreen`, because the frozen contract makes an invalid coordinate drop-and-continue, not session-ending: `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment`, `coordinatesOutsideTheScreenAreDroppedNotClamped`; the thrown error is the three fail-closed cases: `bodyMustBeExactlyFourBytes`, `clientToServerDirectionFailsClosedBeforeTheBody`, `unknownAndShortTokensFailClosedWithOnlyAByteCount`. (c) golden vector round-trip evidence: `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder`, `everyReachablePixelRoundTripsDecodeThenEncode`, `edgesAndCenterRoundTripThroughTheEncoder`. (d) next row. |
| Happy path, boundary, invalid input and error/cancel/cleanup tests pass | Happy path: `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`. Boundary: `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment`, `coordinatesOutsideTheScreenAreDroppedNotClamped`, `edgesAndCenterRoundTripThroughTheEncoder`, `normalizedIsThePixelOffsetOverExtentMinusOneAndZeroForASinglePixel`. Invalid input: the three fail-closed tests above. Cancel/cleanup: the decoder owns no I/O, timer, task, lock or other resource, so there is nothing to cancel or clean up; determinism and the absence of latched state: `decoderIsPureAndScreensAreIndependent`. All 16 tests pass. |
| Public behavior matches the CONTRACT_CATALOG and the frozen ADR; no implicit API | Everything is module-internal. Token, layout, raw bound and rejection rules come only from M1-PROTOCOL-003. `KVMEvent` (C-001) is unchanged and only `.mouseMove` is produced (`outcomeEventsAreAlwaysMouseMove`). C-008: wire pixels stay separate from `NormalizedPoint`, which does the 0...1 clamp; the decoder never clamps a wire value. `productionSourceImportsOnlyKVMContracts`. |
| Architecture checker, lint, build and unit tests pass, no new warning | The Verification list above: `make architecture-check`, `swift format lint --strict`, `xcodebuild`, the full-package `swift test`, `-warnings-as-errors`, `make verify`. |
| Production logs hold no typed text, clipboard payload, secret or reconstructable content | The decoder has no log site and imports no logger (`productionSourceImportsOnlyKVMContracts`); errors and diagnostics hold only enums and `Int` counts, never a coordinate (`dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata`). |

Automated Tests of the issue:

| Required test | Evidence |
| --- | --- |
| Happy path | `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne`: the seven captured frames decode to the observed pixels, normalized by `extent - 1`. |
| Boundary or limit | `rawCoordinatesAbove0x7fffAreDroppedBeforeContainment`, `coordinatesOutsideTheScreenAreDroppedNotClamped`, `edgesAndCenterRoundTripThroughTheEncoder`. |
| Invalid input or failure | `bodyMustBeExactlyFourBytes`, `clientToServerDirectionFailsClosedBeforeTheBody`, `unknownAndShortTokensFailClosedWithOnlyAByteCount`. |
| Cancel, cleanup or idempotency, if there is async, state or a resource | None exists. Determinism and no latched state: `decoderIsPureAndScreensAreIndependent`. |
| Golden bytes exactly equal, not only the decoded object | `capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder` compares the whole frame, length prefix included, with the captured bytes; `capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne` first checks that each fixture payload equals the pair the register records. |
| Fragmentation, coalescing and truncation | `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated`: the fixture's server-to-client stream through `BarrierFrameReassembler`, routed by token, coalesced, byte by byte, split at every boundary, and truncated at every byte. |

## Independent review

No Critical or High finding. The reviewer judged the typed-drop reading of "invalid coordinate
typed error" right. The Medium finding (no machine-readable test report) and the Low findings
(no per-command times in `commands.json`, no sentence reconciling the issue's wording) are
resolved in the commit that adds this file; the slow truncation test is accepted as is. See
`independent-review.md`.

## Known limitations

- Only a client at origin (0, 0), 1600 x 900, was captured. Pointer values at or above `0x8000`,
  negative coordinates and `DMMV` relative to a non-zero `DINF` origin are not frozen by the
  contract. The decoder drops raw values above `0x7FFF` and otherwise applies the first-party
  inverse `pixel - origin`; it makes no Barrier claim about them.
- The pixel-to-`NormalizedPoint` formula is a first-party convention. At the center of an even
  extent the decoded value is within `1 / (2 * (extent - 1))` of 0.5, not equal to it.
- The decoder is not yet wired into a session, and nothing has run it against a real server
  stream beyond the M2-022 capture frames and the first-party encoder. M4-036-FOLLOWUP-001 is the
  end-to-end check.
- The session must offer a `DMMV` payload to this decoder before `BarrierControlDecoder`, which
  fails closed on the token, and must rebuild the decoder when a `DINF` replaces the screen.
- `evidence/registers/M1-023.json` does not list this suite under `consumingTests` of
  `BARRIER-EVID-0006`; the register is outside this issue's files.
- Per-command start and end times are not in `commands.json`; see its note.
- The Status line of M1-PROTOCOL-003 still reads "Proposed" on main. This is a follow-up.

Full gates are in `commands.json`; the machine-readable test report is in `tests/`.

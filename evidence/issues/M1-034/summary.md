# M1-034 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseWheelDecoder.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierMouseWheelDecoderTests.swift`,
`docs/components/M1-034-barrier-mouse-wheel-decoder.md`.

The decoder turns a Barrier `DMWM` frame into `KVMEvent.scroll` with the M1-PROTOCOL-003 rule:
`deltaX = −wireX / 120` and `deltaY = wireY / 120`, in `Int32`, by integer division toward zero.
Its consumer is the first-party Linux client session (M4-SCOPE-001); nothing wires it yet.

## RED

Against a stub that compiled and always dropped:
`✘ Test run with 17 tests in 1 suite failed after 6.372 seconds with 8926 issues.` 15 of 17 tests
failed. The two that passed (`tokenBytesAreTheFrozenAsciiToken`,
`productionSourceImportsOnlyKVMContracts`) do not exercise decode behavior.

## GREEN

- Focused: `✔ Test run with 17 tests in 1 suite passed after 2.233 seconds.`
- Full package at `e5b5465`: `✔ Test run with 264 tests in 9 suites passed`, in the
  implementer's run and again in the run that wrote `tests/`.

## Mutation checks

| Mutation | Result |
| --- | --- |
| remove the horizontal inversion | failed: 9 of 17, among them `capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight` and `horizontalAxisIsInvertedAndVerticalIsNot` |
| invert the vertical axis too | failed: 10 of 17, among them `capturedNotchFramesReEncodeByteForByteThroughTheServerEncoder` |
| floor division instead of division toward zero | failed: 5 of 17, among them `remaindersAreDroppedTowardZero` and `extremesDoNotOverflow` |
| emit a zero `.scroll` instead of dropping | failed: 3 of 17, among them `zeroOnBothAxesIsDroppedWithADiagnostic` |
| negate in `Int16` before widening | the test process traps (signal 5) in `extremesDoNotOverflow` |

The independent reviewer ran 10 more mutants in its own worktree and every one was killed
(`independent-review.md`).

## Acceptance mapping

| Criterion | Test |
| --- | --- |
| Vertical and horizontal delta, overflow and bounds, direction semantics | `capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight`, `horizontalAxisIsInvertedAndVerticalIsNot`, `scrollRoundTripsThroughTheServerEncoderForEveryDeltaPairUpTo273`, `extremesDoNotOverflow`, `everyWireValueOnEachAxisMatchesAnIndependentTowardZeroOracle`, `remaindersAreDroppedTowardZero` |
| Happy path | `capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight`, `scrollRoundTripsThroughTheServerEncoderForEveryDeltaPairUpTo273` |
| Boundary or limit | `extremesDoNotOverflow`, `remaindersAreDroppedTowardZero`, `zeroOnBothAxesIsDroppedWithADiagnostic` |
| Invalid input or failure | `bodyMustBeExactlyFourBytes`, `clientToServerDirectionFailsClosed`, `unknownAndShortTokensFailClosed` |
| Cancel, cleanup or idempotency | not applicable: no async work, I/O, timer, task or resource. `decoderIsStatelessAndDeterministic` |
| Golden bytes equal exactly | `capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight`, `capturedNotchFramesReEncodeByteForByteThroughTheServerEncoder` |
| Fragmentation, coalescing, truncation | `fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated` |
| Matches the frozen ADR, no implicit API | module-internal declarations only; the direction and round-trip tests pin the rule |
| No sensitive logging | no log site; `productionSourceImportsOnlyKVMContracts`, `dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata` |
| Architecture check, lint, build, unit tests, no new warnings | `commands.json` |

## Independent review

No Critical or High finding. The Medium finding (no machine-readable test report) and the two
Low findings (a worktree basename in `commands.json`, two doc sentences) are resolved in the
commit that adds this file. See `independent-review.md`.

## Known limitations

- Multi-notch magnitudes and the remainder rule are first-party conventions; the capture holds
  one notch per direction.
- No horizontal scroll has been validated end to end. M4-036-FOLLOWUP-001 must include one.
- A frame below 120 units on both axes is dropped and nothing accumulates across frames. At
  most 273 notches per axis fit in one frame.
- The register's `consumingTests` links for `BARRIER-EVID-0006` do not list these tests;
  `evidence/registers/M1-023.json` is outside the Exact Files. This is a follow-up.
- The Status line of M1-PROTOCOL-003 still reads "Proposed" on main. This is a follow-up.

Full gates are in `commands.json`; the machine-readable test report is in `tests/`.

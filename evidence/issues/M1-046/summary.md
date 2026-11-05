# M1-046 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ModifierStateLedger.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ModifierStateLedgerTests.swift`,
`docs/components/M1-046-modifier-state-ledger.md`, and this directory.

`ModifierStateLedger` records which of Shift, Control, Option and Command the client's injected
keys hold, plus the last key event's Caps Lock bit. It reports `implied` and `stale`
discrepancies and never synthesizes or corrects anything (C-006; the Product Owner decided on
2026-11-02 that V1 synthesizes no modifier or Caps Lock state at enter). The consumer is the
first-party Linux client (M4-SCOPE-001).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Where does the ledger's lock bit come from? | From the last key event of any kind. A Caps Lock toggle's own frames are not a lock discrepancy until the next key event; an unexplained lock change is reported once. | The plan's first sketch (copy the bit only from Caps Lock frames) leaves the lock on after every toggle-off, because both toggle-off frames carry the bit (M1-PROTOCOL-003). The implementer proposed this reading; the lead adopted it as amendment h.2 of the client master plan on 2026-11-03, and the independent review confirmed it. V1 uses the bit for diagnostics only. |
| Which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | The root package, filtered to this suite, plus the full root suite. | `Packages/KVMCore` has no `Package.swift`. The issue's command also runs, because SwiftPM resolves the root package (205 tests). M1-060 and M1-061 record the same deviation. |
| May the round-trip test use the real server encoder? | No. It uses M1-043's round-trip model of `BarrierServerInputEncoder`. | `KVMCoreTests` cannot import `BarrierCompatibility` without a `Package.swift` edit, which belongs to M4-020. The independent review checked the model line by line against the encoder; a real end-to-end test is a follow-up in `Tests/Integration`. |
| What about releases dropped on terminal paths? | Out of scope here; plan amendment h.1. | The implementer found that a queue reset before release-all can drop a release the input ledger already counted. The lead's amendment h.1 adds an injector sweep (`releaseAllHeld()`, `releaseRemaining()`) after the ledger's plan; M4-002 (PR #352), M1-063, M4-024 and M1-063-FOLLOWUP-001 carry it. |

## RED

- Against a compiling stub with the API and no behavior, on `876e5d6`:
  `✘ Test run with 19 tests in 1 suite failed after 0.381 seconds with 4392 issues.` 17 of the 19
  failed; the empty-ledger check and the source check passed. After that run,
  `everyKeyFrameRefreshesTheLockBitWithoutAnyCapsLockPress` was renamed
  `lockBitChangesThatNoCapsLockEventExplainsAreReportedOnce`, and
  `serverReleasesBeforeLeavingLeaveNothingHeld` was added (`commands.json`, `testRenames`,
  `postRedChange`).
- Review round: the reviewer's mutants R1 and R2 against the test file of `fe8dff3` each failed
  only the random test (`Test run with 20 tests in 1 suite failed after 0.005 seconds with 1
  issue.` and `... after 0.004 seconds with 1 issue.`). With the new deterministic assertions,
  each fails two tests (`Test run with 20 tests in 1 suite failed after 0.005 seconds with 2
  issues.`, twice).

## GREEN

At `c6958a8`:

- Focused: `✔ Test run with 20 tests in 1 suite passed after 0.106 seconds.`, and `20 of 20 focused
  runs passed`.
- Full root package: `✔ Test run with 205 tests in 20 suites passed after 0.116 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 205 tests in 20 suites passed after 0.115
  seconds.`
- `swift test --package-path Packages/KVMCore`: `✔ Test run with 205 tests in 20 suites passed
  after 0.165 seconds.`
- Both strict lints exit 0; `docs check OK`; `architecture check OK`; `PACKAGE OK: 217 issues, 5
  milestones, 17 epics`; `** BUILD SUCCEEDED **`; `make verify`: 24 of 24 gates passed.

## Mutation checks

23 mutants, each killed and restored byte for byte: `23 of 23 mutants killed; baseline passed;
restores clean`. The runner is `mutations/run_mutations.py`, which takes the repository path as
an argument; the results are `mutations/mutations.json`. `mutations/mutations-previous-suite.json`
records R1 and R2 against the earlier test file.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| 1a | own-bit logic inverted: a modifier's own press clears its flag, its own release sets it | 16: `eachModifierKeyHoldsItsOwnFlagFromItsPressToItsRelease`, `ownBitOfAModifierPressOrReleaseIsNotComparedButItsOtherBitsAre` and 14 more |
| 1b | own-bit logic inverted in the comparison | 13: the same two and 11 more |
| 1c | the flag taken from the frame's own bit | 16: the same two and 14 more |
| 2a | Caps Lock toggled by presses, no frame bit read | 8: `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns`, `lockBitChangesThatNoCapsLockEventExplainsAreReportedOnce` and 6 more |
| 2b | Caps Lock held like a modifier | 8: the same two and 6 more |
| 2c | lock bit copied only from Caps Lock frames | 8: the same two and 6 more |
| 3 | `clear()` as a no-op | 1: `clearForgetsEveryModifierAndTheLockBitAndIsIdempotent` |
| 4 | sides not collapsed (presses counted) | 5: `bothSidesOfAModifierCollapseAndTheFirstReleaseReleases`, `clearForgetsEveryModifierAndTheLockBitAndIsIdempotent` and 3 more |
| 5 | implied never reported | 10: `modifierHeldAtEnterIsReportedAsImpliedAndNeverSynthesized`, `ownBitOfAModifierPressOrReleaseIsNotComparedButItsOtherBitsAre` and 8 more |
| 6 | stale never reported | 7: `staleModifierIsReportedAndStaysHeldUntilItsOwnRelease`, `ownBitOfAModifierPressOrReleaseIsNotComparedButItsOtherBitsAre` and 5 more |
| 7 | a stale modifier dropped from the ledger | 6: `staleModifierIsReportedAndStaysHeldUntilItsOwnRelease` and 5 more |
| 8 | an implied modifier adopted | 8: `modifierHeldAtEnterIsReportedAsImpliedAndNeverSynthesized` and 7 more |
| 9 | a modifier's repeat treated as a press | 2: `repeatOfAModifierChangesNothingAndAnUnheldRepeatIsImplied` and 1 more |
| 10 | `isEmpty` ignores stale | 2: `discrepancyIsEmptyOnlyWhenNoFieldDiffers`, `reconcileReportsEveryFieldOnItsOwnAgainstEveryLedgerState` |
| 11 | option field computed from command flags | 5: `reconcileReportsEveryFieldOnItsOwnAgainstEveryLedgerState` and 4 more |
| 12 | `default` branch in the key classification (behavior-neutral) | 1: `productionSourceImportsOnlyKVMContractsAndNeverLogs` |
| 13 | non-key events clear the ledger | 3: `eventsOtherThanKeysChangeNothingAndReportNothing` and 2 more |
| 14 | a toggle's lock change reported | 3: `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns` and 2 more |
| 15 | an unexplained lock change not reported (the earlier behavior) | 5: `lockBitChangesThatNoCapsLockEventExplainsAreReportedOnce` and 4 more |
| 16 | toggle exemption kept beyond the next key event | 2: `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns` and 1 more |
| 17 | `clear()` keeps a pending toggle | 1: `clearForgetsEveryModifierAndTheLockBitAndIsIdempotent` |
| R1 | an event other than a key event between a Caps Lock event and the next key event ends the exemption | 2: `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns`, `randomSequencesFollowTheRulesStatedOverTheWholeHistory` |
| R2 | a Caps Lock press alone leaves the next key event's lock bit compared | 2: `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns`, `randomSequencesFollowTheRulesStatedOverTheWholeHistory` |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Every Focus item (Shift, Control, Option, Command, Caps Lock, reconciliation, clear on disconnect) has an implementation and tests | `eachModifierKeyHoldsItsOwnFlagFromItsPressToItsRelease`, `ownBitOfAModifierPressOrReleaseIsNotComparedButItsOtherBitsAre`, `bothSidesOfAModifierCollapseAndTheFirstReleaseReleases`, `capsLockFollowsTheFramesLockBitThroughBothTogglePatterns`, `lockBitChangesThatNoCapsLockEventExplainsAreReportedOnce`, `reconcileReportsEveryFieldOnItsOwnAgainstEveryLedgerState`, `clearForgetsEveryModifierAndTheLockBitAndIsIdempotent` |
| Happy path | `eachModifierKeyHoldsItsOwnFlagFromItsPressToItsRelease`, `serverChainRoundTripKeepsTheLedgerOnTheServersState`, `serverReleasesBeforeLeavingLeaveNothingHeld` |
| Boundary | `reconcileReportsEveryFieldOnItsOwnAgainstEveryLedgerState` (16 held states × 2 lock bits × 32 reported states), `bothSidesOfAModifierCollapseAndTheFirstReleaseReleases`, `newLedgerHoldsNothingAndAgreesWithAnEmptyReport`, `discrepancyIsEmptyOnlyWhenNoFieldDiffers` |
| Invalid input and failure | `otherKeysNeverChangeTheHeldModifiers`, `eventsOtherThanKeysChangeNothingAndReportNothing`, `repeatOfAModifierChangesNothingAndAnUnheldRepeatIsImplied`, `modifierHeldAtEnterIsReportedAsImpliedAndNeverSynthesized`, `staleModifierIsReportedAndStaysHeldUntilItsOwnRelease` |
| Error, cancel, cleanup and idempotency | `clearForgetsEveryModifierAndTheLockBitAndIsIdempotent`, `ownersOnSeparateTasksAndACancelledTaskGetTheSameResults`, `randomSequencesFollowTheRulesStatedOverTheWholeHistory`, `ledgersAreEquatableValuesThatCopyIndependently` |
| Consistent with C-006 and the frozen ADRs; no implicit API | package-only API (plan b.1 plus the `ModifierDiscrepancy` initializer); the M1-PROTOCOL-003 own-bit and toggle patterns through `serverChainRoundTripKeepsTheLedgerOnTheServersState`; the lock reading of amendment h.2 |
| Checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 205 root tests with warnings as errors, `** BUILD SUCCEEDED **`, `make verify` 24 of 24. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`). |
| No typed text, payload or secret in logs | `productionSourceImportsOnlyKVMContractsAndNeverLogs`; the ledger holds flags only |

## Independent review

- Before the PR, a fresh-context reviewer started by the implementer found nothing critical. Its
  fixes, the lock rule among them, were applied before the first push.
- After the PR, a fresh-context Fable reviewer started by the lead (`independent-review.md`)
  accepted it with no Critical, High or Medium finding and confirmed amendment h.2. Lows 1–4 are
  resolved at `c6958a8`; Low 5, this file and the review record, by the lead's finishing commit.

## Merge

Merged by the lead under the Product Owner's authorization of 2026-11-02: a PR on the
first-party client path merges after a fresh-context review with its findings resolved and green
CI.

## Known limitations

- After a toggle-off, `state.capsLock` stays on until the next key event; the client's own lock
  state is neither known nor synchronized in V1.
- A lock change that first shows up on a Caps Lock frame, or on the key event right after one, is
  not reported (for example, the lock already on at enter and a toggle-off as the first frames).
- A modifier's own bit is not compared on its own press or release, so a modifier held at enter
  is reported on the keys typed while it is held, not at its release.
- No test runs the real encoder, decoder, mapper and ledger together; that follow-up belongs in
  `Tests/Integration`.
- With a server that reports a release per side, the first release releases the modifier (the
  M1-042 cost).
- No synthesis at enter in V1.
- The first-party server releases keys before it leaves with each key's press-time modifiers, so
  a modifier released in between is reported as implied once; nothing stays held. A future
  synthesis feature must not act on such reports, or the server must send those releases with the
  current modifiers.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test report is in `tests/`.

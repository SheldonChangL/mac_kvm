# M1-050 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ReleaseAllKeys.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ReleaseAllKeysTests.swift`,
`docs/components/M1-050-release-all-keys.md`, and this directory.

`ReleaseAllKeys` turns the keys and buttons a client's injector holds into one ordered release
plan (`plan(keys:buttons:)`) and runs it (`execute(_:with:)`). The order is non-modifier keys,
then buttons, then modifier keys, each group newest first; each key release carries the
modifiers recorded at its press. `execute` is synchronous, attempts every step after a failure,
and reports attempted, failed and a disposition (completed, partial, failed, or notRequired for
an empty plan). Running a plan twice is harmless. The consumer is the first-party Linux client
(M4-SCOPE-001).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| What does `plan` take? | `(key:, modifiers:)` pairs, the `ServerCoordinator.remoteKeys` shape, not `HeldKey`. | Client master plan amendment h.7 (the lead's planning document, not in the repository). |
| What is a "modifier key"? | C-005's Modifiers group: shift, control, option, command and capsLock. The classification switch has no `default`. | Amendment h.6; the same grouping M4-002's `releaseAllHeld()` uses. The component doc says so. |
| What happens after a failed step? | Every step is attempted; nothing is logged. | Frozen Decision 7 (attempt everything) and Decision 8 (no logging of input). |
| Which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | The root package, filtered to this suite, plus the full root suite. | `Packages/KVMCore` has no `Package.swift`; SwiftPM resolves the root package (246 tests). M1-046, M1-060 and M1-061 record the same deviation. |
| No manual run and no `environment.json` | Accepted: the hardware half is discharged by the Product Owner's 2026-11-02 decision (plan e.4). | The Xvfb release-all test of M4-024 and the owner E2E (#351) are the hardware evidence for M1-050 and M1-061, so issue #64 stays open until they run. |

## RED

- Against a compiling stub, from the first run: `✘ Test run with 22 tests in 2 suites failed
  after 0.006 seconds with 29 issues.` (`commands.json`, first command, exit 1, recorded as an
  expected failure.)
- Review round: the reviewer's mutant (`failed == attempted` replaced by
  `failed > 0 && failed + 1 >= attempted`) survived all 22 tests. Two tests were added
  (`oneFailureInATwoStepPlanIsPartial`, `twoFailuresInAThreeStepPlanArePartial`); against the
  mutant, the suite now fails: `Test run with 24 tests in 2 suites failed after 0.001 seconds
  with 3 issues.` (mutant R1).

## GREEN

At `124c3e7`:

- Focused: `✔ Test run with 24 tests in 2 suites passed after 0.001 seconds.`
- Full root package: `✔ Test run with 246 tests in 24 suites passed after 0.127 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 246 tests in 24 suites passed after 0.125
  seconds.`
- `swift test --package-path Packages/KVMCore`: `✔ Test run with 246 tests in 24 suites passed
  after 0.125 seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `git diff --cached --check` exit 0;
  `** BUILD SUCCEEDED **` (`xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination
  platform=macOS build`); `make verify`: 24 of 24 gates passed.

## Mutation checks

16 mutants, each killed and restored byte for byte: `killedCount 16`, `mutantCount 16`,
`baselinePassed`, `allRestored` all true in `mutations/mutations.json`. The runner is
`mutations/run_mutations.py`. Ids 1 to 9 are the issue's required mutants; 3b, 3c and 10 to 13
are extras; R1 is the reviewer's.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| 1 | modifier keys come before the other keys and the buttons | 10 issues: `anUnclassifiedKeyIsAnOrdinaryKey`, `capsLockIsAModifierKeyAndReleasesWithTheModifiers`, `eachKeyReleaseCarriesTheModifiersRecordedAtItsPress`, `everyModifierKeyReleasesAfterTheButtons` and more |
| 2 | the buttons come before the non-modifier keys | 8 issues: `capsLockIsAModifierKeyAndReleasesWithTheModifiers`, `everyModifierKeyReleasesAfterTheButtons`, `keysThenButtonsThenModifiersWithEachGroupInReversePressOrder` and more |
| 3 | keys and buttons release in press order | 7 issues: `anUnclassifiedKeyIsAnOrdinaryKey`, `buttonsReleaseNewestFirst`, `capsLockIsAModifierKeyAndReleasesWithTheModifiers` and more |
| 3b | keys only in press order | 6 issues: `anUnclassifiedKeyIsAnOrdinaryKey`, `capsLockIsAModifierKeyAndReleasesWithTheModifiers` and more |
| 3c | buttons only in press order | 2 issues: `buttonsReleaseNewestFirst`, `keysThenButtonsThenModifiersWithEachGroupInReversePressOrder` |
| 4 | `execute` stops at the first step that throws | 6 issues: `aFailedRunCanBeRepeatedAndRetriesEveryStep`, `aFailureOnTheFirstStepStillAttemptsTheRest` and more |
| 5 | every step attempted twice | 7 issues: `aFailedRunCanBeRepeatedAndRetriesEveryStep`, `eachRunAttemptsEachStepExactlyOnce` and more |
| 6 | an empty plan reports completed | 1 issue: `anEmptyPlanIsNotRequiredAndTouchesNothing` |
| 7 | the failed disposition is never produced | 2 issues: `aSingleStepPlanIsCompletedOrFailed`, `everyStepFailingIsFailedNotPartial` |
| 8 | each key release carries no modifiers | 5 issues: `eachKeyReleaseCarriesTheModifiersRecordedAtItsPress` and more |
| 9 | capsLock classified as an ordinary key | 2 issues: `capsLockIsAModifierKeyAndReleasesWithTheModifiers`, `everyModifierKeyReleasesAfterTheButtons` |
| 10 | `failed` never incremented | 8 issues: `aFailureOnTheLastStepIsPartial`, `aSingleStepPlanIsCompletedOrFailed` and more |
| 11 | any failure short of all reports completed | 6 issues: `aFailureOnTheLastStepIsPartial`, `oneFailureInATwoStepPlanIsPartial` and more |
| 12 | control, option and command classified as ordinary keys | 5 issues: `everyModifierKeyReleasesAfterTheButtons`, `planAndExecuteFromHeldInputReleaseEverythingInOrder` and more |
| 13 | key releases composed with phase down | 15 issues: `anUnclassifiedKeyIsAnOrdinaryKey`, `eachKeyReleaseCarriesTheModifiersRecordedAtItsPress` and more |
| R1 | failed also when all but one step failed (`failed > 0 && failed + 1 >= attempted`) | 3 issues: `oneFailureInATwoStepPlanIsPartial`, `twoFailuresInAThreeStepPlanArePartial` |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Non-modifier keys before modifier keys; buttons between | `keysThenButtonsThenModifiersWithEachGroupInReversePressOrder`, `everyModifierKeyReleasesAfterTheButtons`, `nonModifierKeysReleaseNewestFirst`, `modifierKeysReleaseNewestFirst`, `buttonsReleaseNewestFirst`, `capsLockIsAModifierKeyAndReleasesWithTheModifiers`, `anUnclassifiedKeyIsAnOrdinaryKey` |
| Press-time modifiers carried on each release | `eachKeyReleaseCarriesTheModifiersRecordedAtItsPress`, `everyStepIsARelease` |
| Repeatable | `runningThePlanTwiceIsHarmless`, `planningIsPureAndRepeatable`, `aFailedRunCanBeRepeatedAndRetriesEveryStep`, `eachRunAttemptsEachStepExactlyOnce` |
| A partial release failure still attempts the remaining keys | `aFailureOnTheFirstStepStillAttemptsTheRest`, `aFailureOnTheSecondStepStillAttemptsTheRest`, `aFailureOnTheLastStepIsPartial`, `oneFailureInATwoStepPlanIsPartial`, `twoFailuresInAThreeStepPlanArePartial` |
| Dispositions | `releasesEveryStepInPlanOrderAndReportsCompleted`, `anEmptyPlanIsNotRequiredAndTouchesNothing`, `nothingHeldMakesAnEmptyPlan`, `aSingleStepPlanIsCompletedOrFailed`, `everyStepFailingIsFailedNotPartial` |
| Plan and execute together | `planAndExecuteFromHeldInputReleaseEverythingInOrder` |
| Consistent with the frozen decisions; no new public contract | package-only API; Decision 7 (every step attempted) and Decision 8 (no logging); the C-005 Modifiers grouping of amendment h.6 |
| Checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 246 root tests with warnings as errors, `** BUILD SUCCEEDED **`, `make verify` 24 of 24. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`). |
| Manual run on hardware | Not run; discharged by the Product Owner's 2026-11-02 decision (plan e.4). See Known limitations. |

## Independent review

- After the PR, a fresh-context Opus reviewer started by the lead (`independent-review.md`)
  approved it with fixes: no Critical or High finding, 1 Medium, 2 Low. The Medium (a surviving
  mutant on the partial/failed boundary) is fixed at `124c3e7` with two tests and mutant R1; the
  xcodebuild Low is fixed and recorded in `commands.json`; the missing `summary.md` is this file.
- The reviewer did not re-run the full suite, `make verify`, the architecture and docs checks or
  xcodebuild; `commands.json` records them.

## Merge

Pending owner approval.

## Known limitations

- No manual run and no `environment.json`: the hardware evidence is the Xvfb release-all test of
  M4-024 and the owner E2E (#351), so issue #64 stays open and this PR is `Part of #64`.
- `execute` only reports a partial or failed result; the response to it belongs to M1-063.
- `plan` takes the held keys and buttons as input; the injector sweep after a queue reset
  (amendment h.1) is carried by M4-002, M1-063, M4-024 and M1-063-FOLLOWUP-001, not here.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test report is in `tests/`.

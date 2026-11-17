# M1-063-FOLLOWUP-001 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ClientCoordinator.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ClientCoordinatorTests.swift`,
`docs/components/M1-063-FOLLOWUP-001-client-coordinator.md`, and this directory.

`ClientCoordinator` is the client mirror of `ServerCoordinator` (GitHub issue #346, Tier C, PR #368;
follow-up issue with no manifest entry). It consumes the client session's events in order, with one
`NSLock` and effects (`inject`, `moveLocalPointer`, `applyClipboard`, status callbacks) that only
queue. It owns the session generation, the input-state ledger (M1-062) and the clipboard loop guard
(M1-054), and it is the single cleanup entry for every terminal path through `terminate(_:)`, which
runs `CleanupHooks.runOnce`. Its diagnostics hold counts by reason only. The consumer is the
composition root (M4-020-FOLLOWUP-001). The policy is first-party, built from the repository's
contracts.

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| What does `handle` return? | A discardable `ClientHandleOutcome` (`accepted`, `dropped`, `failedClosed`). A failed effect closes the session synchronously and the owner calls `terminate`; `run` does so with the injection-failure trigger. A superset of plan b.8. | Component doc, API; independent review, declared deviation 1. |
| How does `run(_:)` map the end of a stream? | Finished is `streamEnded(.transportClosed)`; a thrown `CoreError` goes through `CleanupHooks.trigger(for:)`; cancellation is `cancelled`; any other error is `protocolViolation(internal.unclassified)`. | Component doc, API; deviation 2. |
| One coordinator across generations? | Yes: `beginSession()` opens the next generation and refuses while a session is open or its cleanup is running, so one `FailSafeCoordinator` serves every generation and the old generation's releases finish before the new one injects. Events from an old generation's stream are dropped. | Plan h.5; component doc, API; deviation 3; mutants M13 and M15. |
| Inbound clipboard while inactive? | Applied, after `ClipboardLoopGuard.admitInbound`; clipboard is not input. Outbound clipboard is sent only while active and open. | Plan a.8; deviation 4; mutant M8. |
| Unpaired repeat? | Never injected; a duplicate down is dropped; an unheld release is injected. | Plan a.6.2; mutants M3, M4. |
| Leave order? | The `ReleaseAllKeys` plan over the ledger (non-modifier keys, buttons, then modifiers, each in reverse press order), then the ledger reset, then `.inactive`. A failed inject keeps the ledger. | M1-050; mutants M5 to M7. |
| A second `terminate` during an in-flight cleanup? | Returns `ran == false` at once and does not wait. The composition root awaits its own `terminate` and treats `beginSession() == false` as wait, then retry. | Review note L1 and its resolution; component doc, Terminal paths. |
| What does `ledgerSnapshot` carry? | No key or button identities; it carries the opaque last clipboard transaction ID, which must not be logged. | Review note L3 and its resolution. |
| Release that failed to queue? | The ledger has already freed the key, so only the injector sweep `releaseRemaining()` releases it (h.1); the property test runs injection failures only with the sweep enabled. | Component doc, Limits. |

## RED

`commands.json`, first command, exit 1, recorded as an expected failure: the tests ran against a
compiling stub whose event handling dropped every event and whose terminate ran no cleanup. The
file's note says 27 of the 29 tests failed; the kept output tail reads `Test run with 29 tests in 1
suite failed after 0.138 seconds with 1022 issues`. The output keeps only the first 25 and last 80
lines, and its timestamps are approximate (taken from the saved output file). The RED run is the
29-test suite; the two tests added by the review resolution are not in it.

## GREEN

macOS, Apple Swift 6.2.3, arm64 (`commands.json`, after the review resolution `a9a0ec5`):

- `swift test --filter ClientCoordinator`: `Test run with 31 tests in 1 suite passed after 0.144
  seconds.` The committed report `tests/swift-testing-xunit-swift-testing.xml` records tests="31"
  failures="0" errors="0" skipped="0".
- Full root package (KVMCore has no `Package.swift` of its own): `Test run with 332 tests in 29
  suites passed after 0.172 seconds.`; with `-Xswiftc -warnings-as-errors`, `Test run with 332 tests
  in 29 suites passed after 0.165 seconds.`
- Both `swift format lint --strict` runs (the two files, and the repository) exit 0.
- `make docs-check` prints `docs check OK`; `make architecture-check` prints `architecture check
  OK`; `python3 Tools/Backlog/validate_package.py` prints `PACKAGE OK: 217 issues, 5 milestones, 17
  epics`.
- `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build`
  prints `** BUILD SUCCEEDED **`.
- `make verify`: 24 gates `[PASSED]`, 0 `[FAILED]`.
- CI: both jobs passed, per the review resolution (the run identifiers are not recorded in the
  evidence directory).

## Mutation checks

`mutations/run_mutations.py` applies each mutant to `ClientCoordinator.swift`, runs its killing test
and restores the source; `mutations/mutations.json` records 16 mutants, all `killed`, and the
`commands.json` entry exits 0. The runner records a timeout as killed. M15 and M16 were added by the
review resolution.

| Mutants | Mutation | Killing test |
| --- | --- | --- |
| M1 | enter does not move the pointer first | `enterMovesThePointerFirstThenBecomesActive` |
| M2 | key and button input accepted while inactive | `inputWhileInactiveIsDroppedAndCounted` |
| M3 | unpaired repeat injected | `unpairedRepeatIsNeverInjected` |
| M4 | duplicate down injected | `duplicateDownIsDropped` |
| M5, M6, M7 | leave injects no releases; releases in reverse plan order; does not reset the ledger | `leaveReleasesInPlanOrderThenResetsAndBecomesInactive` |
| M8 | inbound clipboard skips the loop guard | `inboundClipboardPassesTheLoopGuardBeforeItIsApplied` |
| M9 | inject failure ignored | `injectFailureFailsClosed` |
| M10 | terminate does not close the session | `terminateReleasesEverything` |
| M11, M14 | terminate skips the cleanup hooks; a finished stream is not terminated | `streamEndReleasesEverything` |
| M12 | old generation events accepted | `oldGenerationStreamCannotInjectIntoTheNewSession` |
| M13 | new session allowed while the old one is open | `newGenerationStartsOnlyAfterTheOldCleanup` |
| M15 | new session allowed during the old cleanup (review note M1) | `beginSessionWaitsForAnInFlightCleanup` |
| M16 | run keeps reading a closed generation's stream (review note L2) | `runStopsReadingOnceItsGenerationIsClosed` |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Events consumed in order: enter, pointer, buttons, scroll, keys, clipboard both ways, leave | The scripted-session tests of the 31-test suite; mutants M1 to M4, M8 |
| Leave and every terminal path release all held input, in plan order, once | `leaveReleasesInPlanOrderThenResetsAndBecomesInactive`, `terminateReleasesEverything` (8 triggers), `streamEndReleasesEverything`; mutants M5 to M7, M10, M11, M14 |
| Nothing injects after cleanup; old generations cannot reach a new session | The platform model records any injection after the cleanup started; `oldGenerationStreamCannotInjectIntoTheNewSession`, `newGenerationStartsOnlyAfterTheOldCleanup`, `beginSessionWaitsForAnInFlightCleanup`; mutants M12, M13, M15 |
| Fail closed on injection failure | `injectFailureFailsClosed`, `runTerminatesWithTheInjectionFailureTrigger`; mutant M9 |
| Cleanup runs at most once per generation | A second cleanup does not run, asserted after every terminal path; `randomStreamsCutAtRandomPointsKeepTheInvariants` (300 seeded random streams cut by random terminal paths and injection failures) |
| Diagnostics hold no identifiers | Asserted after every terminal path; the component doc's Diagnostics section; independent review check |
| Architecture checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 332 tests with warnings as errors, `xcodebuild` build succeeded, `make verify` 24 of 24 |
| Manual evidence | Not applicable to this Tier C issue; the composition root's owner E2E is M4-020-FOLLOWUP-001 and later |

## Independent review

- A fresh-context Opus reviewer (Tier C strong review) returned APPROVE WITH CHANGES at head
  `559a911c`: Critical 0, High 0, Medium 1, Low 3 (`independent-review.md`). It judged the four
  declared deviations acceptable and found nothing injecting after cleanup, no key left held, no
  double cleanup, no old-generation leak and no identifiers in diagnostics.
- The reviewer ran `swift test --filter ClientCoordinator` (29 tests in 1 suite, passing) and
  `swift format lint --strict` (exit 0) in a detached worktree, and 6 mutants of its own, of which 5
  were killed and 1 survived (`beginSession()` allowed while cleaning).
- All four findings were addressed in `a9a0ec5`: the Medium by a new test, one Low by a documented
  limitation, one Low by a fix and a new test, one Low by a comment and doc correction.

## Merge

Pending owner approval.

## Known limitations

- A second `terminate` during an in-flight cleanup returns `ran == false` without waiting (review
  L1); the composition root must await its own `terminate` and treat `beginSession() == false` as
  wait, then retry.
- A release that could not be queued is freed in the ledger already, so only the injector sweep
  releases it; without the sweep the ledger's plan alone would not (component doc, Limits).
- Effects run with the lock held; an adapter that blocks stalls the session, as for
  `ServerCoordinator`.
- `ledgerSnapshot` carries an opaque clipboard transaction ID that must not be logged.
- Not verified by the reviewer: the full KVMCore suite and cigates (it relied on the PR evidence),
  the b.16 adapter, and RED against the committed suite.
- Source disagreement, stated rather than resolved: `commands.json` records its `make verify`
  context as commit `559a911c5b9dd6473e95707f133e498e28081a7f`, the reviewed head, although the
  gates ran after the review resolution (timestamps 03:53 to 03:54 and the 31-test and 332-test
  counts). The evidence was generated in the working tree before the `a9a0ec5` commit; the
  evidence is not tied to a clean commit by that field.
- Source disagreement: the RED run is 29 tests (27 failing, per the note) and the GREEN runs are 31
  tests, because the resolution added two; the reviewer's runs and the 29-test RED run are the
  pre-resolution suite.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21
clang-1700.6.3.2), arm64); the machine-readable test report is in `tests/`.

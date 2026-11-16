# M1-063 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/FailSafeCoordinator.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/FailSafeCoordinatorTests.swift`,
`docs/components/M1-063-fail-safe-coordinator.md`, and this directory.

`FailSafeCoordinator` is the client mirror of the server's `ServerFailSafe` and C-011's
InputSafetyController: the one ordered, idempotent, best-effort cleanup that every terminal path
of the client runs. `recover(plan:)` runs queue reset (`clearTransientState`), the ledger's
release plan (`ReleaseAllKeys.execute`), the injector sweep (`releaseRemaining`) and
`restoreLocalInput`, attempts every step after a failure, and reports a disposition (completed,
partial, failed, or notRequired when a recovery is already running). `FailSafeReport` holds
counts and step names only, never a key or button identity (Frozen Decision 8). The platform
side is the `ClientInputSafety` adapter protocol; the consumer is the first-party Linux client
(M4-SCOPE-001).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Step order | `clearTransientState`, then `ReleaseAllKeys.execute(plan)`, then `releaseRemaining()` (injector sweep), then `restoreLocalInput()`. Each step has its own do/catch and the sweep runs whatever the plan reported. | Client master plan b.4 and amendment h.1 (the lead's planning document, not in the repository). The injector's own record is the authority for what the platform holds, so the sweep releases what the queue reset dropped and what the ledger overflowed or never tracked. |
| How are the release dispositions counted? | `notRequired`: no work, no failure. `completed`: success. `partial`: one success and a failed step `releasePlan`. `failed`: a failed step `releasePlan`. Overall: completed when no step failed, failed when no step did work successfully, otherwise partial. A partial or failed plan is never swallowed. | Plan a.5, so the owner can report `inputSafety(.cleanupPartial)` or `.cleanupFailed`. |
| Reentrancy | `recover(plan:)` called while a recovery is running (another thread, or from inside a step) returns `notRequired` and runs nothing. `recoverJoiningInFlight(plan:)` waits for the running recovery and returns its disposition, or `lastDisposition` if it just finished. The lock guards only the flag, the last result and the waiters; steps run outside it. | The `ServerFailSafe.recoverAll` shape. |
| Who disconnects the session and resets the ledger? | Not this coordinator; left to M1-064 `CleanupHooks`, which runs the recovery, clears the ledger, then awaits the disconnect once per session generation. | Plan a.6.4 and b.6. |
| What must the adapter's drain worker be? | A dedicated `Thread`, never a `Task` on the cooperative pool: `clearTransientState` blocks while it joins the worker, and `recoverJoiningInFlight` calls `recover` from a pool thread, so a pool-hosted worker could deadlock. M1-064 runs `recover(plan:)` off the pool. Documentation only; no behavior change. | Review Minor-1, fixed in `6cd4337`. |
| The CI timeout in the first run | The first CI run hung: the in-flight test parked a cooperative-pool thread. Test-only fix in `6927697`: the blocked recovery runs on its own thread. At `6cd4337` every await in the tests also has a 10 s limit. | Commit messages; `commands.json` and mutations regenerated. |
| Extras beyond the b.4 API table | `lastReport: FailSafeReport?`, `FailSafeStep`, and `releasePlan(for: InputStateLedger)` (the h.7 mapping of held keys to `(key:, modifiers:)` pairs plus buttons). None carries an identity. | Review Nit; listed in the PR body as additions. |
| Which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | The root package, filtered to this suite, plus the full root suite. | `Packages/KVMCore` has no `Package.swift`; SwiftPM resolves the root package (285 tests). M1-046, M1-050, M1-060 and M1-061 record the same deviation. |
| No manual run and no `environment.json` | Accepted: the issue's Manual Verification is none required. | The real adapter is exercised by the Xvfb tests of M4-024 and the owner E2E (#351). |

## RED

Against a compiling stub whose `recover()` returned completed without running any step
(`commands.json`, first command, exit 1, recorded as an expected failure): 15 of the 17 tests
failed. The in-flight test then waited for a step that never came, so the test process was
stopped by hand.

## GREEN

At `6cd4337`:

- Focused: `✔ Test run with 17 tests in 2 suites passed after 0.002 seconds.`
- Full root package: `✔ Test run with 285 tests in 27 suites passed after 0.134 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 285 tests in 27 suites passed after 0.133
  seconds.`
- `swift test --package-path Packages/KVMCore`: `✔ Test run with 285 tests in 27 suites passed
  after 0.137 seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `** BUILD SUCCEEDED **`
  (`xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build`);
  `make verify`: 24 of 24 gates passed.
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml` (17 test cases).

## Mutation checks

17 mutants, each killed and restored byte for byte: `killedCount 17`, `mutantCount 17`,
`baselinePassed`, `allKilled`, `testsUntouched` and `allRestored` all true in
`mutations/mutations.json`. The runner is `mutations/run_mutations.py`. T1 to T8 are the terminal
steps, D1 to D5 the dispositions, I1 the double run, P1 the identity leak, L1 the ledger mapping,
R1 the reviewer's.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| T1 | `recover` never calls `clearTransientState` | 8 tests, 17 issues |
| T2 | `recover` never calls `releaseRemaining` | 10 tests, 22 issues |
| T3 | `recover` never calls `restoreLocalInput` | 9 tests, 21 issues |
| T4 | `releaseRemaining` moved ahead of `ReleaseAllKeys.execute` | 5 tests, 9 issues |
| T5 | `clearTransientState` moved after the sweep | 7 tests, 9 issues |
| T6 | `recover` returns failed as soon as `clearTransientState` throws | 2 tests, 5 issues |
| T7 | `recoverJoiningInFlight` returns `notRequired` instead of joining | 1 test, 4 issues |
| T8 | joiners resumed with completed instead of the run's disposition | 1 test, 3 issues |
| D1 | an empty plan is listed as a failed step | 2 tests, 2 issues |
| D2 | a completed plan is listed as a failed step | 6 tests, 11 issues |
| D3 | a partial plan is counted as a success | 1 test, 2 issues |
| D4 | a failed plan is counted as a success | 2 tests, 4 issues |
| D5 | a recovery with no successful step reports partial | 2 tests, 2 issues |
| I1 | a reentrant or concurrent call runs the steps again instead of `notRequired` | 3 tests, 14 issues |
| P1 | the report gains a field holding the plan's events | 1 test, 4 issues |
| R1 | the running flag is never reset | 1 test, 2 issues |
| L1 | `releasePlan(for:)` passes no buttons | 1 test, 1 issue |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Order: queue reset, ledger plan, injector sweep, restore | `happy path: queue reset, ledger plan, injector sweep, then restore, in that order`; mutants T1 to T5 |
| Every step is attempted after a failure | `failure: a failing step does not skip later steps`, `failure: every step failing reports failed and still attempts each`; mutant T6 |
| Release dispositions and the sweep | `release disposition notRequired: an empty plan still sweeps and reports completed`, `release disposition partial: the sweep still runs and the recovery reports partial`, `release disposition failed: the sweep is the next step and the recovery reports partial`, `boundary: an empty plan with every other step failing reports failed`; mutants D1 to D5 |
| Dropped, overflowed and untracked presses reach the sweep | `h.1: a release dropped with the queue is released only by the injector sweep`, `boundary: overflowed and untracked presses are released by the sweep`, `releasePlan(for:) maps held keys and buttons in ReleaseAllKeys order`; mutants T2, L1 |
| Idempotent and reentrant | `idempotent: a later recovery reruns the idempotent steps with no extra effect`, `reentrant: a recovery triggered during a recovery returns notRequired without running`, `concurrent recoveries never interleave steps`, `joiners wait for the in-flight recovery and get its result; the steps run once`, `an async caller with nothing in flight runs the recovery itself`; mutants I1, R1, T7, T8 |
| No key or button identity in the report; no logging | `privacy: the report carries no key or button identity`; mutant P1; Frozen Decision 8 |
| Consistent with the frozen decisions; no new public contract | package-only API; the doc's Order and Dispositions sections |
| Checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 285 root tests with warnings as errors, `** BUILD SUCCEEDED **`, `make verify` 24 of 24. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`). |
| Manual run on hardware | None required by the issue. See Known limitations. |

## Independent review

- After the PR, a fresh-context Opus reviewer started by the lead (`independent-review.md`)
  approved it at `6927697`: no Blocker or Major finding, 2 Minor, 1 Nit on the extras, and a
  Nit on a mutant that hung the tests. Minor-1 (the drain-thread requirement) is documented at
  `6cd4337`; Minor-2 is accepted as in plan b.4; the extras are recorded above; every test wait
  is now bounded at 10 s and mutant R1 is killed without hanging.
- The reviewer ran `swift build --build-tests` and the focused suite 20 times (20 of 20 passed)
  and four mutants of its own, all killed. It did not re-run the full suite or `make verify`;
  `commands.json` records them.

## Merge

Pending owner approval.

## Known limitations

- Proven only against a model adapter. The real Linux adapter is M4-024 and M4-020-FOLLOWUP-001,
  so the real injection worker, queue reset and sweep are exercised there (Xvfb) and by the owner
  E2E.
- A process crash runs no cleanup (risk f.9).
- The coordinator does not disconnect the session or reset the ledger; M1-064 `CleanupHooks` does,
  and must run `recover(plan:)` off the cooperative pool.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test report is in `tests/`.

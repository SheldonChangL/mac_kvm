# M1-064 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/CleanupHooks.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/CleanupHooksTests.swift`,
`docs/components/M1-064-cleanup-hooks.md`, and this directory.

`CleanupHooks` is the single funnel for every client terminal, error and cancel path (stream end,
transport or TLS failure, protocol violation, keepalive timeout, cancel, sleep, termination,
display loss). Each session generation gets exactly one logical cleanup: M1-063's
`FailSafeCoordinator.recover(plan:)` on a dedicated thread, then `clearLedger()`, then a
disconnect bounded by a `KVMClock` timeout. `CleanupOutcome` reports whether the cleanup ran, its
disposition and whether the disconnect timed out, and carries no key, button or event identity.
`trigger(for:)` maps a `DisconnectReason` to a trigger with an exhaustive switch. The consumer is
the first-party Linux client (M4-SCOPE-001).

## Decisions recorded

| Question | Decision | Basis |
| --- | --- | --- |
| Which thread runs the recovery? | A dedicated `Thread` named `mackvm-cleanup`, never the cooperative pool. Cleanups of different generations are serialized by a recovery lock that is held only on dedicated threads. | M1-063 independent review, Minor-1: `clearTransientState` blocks while it joins the injection worker, so a pool-hosted recovery could deadlock. |
| Is the disconnect bounded? | Yes. It runs after the recovery and the ledger clear, and is abandoned (its task cancelled) after `disconnectTimeout`, 2 s by default (`defaultDisconnectTimeout`). The outcome reports `disconnectTimedOut`; the releases have already run. A prompt disconnect cancels the timer, and a clock that throws counts as expired. | Plan a.6.4 and b.6; review Minor on the timer and the throwing clock, fixed in `24b2272`. |
| How is once per generation enforced? | `beginGeneration()` opens a token; `runOnce` closes it by an atomic remove under a lock. A repeat, a stale or an unissued generation gets `ran == false` and runs nothing. An older generation still cleans up after a newer one began. | Plan b.6. |
| The Linux thread name | Linux pthread names are at most 15 bytes. The first CI attempt failed because a longer name was not applied; `790cb0e` shortened it, and the second CI attempt still failed because the name was set from the creating side. `9817133` sets `Thread.current.name` inside the thread body. Two failed CI attempts before the third passed. | Commit messages; CI `verify-linux` run 43870323135 and, after `24b2272`, run 43872500440. |
| Extras beyond the b.6 API | Init parameters `clearLedger`, `clock`, `disconnectTimeout`; `CleanupOutcome.disconnectTimedOut` and `.skipped`; `CleanupHooks.defaultDisconnectTimeout`; `CleanupHooks.disconnectReason(for:)`; `CleanupGeneration.rawValue`. All package-scoped, none carries an identity. | Review: justified by testability; listed in the PR body. |
| Which tests does the issue's `swift test --package-path Packages/KVMCore` mean? | The root package, filtered to this suite, plus the full root suite. | `Packages/KVMCore` has no `Package.swift`; SwiftPM resolves the root package (`commands.json` note). M1-063 records the same deviation. |
| The off-pool test limitation | The test checks the recovery thread's name; it does not saturate the cooperative pool. A deterministic starvation test depends on the pool's width and is not attempted. Mutant P1 (recovery inline on the caller) is killed by the name check; Linux naming is covered by CI `verify-linux`. | Review Minor, accepted. |
| No manual run and no `environment.json` | Accepted: the issue has no mandatory hardware step. | The real adapter is exercised by the Xvfb tests of M4-024 and the owner E2E (#351). |

## RED

Against a compiling stub whose `runOnce()` returned `ran == false` without running anything
(`commands.json`, first command, exit 1, recorded as an expected failure): 9 of 14 tests failed
with 36 issues (`✘ Test run with 14 tests in 1 suite failed after 0.008 seconds with 36 issues.`).
The RED entry is carried over from the first run; the suite has since grown to 16 tests.

## GREEN

At `24b2272`:

- Focused: `✔ Test run with 16 tests in 1 suite passed after 0.003 seconds.`
- Full root package: `✔ Test run with 301 tests in 28 suites passed after 0.135 seconds.`; with
  `-Xswiftc -warnings-as-errors`, `✔ Test run with 301 tests in 28 suites passed after 0.152
  seconds.`
- `swift test --package-path Packages/KVMCore`: `✔ Test run with 301 tests in 28 suites passed
  after 0.411 seconds.`
- Both format lints (the two files, and the repository) exit 0; `docs check OK`; `architecture
  check OK`; `PACKAGE OK: 217 issues, 5 milestones, 17 epics`; `** BUILD SUCCEEDED **`
  (`xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination platform=macOS build`);
  `make verify`: 24 of 24 gates passed.
- Linux: CI `verify-linux` run 43872500440 passed on both jobs (the earlier run 43870323135 also
  ran the suite on Linux; the dedicated-thread test passed there).
- The machine-readable report is `tests/swift-testing-xunit-swift-testing.xml` (16 test cases).

## Mutation checks

16 mutants, each killed and restored byte for byte: `killedCount 16`, `mutantCount 16`,
`baselinePassed`, `allKilled`, `testsUntouched` and `allRestored` all true in
`mutations/mutations.json`. The runner is `mutations/run_mutations.py`.

| Id | Mutation | Failing tests |
| --- | --- | --- |
| O1 | the disconnect is awaited before the recovery | 6 tests, 15 issues |
| G1 | the generation check is removed: every caller runs | 3 tests, 7 issues |
| G2 | the generation is checked but never consumed | 2 tests, 5 issues |
| G3 | any generation is accepted | 3 tests, 7 issues |
| P1 | no thread is used: the recovery runs inline on the caller's pool thread | 1 test, 1 issue |
| L1 | `clearLedger` is never called | 7 tests, 16 issues |
| B1 | the disconnect timeout is reported as a normal disconnect | 2 tests, 2 issues |
| F1 | `runOnce` always reports completed | 1 test, 1 issue |
| M1 | `timeout(.keepalive)` maps to `transportFailure` | 2 tests, 2 issues |
| M2 | `cancellation(.shutdown)` maps to cancelled | 1 test, 1 issue |
| M3 | security errors map to `streamEnded` | 2 tests, 2 issues |
| M4 | `lifecycle(.subsystemUnavailable)` maps to `streamEnded` | 2 tests, 2 issues |
| R1 | cancelled disconnects with `cancellation(.requested)` | 1 test, 1 issue |
| R2 | termination disconnects with `userRequested` | 1 test, 1 issue |
| T1 | the disconnect path no longer cancels the timer | 1 test, 1 issue |
| T2 | a throwing timer resolves as not timed out | 1 test, 1 issue |

## Acceptance mapping

| Criterion | Tests and evidence |
| --- | --- |
| Every terminal, error and cancel path funnels into one cleanup | `each trigger runs the one cleanup in order: recovery, ledger clear, then disconnect`, `mapping table: every disconnect reason maps to its trigger`, `round trip: a trigger's disconnect reason maps back to the same trigger`; mutants M1 to M4, R1, R2 |
| Order: recovery, ledger clear, then disconnect | the order test above, `the releases finish before the disconnect starts, even when the disconnect hangs`; mutants O1, L1 |
| Exactly one cleanup per generation | `a second trigger for the same generation runs nothing`, `concurrent triggers for one generation: exactly one runs`, `a generation this instance never issued runs nothing`, `a new generation runs its own cleanup`, `an older generation not yet cleaned up still cleans up after a newer one began`; mutants G1 to G3 |
| A hung disconnect is bounded by the `KVMClock` timeout | `the releases finish before the disconnect starts, even when the disconnect hangs`, `a disconnect that finishes before the timeout is not reported as timed out`, `promptDisconnectCancelsTimer`, `throwingClockCountsAsExpired`; mutants B1, T1, T2 |
| A failed recovery is reported, never swallowed | `a failed recovery is reported, never swallowed, and the disconnect still runs`, `an empty plan still runs the sweep and the disconnect`; mutant F1 |
| Recovery runs off the cooperative pool | `the recovery runs on the dedicated cleanup thread, off the cooperative pool`; mutant P1; the Linux CI run |
| No key, button or event identity in the outcome | `the outcome carries no key, button or event identity` |
| Checker, lint, build and unit tests with no new warning | `commands.json`: architecture check OK, both lints exit 0, 301 root tests with warnings as errors, `** BUILD SUCCEEDED **`, `make verify` 24 of 24. The SwiftPM "unhandled files" warning predates this change (`Tests/SystemTests`). |
| Manual run on hardware | None required by the issue. See Known limitations. |

## Independent review

- After the PR, a fresh-context Opus reviewer started by the lead (`independent-review.md`)
  approved it at `9817133`: no Blocker or Major finding, 4 Minor and 1 Nit. The hung-recovery
  risk is documented; the timer cancellation and the throwing clock are fixed and pinned by tests
  and mutants T1 and T2 at `24b2272`; the off-pool test is not strengthened, for the reason given
  above; the reason-mapping Nit and the extras are accepted.
- The reviewer ran `swift build --build-tests` and the focused suite 20 times (20 of 20 passed),
  read the Linux CI log, and ran five mutants of its own: four killed, and one (deleting the
  in-thread name assignment) survived on macOS as expected, since only the Linux CI test covers it.
  It did not re-run the full suite or `make verify`; `commands.json` records them.

## Merge

Pending owner approval.

## Known limitations

- A hung recovery stalls later generations: an unbounded hang in `failSafe.recover` hangs `runOnce`
  and, through the recovery lock, every later generation's cleanup waits behind it, each parking one
  OS thread. M1-063's adapter contract requires prompt steps; only the disconnect is bounded here.
- Proven only against model adapters. Wiring to the session, `ReconnectManager`,
  `RecoveryCoordinator`'s sleep hook and the signal handlers is M4-020-FOLLOWUP-001.
- An abandoned disconnect task keeps running until it honours cancellation.
- A process crash runs no cleanup (risk f.9).
- The off-pool test proves the thread name, not pool starvation; Linux naming is covered by CI.

Full gates are in `commands.json` (toolchain Apple Swift version 6.2.3
(swiftlang-6.2.3.3.21 clang-1700.6.3.2)); the machine-readable test report is in `tests/`.

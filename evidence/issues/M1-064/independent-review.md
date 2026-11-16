# M1-064 Independent Review

- Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT)
- Date: 2026-11-17
- Target: PR #361 at `9817133`
- Verdict: APPROVE with minor findings, 4 Minor, 1 Nit, nothing blocks the merge

## Review (verbatim)

> Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT), 2026-11-17, target head 9817133 (PR #361).
> Verdict: APPROVE with minor findings. Nothing blocks the merge.
> Ran (detached worktree, removed): swift build --build-tests complete; swift test --filter CleanupHooks x20: pass=20 fail=0 (14 tests, 1 suite). CI run 43870323135 Linux log: the CleanupHooks (M1-064) suite ran on Linux; the dedicated-thread test passed in 0.098s; totals 118/2, 374/15, 15/3 tests passed ("Executed 0 tests" lines are XCTest shims). Own mutations (CleanupHooks.swift): M1 recovery inline on the pool KILLED (1 issue); M2 disconnect before recovery KILLED (15); M3 claim uses contains instead of remove KILLED (5); M4 .cancelled maps to .applicationTermination KILLED (2); M5 delete the in-thread Thread.current.name (line 126) SURVIVED on macOS, expected, only the Linux CI test covers it.
> Holding: exactly one cleanup per generation via atomic remove under the lock (:108), unknown or stale generations skipped; recovery and clearLedger under recoveryLock on a dedicated Thread before the bounded disconnect (:111-112); OnceGate resumes exactly once; cooperative pool never blocked, recoveryLock held only on dedicated threads, no deadlock with FailSafeCoordinator joiners; outcome carries no identity.
> MINOR :128: an unbounded hang in failSafe.recover hangs runOnce forever and, via recoveryLock, stalls every later generation, each parking one more OS thread; inherent, document as residual risk.
> MINOR :150-160: the timer Task is never cancelled when the disconnect finishes promptly; each cleanup leaves a sleeping Task for disconnectTimeout (2s); cancel on success.
> MINOR :153-155: a clock that throws at once counts as expired, abandoning the disconnect immediately; defensible, but no test pins it.
> MINOR test gap CleanupHooksTests.swift:318-324: the off-pool test checks only the thread name, does not saturate the pool; Linux naming (M5) covered only by the Linux CI run.
> NIT :208-209: disconnectReason(for: .cancelled) always gives .superseded; the round trip with trigger(for:) is lossy, acceptable.
> Extras beyond b.6 (clearLedger, clock, disconnectTimeout, disconnectTimedOut, skipped, disconnectReason(for:), rawValue): package-scoped, small, justified by testability.

## Resolution

Fixes are at `24b2272`; CI run 43872500440 passed on both jobs.

| Finding | Resolution |
| --- | --- |
| Minor (`:128`): an unbounded hang in `failSafe.recover` stalls every later generation | Documented as residual risk: a comment on `recoverOffPool`, the component doc and the summary's Known limitations. Not bounded in code; M1-063's adapter contract requires prompt steps. |
| Minor (`:150-160`): the timer Task is never cancelled when the disconnect finishes promptly | Fixed in `24b2272`: a prompt disconnect cancels the timer. Test `promptDisconnectCancelsTimer`; mutant T1 killed. |
| Minor (`:153-155`): a clock that throws counts as expired, with no test | Test `throwingClockCountsAsExpired` pins the behavior; mutant T2 killed. |
| Minor (test gap, `CleanupHooksTests.swift:318-324`): the off-pool test only checks the thread name | Not strengthened: a starvation test depends on the cooperative pool's width and cannot be reliable. Documented; mutant P1 is still killed by the thread-name check; Linux naming is covered by the CI `verify-linux` job. |
| Nit (`:208-209`): `disconnectReason(for: .cancelled)` is lossy against `trigger(for:)` | Accepted. |
| Extras beyond b.6 | Accepted; listed in the PR body and the summary. |

All 16 mutants are killed (`mutations/mutations.json`).

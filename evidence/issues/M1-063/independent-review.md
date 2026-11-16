# M1-063 Independent Review

- Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT)
- Date: 2026-11-16
- Target: PR #360 at `6927697`
- Verdict: APPROVE, 2 Minor, 1 Nit, no Blocker or Major

## Review (verbatim)

> Reviewer: fresh-context Opus agent, Tier C (STRONG_REVIEW_PROMPT), 2026-11-16, target head 6927697 (PR #360).
>
> Verdict: APPROVE, 2 Minor, 1 Nit, no Blocker or Major.
>
> Checked (FailSafeCoordinator.swift): order clearTransientState -> ReleaseAllKeys.execute(plan) -> releaseRemaining -> restoreLocalInput (:119-147) matches b.4 + h.1; each step in its own do/catch, no early return; the sweep runs whatever the plan's disposition. Dispositions (:125-156): notRequired neither failure nor success; partial counts one success and records a failed step; failed records a failed step; overall completed if no failed step, failed if no success, else partial; partial/failed plans are never swallowed. FailSafeReport (:40-60) holds dispositions, counts, step names only, no identity. Reentrancy: recovering flag checked and set under the lock, an in-flight call returns .notRequired (:109-114); joiners taken under the lock and resumed outside it (:160-167); recoverJoiningInFlight returns lastDisposition on the just-finished race (:179). Disconnect session left to M1-064 (doc :49-51), consistent with plan a.6 and b.6.
>
> Minor-1 (:108, :173-174): production has the same hazard as the CI test: recover is synchronous and runs clearTransientState (stop and join the injection worker, :19-20) on the caller's thread; recoverJoiningInFlight calls it from a cooperative-pool thread. If the drain worker is itself on the cooperative pool, a small pool can deadlock. Suggest documenting that the drain worker must be a dedicated Thread, and running recover off the pool in M1-064. Not blocking.
>
> Minor-2 (:190-201): waitForJoinedRecoveries is a test hook exposed as package API with joinerObservers in the production type; listed in plan b.4, so in scope.
>
> Nit: lastReport (:93), FailSafeStep (:31), releasePlan(for:) (:99) exceed the b.4 API table; harmless, no identity; releasePlan maps h.7; mark them in the PR as additions.
>
> Ran (detached worktree, removed): swift build --build-tests complete; swift test --filter FailSafeCoordinator 20 runs, 20/20 "17 tests in 2 suites passed". Own mutants, all killed: partial plan not recorded as failed step (2 issues); notRequired counted as success (1); joiner always resumed .completed (3); releaseRemaining skipped when plan completed (10). A fifth (recovering never reset) hung the tests >180 s and was killed by hand: no timeout on such hangs (Nit).

## Resolution

Fixes are at `6cd4337`; CI run 43822909173 passed.

| Finding | Resolution |
| --- | --- |
| Minor-1: drain worker on the cooperative pool can deadlock `clearTransientState` | Fixed in `6cd4337` as documentation: the `clearTransientState` protocol comment and the component doc require the drain worker to be a dedicated `Thread`, never a `Task` on the cooperative pool, and say M1-064 runs `recover(plan:)` off the pool. No behavior change. |
| Minor-2: `waitForJoinedRecoveries` test hook as package API | Accepted: it is in plan b.4. |
| Nit: `lastReport`, `FailSafeStep`, `releasePlan(for:)` exceed the b.4 table | The PR body lists them as additions beyond b.4; `releasePlan` maps h.7. |
| Nit: a mutant (running flag never reset) hung the tests for more than 180 s | Every await in the tests now has a 10 s limit; the new mutant R1 is killed by the idempotent test without hanging; 17 of 17 mutants killed. |

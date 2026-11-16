# M1-063 Fail-safe Coordinator

## Outcome

`KVMCore` provides `FailSafeCoordinator`, the `ClientInputSafety` adapter
protocol, `FailSafeStep` and `FailSafeReport` in
`Packages/KVMCore/Sources/KVMCore/FailSafeCoordinator.swift`, with `package`
access. It is the client mirror of the server's `ServerFailSafe` and the
client's C-011 InputSafetyController: the one ordered, idempotent and
best-effort cleanup that every terminal path of the client runs, so nothing
the client injected stays pressed. Everything here is first-party policy. It
never logs, and its report never carries a key or button identity (Frozen
Decision 8).

## API

| Member | Meaning |
|---|---|
| `ClientInputSafety` | Platform adapter: `release(_:)` (from M1-050's `InputReleaser`), `clearTransientState()`, `releaseRemaining()`, `restoreLocalInput()`; all synchronous, idempotent, best effort |
| `init(safety:)` | Coordinator over one adapter |
| `recover(plan:) -> CleanupDisposition` | Runs the recovery synchronously; `notRequired` at once if one is already running |
| `recoverJoiningInFlight(plan:) async` | Runs the recovery, or waits for the running one and returns its result |
| `waitForJoinedRecoveries(count:) async` | Test barrier: returns once `count` callers are waiting |
| `lastReport: FailSafeReport?` | Counts and step names of the last finished recovery |
| `releasePlan(for: InputStateLedger) -> ReleasePlan` | Maps the ledger's held keys to `(key:, modifiers:)` pairs and its buttons into `ReleaseAllKeys.plan` (plan h.7) |

C-011 names `releaseAllKeys`, `releaseAllMouseButtons`, `restoreLocalInput` and
`clearTransientState`. The first two are one `ReleaseAllKeys.execute` over the
plan, which orders non-modifier keys, then buttons, then modifier keys (M1-050).

## Order

Every call runs these steps in this order and attempts each even when an
earlier one fails:

1. `clearTransientState()`: the adapter stops and joins the injection worker,
   then resets the injection queue and drops pending clipboard work (plan a.3,
   h.6), so no queued or already-dequeued press is injected after the releases.
2. `ReleaseAllKeys.execute(plan)`: the ledger's release plan.
3. `releaseRemaining()`: the injector sweep (plan h.1). The injector's own
   record of what it pressed is the authority for what the platform holds, so
   the sweep releases releases that the queue reset dropped after the ledger
   had already freed the key, and presses the ledger overflowed or never
   tracked (M1-062 `overflowed…Count`, `untracked…Count`). It always runs,
   whatever step 2 reported.
4. `restoreLocalInput()`: a no-op on a client that never suppresses local
   input; kept for C-011.

The coordinator does not disconnect the session or reset the ledger. Per plan
a.6.4 and b.6, `CleanupHooks` (M1-064) runs this recovery, clears the ledger
and then awaits the disconnect, once per session generation.

## Dispositions

| `ReleaseAllKeys` disposition | Counted as | Next step |
|---|---|---|
| `notRequired` (empty plan) | no work, no failure | sweep |
| `completed` | success | sweep |
| `partial` | some success and a failure; `releasePlan` is listed in `failedSteps` | sweep, which retries whatever the platform still holds |
| `failed` | failure; `releasePlan` is listed in `failedSteps` | sweep, as above |

The recovery reports `completed` when no step failed, `failed` when no step did
any work successfully (an empty plan does none), and `partial` otherwise. A
`partial` or `failed` plan is never swallowed: even when the sweep succeeds the
recovery reports at most `partial`, so the owner can report
`inputSafety(.cleanupPartial)` or `.cleanupFailed` (plan a.5).

## Reentrancy and idempotency

- The steps run outside the lock; the lock only guards the running flag, the
  last result and the waiting callers, so no step can deadlock the coordinator.
- A `recover(plan:)` made while a recovery is running (from another thread, or
  from inside a step) returns `notRequired` at once and runs nothing.
- `recoverJoiningInFlight(plan:)` waits for the running recovery and returns
  its disposition, as `ServerFailSafe.recoverAll` does.
- A later call after a recovery finished runs the steps again. The adapter's
  calls are idempotent, so a second run has no further effect on the platform.

## Privacy

`FailSafeReport` holds `releaseDisposition`, `releaseAttempted`,
`releaseFailed`, `failedSteps` (step names) and `disposition`. A test walks it
by reflection and checks its description, so no key, button or event can be
added to it unnoticed.

## Evidence and known limitations

- Tests: `Packages/KVMCore/Tests/KVMCoreTests/FailSafeCoordinatorTests.swift`,
  with a model adapter that records calls and models the platform's held set
  and the injection queue. Mutations: `evidence/issues/M1-063/mutations/`.
- The real adapter (queue reset, worker join, `releaseAllHeld()` sweep, XSync)
  is the Linux composition root's (M4-024, M4-020-FOLLOWUP-001); this issue
  proves the coordinator's order and accounting against the model only.
- A process crash runs no cleanup (plan risk f.9).

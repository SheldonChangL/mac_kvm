# M2-007 EventTap Start/Stop/Restart Lifecycle

## Outcome

`KVMCore` now has `EventTapLifecycle`, the `EventTapControl` protocol and
`EventTapRestartDecision`. Declarations are `package`. The concrete
`CGEvent.tapCreate` control lives in the platform layer (not part of this
Issue's Exact Files).

## Rules

- `start()` installs once; repeated starts are no-ops; install failure leaves
  the tap stopped and rethrows the typed error.
- `stop()` removes once; repeated stops are no-ops.
- `handleSystemDisable()`: the owner has already failed open through M2-013;
  the lifecycle re-enables the tap at most `restartBudget` (0...10) times per
  start, then removes it and returns `gaveUp` so capture stays failed open.
  Not running → `notRunning`.
- `terminate()` removes the tap and blocks later starts with
  `lifecycle.termination`, so application termination always releases it.

One `NSLock` guards state; nothing awaits or logs.

## Tests

`EventTapLifecycleTests` (6): idempotent start/stop, install failure, restart
budget and give-up, budget reset on a fresh start, terminate, invalid budget.

## Known limitations

Real tap installation, run-loop integration and system disable behavior
need hardware verification.

## Rollback

Revert the three M2-007 files.

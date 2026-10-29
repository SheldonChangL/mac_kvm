# M2-033 Server-side Fail-safe and Local Recovery Coordinator

## Outcome

`KVMCore` now has `ServerFailSafe` and the `ServerLocalInputSafety` protocol
(C-011 operations for the server role). Declarations are `package`.

## Rules

- `recoverLocal()` is synchronous and never awaits. Fixed order: stop
  suppression, release all keys, release all mouse buttons, restore the local
  cursor, clear transient state.
- Every step is attempted even if an earlier one fails. The result is
  `completed`, `partial` or `failed`.
- Reentrant: a call made while a recovery is running (for example from inside
  a step, or from another thread) returns `notRequired` immediately; it never
  recurses or blocks.
- Repeated recoveries rerun the idempotent steps.
- `recoverAll(sessions:reason:afterLocalRestore:)` restores local input first,
  and only then awaits `SessionManager.closeAll`, so remote teardown can never
  delay local restoration. It returns `RecoveryOutcome`: the disposition and,
  when an active target was cleared, its `sessionLost` action for the reducer.

Any session, tap or router failure maps to one of the reducer's forced-local
actions; the owner then calls `recoverLocal()` (the `restoreLocal` effect).

## Tests

`ServerFailSafeTests` (7): order, partial failure, total failure, repeated
recovery, reentrancy, concurrent recoveries without interleaving, local-first
`recoverAll`. Five repeated runs passed.

## Known limitations

The platform implementation of `ServerLocalInputSafety` (event tap
suppression, CGEvent key/button release, cursor warp) is owned by M2-013 and
M2-021 and requires real-hardware verification.

## Rollback

Revert the three M2-033 files.

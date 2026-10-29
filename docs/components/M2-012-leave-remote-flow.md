# M2-012 Remote → LeavingRemote → Local Flow

## Outcome

`KVMCore` now has `LeaveRemoteFlow` and `LeaveIntent`. Declarations are
`package`.

## Behavior

- Return edge: `intent(for:target:leftThrough:)` turns the M2-019 tracker's
  `returned(offset:)` into `returnEdge(target:localPosition:)` using the
  M2-020 `ReturnCoordinateMapper`, and returns the local re-entry point for
  the M2-021 cursor restorer. Any other motion yields no intent.
- Escape: `escapeAction` is `emergencyEscape` (M2-014).
- Disconnect: `sessionEndAction(for:)` is `sessionLost(target)`.

The M2-008 table executes the leave local-first: suppression is disabled
before the leave is sent, `leavingRemote` already routes locally, and
`leaveCompleted` returns to `local`. Repeated and stale leaves are no-ops.

## Tests

`LeaveRemoteFlowTests` (3): return-edge intent and re-entry point, escape and
session-end triggers, leave sequence with repeated and stale leaves.

## Rollback

Revert the three M2-012 files.

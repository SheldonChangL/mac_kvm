# M2-008 Local / EnteringRemote / Remote / LeavingRemote Transition Table

## Status

Proposed on 2026-10-27 under the Product Owner M2 execution-order pivot.
`M1-062` (Input State Ledger) is not merged; this table does not depend on its
API. Held key/button bookkeeping stays owned by M1-062/M1-063 and M2-033 and is
represented here only as abstract effects. Acceptance requires a
non-implementing reviewer.

## Binding sources

- `docs/adr/M2-001-mac-server-safety-model.md`
- `MacKVM_Implementation_Package_v2/CONTRACT_CATALOG.md` C-011, C-012, C-013
- `MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md` item 7

## Decision

The input state is exactly one of four explicit states. There is no separate
`isRemote` boolean anywhere; suppression is derived from the state.

| State | Meaning | Local suppression |
|---|---|---|
| `local` | Input stays on the Mac | off |
| `enteringRemote(target)` | Enter sent, waiting for commit | off |
| `remote(target)` | Committed; input is routed to `target` | on |
| `leavingRemote(target)` | Leave in progress; input already local | off |

`target` is the remote `ScreenID`. An action naming a different target than
the current one is stale and ignored.

### Commit, rollback and timeout

- Commit: the protocol adapter reports that the enter for the same target was
  delivered (`enterDelivered`). For the Barrier subset this is the successful
  completion of the enter frame send; no client acknowledgement frame is frozen.
- Rollback: `enterFailed` or `enterTimeout` returns to `local`.
- Timeout: the enter timeout is started on entry to `enteringRemote` and is
  cancelled on every exit from it. Its duration is caller configuration, not a
  wire value.

### Activation precondition

`edgeActivated` is emitted (M2-010) only while no local key or mouse button
is held. Otherwise the matching release would arrive while suppression is on,
be swallowed, and leave the key or button stuck on the Mac after return. The
table below therefore never needs to synthesize local releases on a normal
return; forced-local paths still emit `restoreLocal`.

### Transition table

Effects are listed in execution order. `restoreLocal` means: stop suppression,
release locally held state and restore the local cursor (C-011). Effects
marked best effort must not block or fail the transition.

| State | Action | Next | Effects |
|---|---|---|---|
| local | edgeActivated(t, p) | enteringRemote(t) | saveLocalCursor, sendEnter(t, p), startEnterTimeout(t) |
| local | emergencyEscape / captureFailure / lifecycle | local | restoreLocal |
| local | any other | local | none |
| enteringRemote(t) | enterDelivered(t) | remote(t) | cancelEnterTimeout(t), enableSuppression |
| enteringRemote(t) | enterFailed(t) / enterTimeout(t) | local | cancelEnterTimeout(t), sendLeave(t) best effort, restoreLocal |
| enteringRemote(t) | sessionLost(t) | local | cancelEnterTimeout(t), restoreLocal |
| enteringRemote(t) | emergencyEscape / captureFailure / lifecycle | local | cancelEnterTimeout(t), sendLeave(t) best effort, restoreLocal |
| enteringRemote(t) | edgeActivated(any) | enteringRemote(t) | none (deduplicated) |
| enteringRemote(t) | any other or stale target | enteringRemote(t) | none |
| remote(t) | returnEdge(t, p) | leavingRemote(t) | disableSuppression, releaseRemoteInput(t), sendLeave(t), restoreLocalCursor(p) |
| remote(t) | emergencyEscape / captureFailure / lifecycle | local | disableSuppression, releaseRemoteInput(t) best effort, sendLeave(t) best effort, restoreLocal |
| remote(t) | sessionLost(t) | local | disableSuppression, restoreLocal |
| remote(t) | any other or stale target | remote(t) | none |
| leavingRemote(t) | leaveCompleted(t) | local | none |
| leavingRemote(t) | sessionLost(t) / emergencyEscape / captureFailure / lifecycle | local | restoreLocal |
| leavingRemote(t) | any other or stale target | leavingRemote(t) | none |

Invariants checked by M2-009 tests over every state × action pair:

1. `enableSuppression` is emitted only on the transition into `remote`.
2. Every transition out of `remote` emits `disableSuppression` or
   `restoreLocal` first.
3. Emergency escape, capture failure and lifecycle reach `local` from every
   state in one step and never wait for a remote response.
4. Repeating any action is safe: the second application is a no-op or the
   idempotent `restoreLocal`.

## Rejected alternatives

- Implicit boolean remote flag: rejected (cannot express commit window).
- Suppressing during `enteringRemote`: rejected by M2-001.
- Waiting in `leavingRemote` with suppression on: rejected; leave is
  local-first.

## Rollback

Revert this ADR and M2-009. M2-010 through M2-014 return to blocked state.

## Traceability

Issue: `MacKVM_Implementation_Package_v2/issues/M2/M2-008-input-state-table.md`.

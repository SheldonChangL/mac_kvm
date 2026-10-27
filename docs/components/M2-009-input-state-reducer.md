# M2-009 InputState Reducer

## Outcome

`KVMCore` now has `InputStateReducer`, a pure implementation of the M2-008
transition table (C-012). It maps `InputState` + `InputAction` to the next
state plus ordered `InputEffect` values. It performs no side effect and has no
clock, network, UI or platform dependency.

All declarations are `package`; no public API is added.

## API

| Declaration | Purpose |
| --- | --- |
| `InputState` | `local`, `enteringRemote`, `remote`, `leavingRemote`; `suppressesLocalInput` is true only for `remote` |
| `InputAction` | edge activation, enter delivered/failed/timeout, return edge, leave completed, session lost, emergency escape, capture failure, lifecycle |
| `InputEffect` | save/restore cursor, send enter/leave, start/cancel enter timeout, enable/disable suppression, release remote input, `restoreLocal` |
| `InputEffectDelivery` | `required` or `bestEffort` for recovery sends |
| `InputStateReducer.reduce(_:_:)` | total, deterministic transition function |

## Design

- There is no remote boolean. Suppression is derived from the state.
- Actions naming a target other than the current one are stale and ignored.
- Emergency escape, capture failure and lifecycle triggers reach `local` in one
  step from every state and never wait for a remote response.
- `leavingRemote` already has suppression disabled; `leaveCompleted` is sent by
  the executor once the leave send finished, whether it succeeded or not.

## Tests

`Packages/KVMCore/Tests/KVMCoreTests/InputStateReducerTests.swift` covers the
happy path, rollback, forced-local from every state, session loss, stale and
duplicate actions, the suppression invariant over every state × action pair,
idempotency and totality.

## Privacy

The reducer handles only identifiers and normalized positions; it never sees
key identity, typed text or clipboard content.

## Known limitations

- Held-key bookkeeping (M1-062) is not merged; `restoreLocal` and
  `releaseRemoteInput` are effects whose executors are owned by M2-033.
- Multi-target switching while remote is ignored in the MVP.

## Rollback

Revert the three M2-009 files. No other file depends on them at this commit.

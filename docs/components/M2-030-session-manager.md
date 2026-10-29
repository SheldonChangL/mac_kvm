# M2-030 Multi-client SessionManager

## Outcome

`KVMCore` now has `SessionManager`, `SessionManagerError` and
`SessionRemoval`. Declarations are `package`.

## Rules

- `[SessionID: ServerSession]` plus a one-to-one screen index: at most one
  session per remote screen; capacity `1...8`.
- Exactly zero or one active target. `activate` requires a registered screen;
  `deactivate` is idempotent.
- A rejected registration (duplicate id, duplicate screen, capacity) closes the
  rejected session before throwing, so no connection leaks.
- `remove` and `closeAll` mutate state before any await and then close the
  removed sessions. Removing the active target clears it and returns
  `removedActive(screen)` so the owner reports `sessionLost` to the reducer.
- The manager is the lifecycle owner: sessions it holds are closed only
  through it.

## Tests

`SessionManagerTests` (5): lifecycle, rejections with cleanup, unique active
target, idempotent `closeAll`, concurrent register/remove/activate. Five
repeated runs passed.

## Rollback

Revert the three M2-030 files.

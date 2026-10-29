# M2-031 ScreenRouter Target Selection

## Outcome

`KVMCore` now has `ScreenRouter`, `RouteDecision` and `EdgeTarget` (C-013).
Declarations are `package`. The router is pure and never sends.

## Rules

- `linkedEdges`: local edges with a topology neighbor; feeds `EdgeDetector`.
- `target(across:available:)`: `target(screen)` only when the edge is linked
  and that screen has a ready session; otherwise `unlinked` or `unavailable`,
  and the owner does not emit `edgeActivated`.
- `route(_:available:)`: only committed `remote(screen)` routes remotely, and
  only to a direct neighbor that still has a session. `local`,
  `enteringRemote` and `leavingRemote` route locally.
- An invalid or session-less committed target is `rollback(screen)`; its
  `recoveryAction` is `sessionLost(screen)` for `InputStateReducer`, which
  disables suppression and restores local input.

## Tests

`ScreenRouterTests` (6): linked edges, activation, missing/unlinked targets,
routing per state, rollback, invalid local screen.

## Known limitations

Remote-to-remote hops (for example Linux → a third screen) are not routed in
the MVP; they yield a rollback.

## Rollback

Revert the three M2-031 files.

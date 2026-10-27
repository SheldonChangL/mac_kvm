# M2-029 Server Session Lifecycle Actor

## Outcome

`KVMCore` now has `ServerSession`, an actor owning one protocol-neutral
(`KVMProtocolSession`, C-003) client session for the server role, and
`ServerSessionState`. Declarations are `package`.

## Lifecycle

`idle` → `connecting` → `ready` → `entering` → `active` → `ready` …; any → `closed`

| Call | Requires | Effect |
| --- | --- | --- |
| `start()` | idle | `connect()`; `ready`, or `closed` on failure |
| `enter(at:)` | ready | `entering` while `enterScreen` is written; then `active` |
| `forward(_:)` | active | sends the event |
| `leave()` | active / entering | active: `ready`, then sends `leaveScreen`; entering: closes the session (superseded) so the peer is never left entered |
| `close(reason:)` | any | disconnects once; idempotent |
| `monitorPeer()` | any | drains the peer stream; closes with `transportClosed` or the failure |

## Rules

- Single writer: a FIFO gate inside the actor keeps sends in call order even
  when a send suspends (actor reentrancy).
- Any connect or send failure is terminal: one disconnect with
  `.failure(error)`, then the error is rethrown so the owner reports
  `sessionLost` to `InputStateReducer`.
- Wrong-state calls fail with `internal.preconditionFailed` and no side
  effect; calls after close fail with `lifecycle.subsystemUnavailable`.
- Inbound client events are not routed in the MVP and are dropped without
  inspection. The session never logs or inspects event content.

## Tests

`ServerSessionTests` (8): lifecycle, connect failure, send failure,
enter failure, wrong-state calls, single-writer ordering under suspension,
idempotent close, peer end. Six repeated runs passed.

## Rollback

Revert the three M2-029 files.

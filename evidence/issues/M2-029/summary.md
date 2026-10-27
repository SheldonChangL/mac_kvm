# M2-029 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ServerSession.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ServerSessionTests.swift`,
`docs/components/M2-029-server-session.md`.

## RED

Before the implementation existed: `cannot find type 'ServerSession' in scope`.

## GREEN

`swift test --filter ServerSession`: 8 tests passed; 6 repeated runs passed.
Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| handshake → ready → active → closing | `lifecycle`, `connectFailure` |
| single writer / event ordering | `singleWriter` |
| terminal path cleanup | `sendFailure`, `enterFailure`, `closeIdempotent`, `peerEnd` |
| invalid input | `wrongState` |

## Deviations

M2-026 and M2-027 (input encoders) are blocked by unfrozen wire contracts, so
a Barrier-backed session cannot forward input yet; this actor is
protocol-neutral and does not depend on them.

## Review

Pending independent review.

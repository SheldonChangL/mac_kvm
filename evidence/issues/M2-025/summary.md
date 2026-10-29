# M2-025 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierServerHandshake.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierServerHandshakeTests.swift`,
`docs/components/M2-025-barrier-server-handshake.md`.

## RED

Before the implementation existed, `swift build --build-tests --package-path
Packages/BarrierCompatibility` failed (emit-module: `BarrierServerHandshake`
not found).

## GREEN

`swift test --package-path Packages/BarrierCompatibility --filter
BarrierServerHandshake`: 8 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| negotiation per server wire contract | `happyPath` golden frames from BARRIER-EVID-0005 |
| screen/client identity validation | `unknownScreen`, `invalidHelloBack`, `configuration` |
| failed handshake creates no active session | sticky `failed` state; `ordering`, `timeoutAndCancel` |
| no sensitive logging | `privacy` |

## Deviations

- Dependency M2-024 (listener) is not yet committed; the handshake is sans-IO
  and does not depend on it.
- Contract source M2-023 is Proposed, not Accepted.

## Review

Pending independent protocol review.

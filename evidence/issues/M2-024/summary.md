# M2-024 Evidence Summary

## Scope

Files: `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierListenerTransport.swift`,
`Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierListenerTransportTests.swift`,
`docs/components/M2-024-barrier-listener-transport.md`.

## RED

Before the implementation existed the test target failed to build:
`cannot find type 'BarrierListenerPolicy' in scope`.

The first GREEN attempt hung: the test's manual clock ignored cancellation,
so the cancelled timeout child never returned. The test clock was fixed to
honour cancellation as the `KVMClock` contract requires; production code was
unchanged by that fix.

## GREEN

`swift test --package-path Packages/BarrierCompatibility --filter
BarrierListenerTransport`: 6 tests passed, 10 of 10 repeated runs passed under
a 60 s per-run timeout. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| accept connection → Transport session | `admit` |
| connection limits / timeouts | `capacity`, `connectTimeout`, `policyBounds` |
| listener error does not affect local input | no input dependency; typed errors only (`connectFailure`, `stop`) |

## Deviations / blockers

- Concrete socket listener and server TLS are out of this file by
  architecture rule and blocked by the missing server identity decision.
- Contract source M2-023 is Proposed.

## Review

Pending independent review.

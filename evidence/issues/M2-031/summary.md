# M2-031 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ScreenRouter.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ScreenRouterTests.swift`,
`docs/components/M2-031-screen-router.md`.

## RED

Before the implementation existed: `cannot find type 'ScreenRouter' in scope`.

## GREEN

`swift test --filter ScreenRouter`: 6 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| input state + topology → target session | `activation`, `routing` |
| invalid/missing target rollback | `rollback`, `noTarget` |
| route effects testable | pure `RouteDecision` / `recoveryAction` |

## Review

Pending independent review.

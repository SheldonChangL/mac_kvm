# M2-007 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/EventTapLifecycle.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/EventTapLifecycleTests.swift`,
`docs/components/M2-007-event-tap-lifecycle.md`.

## RED

Before the implementation existed: `cannot find type 'EventTapControl' in
scope`. A test function name shadowed the `installFailure` constant and was
renamed.

## GREEN

`swift test --filter EventTapLifecycle`: 6 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| start/stop idempotent | `idempotent`, `installFails` |
| controlled restart after system disable | `restartBudget`, `budgetReset` |
| app terminate releases the tap | `terminate` |

## Manual verification

Required on hardware; not performed.

## Review

Pending independent review.

# M2-012 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/LeaveRemoteFlow.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/LeaveRemoteFlowTests.swift`,
`docs/components/M2-012-leave-remote-flow.md`.

## RED

Before the implementation existed: `cannot find type 'LeaveRemoteFlow' in
scope`.

## GREEN

`swift test --filter LeaveRemoteFlow`: 3 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| return edge / escape / disconnect trigger leave | `returnEdge`, `otherTriggers` |
| send leave then restore local | `sequence` (sendLeave, then leaveCompleted → local) |
| reentrant and repeated leave safe | `sequence` (repeat and stale no-ops) |

## Deviations

Dependency M2-011 (commit/rollback/timeout) is implemented by the M2-009
reducer table; no separate M2-011 file exists. Real-hardware verification not
performed.

## Review

Pending independent review.

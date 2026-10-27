# M2-003 Evidence Summary

## Scope

`CaptureQueue` bounded capture handoff. Files:
`Packages/KVMCore/Sources/KVMCore/CaptureQueue.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/CaptureQueueTests.swift`,
`docs/components/M2-003-capture-queue.md`.

## RED

`swift build --build-tests` failed with `cannot find type 'CaptureQueue' in
scope` before the implementation existed.

## GREEN

`swift test --filter CaptureQueue`: 12 tests passed; repeated 6 consecutive
runs, all passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| callback does not await async work | `enqueue` is synchronous; lock-only critical section |
| bounded queue / drop / coalesce rules | `invalidCapacity`, `moveCoalescing`, `scrollCoalescing`, `fullDropsMove`, `wrapAround` |
| key/button never silently dropped | `overflowLatches`, `overflowAfterServe` (typed `inputSafety.cleanupRequired`) |
| cancel / cleanup / idempotency | `cancellation`, `closeIsIdempotent`, `reset` path |

## Deviations

- `Packages/KVMCore` has no `Package.swift`; tests run in the root package.
- Dependency M1-020 async harness is a Python tool; the Swift tests use the
  queue's own `waitForPendingConsumer()` barrier instead of sleeps.

## Review

Pending independent review.

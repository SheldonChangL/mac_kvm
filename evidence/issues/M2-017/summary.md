# M2-017 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/EdgeDetector.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/EdgeDetectorTests.swift`,
`docs/components/M2-017-edge-detector.md`.

## RED

With the implementation absent, `swift build --build-tests` failed with
`cannot find 'EdgeDetector' in scope`.

## GREEN

`swift test --filter EdgeDetector`: 9 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| configurable 50-100 ms delay | `configurationBounds`, `activation`, `tickActivation` |
| 20-40 px corner/dead zone | `configurationBounds`, `corners` |
| leaving the edge cancels | `cancellation`, `corners`, `rearm` |
| invalid input / cleanup | `invalidSamples`, `reset` |

## Manual verification

The Issue requires real-hardware verification of the feel of the delay; not
performed (no live session). Status: unit-verified only.

## Review

Pending independent review.

# M2-020 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ReturnCoordinateMapper.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ReturnCoordinateMapperTests.swift`,
`docs/components/M2-020-return-coordinate-mapper.md`.

## RED

With the implementation absent, `swift build --build-tests` failed with
`cannot find 'ReturnCoordinateMapper' in scope`.

## GREEN

`swift test --filter ReturnCoordinateMapper`: 5 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| remote edge position → local re-entry point | `reentry`, `normalized` |
| clamp / dead zone | `cornerClamp`, `invalid` |
| no immediate re-switch | `avoidsImmediateReswitch` |

Real-hardware verification not performed.

## Review

Pending independent review.

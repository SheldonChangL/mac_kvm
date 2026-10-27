# M2-019 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/OutboundCoordinateMapper.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/OutboundCoordinateMapperTests.swift`,
`docs/components/M2-019-outbound-coordinate-mapper.md`.

## RED

With the implementation absent, `swift build --build-tests` failed with
`cannot find 'OutboundCoordinateMapper' in scope`.

## GREEN

`swift test --filter OutboundCoordinateMapper`: 8 tests passed. Full gates in
`commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| local normalized → remote logical coordinate | `entryPoints`, `normalized`, `tracking` |
| different scaling/rotation bounds | logical-size-only API; `tracking`, `invalidConfiguration` |
| no backing pixel ratio | no scale input exists in the API |
| invalid input | `offsetClamping`, `invalidConfiguration`, `invalidLocalSize` |

## Deviations

Dependency M1-039 (client coordinate mapper) is not merged; this mapper does
not consume it. Real-hardware verification is not performed.

## Review

Pending independent review.

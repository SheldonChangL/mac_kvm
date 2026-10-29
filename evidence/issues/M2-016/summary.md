# M2-016 Evidence Summary

## Scope

`ScreenTopology` validation in KVMContracts. Files:
`Packages/KVMContracts/Sources/KVMContracts/ScreenTopology.swift`,
`Packages/KVMContracts/Tests/KVMContractsTests/ScreenTopologyTests.swift`,
`docs/components/M2-016-screen-topology.md`.

## RED

`swift build --build-tests --package-path Packages/KVMContracts` failed with
`cannot find 'ScreenTopology' in scope` before the implementation existed.
During GREEN, one test JSON fixture used the wrong `ScreenID` encoding shape;
the fixture was corrected to the existing keyed `rawValue` encoding (the
production encoding was not changed).

## GREEN

`swift test --package-path Packages/KVMContracts`: 63 tests passed (7 new).
Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| left/right/top/bottom links | `reciprocal`, `opposites` |
| self/conflicting links rejected | `invalid`, `conflicting` |
| deterministic serialization/validation | `serialization`, `screenLimit` |

## Review

Pending independent review.

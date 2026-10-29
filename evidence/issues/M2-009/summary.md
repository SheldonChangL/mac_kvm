# M2-009 Evidence Summary

## Scope

Pure `InputStateReducer` implementing the proposed M2-008 transition table.
Files: `Packages/KVMCore/Sources/KVMCore/InputStateReducer.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/InputStateReducerTests.swift`,
`docs/components/M2-009-input-state-reducer.md`.

## RED

Before the implementation existed, `swift build --build-tests` failed with
`cannot find type 'InputState' in scope` in the new test file.

## GREEN

`swift test --filter InputStateReducer`: 8 tests in 1 suite passed. Full gates
in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| state + action → state + effects | `reduce(_:_:)`; `happyPath`, `rollback` tests |
| no network/UI side effect | reducer imports only `KVMContracts`; architecture check OK |
| full transition table tests | `suppressionInvariant`, `idempotency`, `totality` over all states × actions |
| boundary / invalid / cleanup | `staleAndDuplicate`, `forcedLocal`, `sessionLossInRemote` |

## Deviations

- The Issue lists `swift test --package-path Packages/KVMCore`; `Packages/KVMCore`
  has no `Package.swift` in this repository, so `KVMCoreTests` run from the root
  package (`swift test`, included in `make code-quality-check` with
  warnings-as-errors).
- Dependency M2-008 is a Proposed ADR, and M1-062 is not merged; the
  Product Owner pivot authorizes M2 sequencing ahead of M1 only.

## Review

Pending independent review. No manual verification is required by the Issue.

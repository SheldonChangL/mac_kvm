# M2-033 Evidence Summary

## Scope

Files: `Packages/KVMCore/Sources/KVMCore/ServerFailSafe.swift`,
`Packages/KVMCore/Tests/KVMCoreTests/ServerFailSafeTests.swift`,
`docs/components/M2-033-server-fail-safe.md`.

## RED

Before the implementation existed: `cannot find type 'ServerLocalInputSafety'
in scope`. A first implementation using an array of typed-throws closures did
not compile for the macOS 14 deployment target (typed-throws function types
need macOS 15 runtime); it was replaced by a step enum.

## GREEN

`swift test --filter ServerFailSafe`: 7 tests passed; 5 repeated runs passed.
Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| any session/tap/router failure restores local | `order`, `recoverAll` |
| stop suppression and restore cursor | `order` (suppression first, cursor restored) |
| reentrant, does not wait for network | `reentrancy`, `concurrent`, `recoverAll` |
| failure paths | `partial`, `failed` |

## Deviations

Dependencies M2-013, M2-021 and M1-063 are not merged. Real-hardware
verification not performed.

## Review

Pending independent review.

# M2-013 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/LocalEventSuppressor.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/LocalEventSuppressorTests.swift`,
`docs/components/M2-013-local-event-suppressor.md`.

## RED

Before the implementation existed: `cannot find type 'LocalEventSuppressor'
in scope`.

## GREEN

`swift test --package-path Packages/MacPlatform --filter LocalEventSuppressor`:
7 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| suppress only in committed remote | `passThroughByDefault` (enabled only by explicit effect) |
| fail open on permission/tap error | `tapDisabled`, `tapFailure` |
| system/emergency hotkeys not intercepted | `emergencyEscape`, `systemHotkey` |

## Deviations

Dependencies M2-009/M2-011 provide the state; M2-011 (commit flow) is folded
into the M2-009 reducer table. Real-hardware verification not performed.

## Review

Pending independent review.

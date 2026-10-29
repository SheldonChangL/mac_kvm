# M2-005 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/MacKeyboardCapture.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/MacKeyboardCaptureTests.swift`,
`docs/components/M2-005-mac-keyboard-capture.md`.

## RED

Before the implementation existed: `cannot find 'MacKeyboardCapture' in scope`.
During GREEN, one expectation was wrong: macOS creates a `CGEvent` for
`kVK_Function` as `flagsChanged` (probe: type 12), not `keyDown`. The test now
exercises fn as `flagsChanged`, and production maps it to `unknown(0x3F)` with
its phase from `maskSecondaryFn` instead of dropping it.

## GREEN

`swift test --package-path Packages/MacPlatform --filter MacKeyboardCapture`:
6 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| key down/up/repeat/modifier → KVMEvent | `phases`, `modifiers`, `flagsChangedEvents` |
| layout/key mapping per existing contract | `roundTrip` against M1-044; `unknown` per M1-042 |
| no text content recorded | pure mapper, no logging |

## Deviations

Dependency M1-046 is not merged. Real-hardware verification not performed.

## Review

Pending independent review.

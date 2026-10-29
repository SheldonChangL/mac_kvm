# M2-004 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/MacMouseCapture.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/MacMouseCaptureTests.swift`,
`docs/components/M2-004-mac-mouse-capture.md`.

## RED

Before the implementation existed: `cannot find 'MacMouseCapture' in scope`.

## GREEN

`swift test --package-path Packages/MacPlatform --filter MacMouseCapture`:
6 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| move/button/scroll → KVMEvent | `moves`, `buttons`, `scrolling` |
| preserve timestamp/order | `timestamps`; order preserved by M2-003 queue |
| no network I/O in callback | pure mapper; no imports beyond CoreGraphics/KVMContracts |

## Manual verification

Required by the Issue on real hardware; not performed (no live session).

## Review

Pending independent review.

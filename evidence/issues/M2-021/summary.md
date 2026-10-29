# M2-021 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/CursorRestorer.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/CursorRestorerTests.swift`,
`docs/components/M2-021-cursor-restorer.md`.

## RED

Before the implementation existed: `cannot find type 'CursorEnvironment' in
scope`.

## GREEN

`swift test --package-path Packages/MacPlatform --filter CursorRestorer`:
6 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| save a safe local point before switching | `saved`, `saveFailure` |
| restore/warp on return to local | `preferred`, `idempotent` |
| hot-plug fallback point | `hotPlug`, `failures` |

## Manual verification

Required on hardware; not performed.

## Review

Pending independent review.

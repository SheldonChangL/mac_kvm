# M2-006 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/SyntheticEventFilter.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/SyntheticEventFilterTests.swift`,
`docs/components/M2-006-synthetic-event-filter.md`.

## RED

Before the implementation existed: `cannot find 'SyntheticEventFilter' in
scope`. The first GREEN run failed because the test helper wrote user data
twice; a standalone probe (outside the repository) showed CoreGraphics ignores
the second write. The helper now writes once, and a new test pins the
behavior and the fallback.

## GREEN

`swift test --package-path Packages/MacPlatform --filter SyntheticEventFilter`:
6 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| first-party injected events not captured again | `taggedEvents` |
| fallback when tag invalid | `tagNotWritable`, `pidFallback` |
| real user events not filtered | `physicalEvents` |

## Deviations

Dependencies M1-049 (keyboard injector) is not merged; M1-036 injector does
not tag (follow-up). Real-hardware verification not performed.

## Review

Pending independent review.

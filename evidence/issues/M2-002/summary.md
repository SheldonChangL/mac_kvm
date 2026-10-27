# M2-002 Evidence Summary

## Scope

Files: `Packages/MacPlatform/Sources/MacPlatform/EventTapPermissionService.swift`,
`Packages/MacPlatform/Tests/MacPlatformTests/EventTapPermissionServiceTests.swift`,
`docs/components/M2-002-event-tap-permission-service.md`.

## RED

Before the implementation existed: `cannot find type
'EventTapPermissionService' in scope`.

## GREEN

`swift test --package-path Packages/MacPlatform --filter
EventTapPermissionService`: 5 tests passed. Full gates in `commands.json`.

## Acceptance mapping

| Criterion | Evidence |
| --- | --- |
| check permission before creating the tap | `preflight()`; `ready`, `denied` |
| diagnostics when disabled by system / timeout | `disabledDiagnostics` |
| denial never enters remote mode | `canEnterRemote` false for denials |

## Manual verification

Required on hardware; not performed.

## Review

Pending independent review.

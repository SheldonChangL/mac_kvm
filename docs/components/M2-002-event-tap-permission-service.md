# M2-002 CGEventTap Permission and Preflight Service

## Outcome

`MacPlatform` now has `EventTapPermissionService` and `EventTapReadiness`.
Declarations are `package`; the environment seam is module-internal.

## Behavior

| Call | Result |
| --- | --- |
| `preflight()` | `ready`, `listenAccessDenied` (`CGPreflightListenEventAccess`), or `accessibilityDenied` (`AXIsProcessTrusted`); never prompts |
| `requestMissingAccess()` | calls `CGRequestListenEventAccess` only if listen access is missing, then re-reads; state at return only |
| `EventTapReadiness.canEnterRemote` | true only for `ready` |
| `EventTapReadiness.failure` | frozen `permission.capabilityUnavailable` / `permission.accessibilityDenied`, `userActionRequired` |
| `diagnoseDisabledTap(_:)` | `inputSafety.cleanupRequired` with diagnostic code 1 (timeout) or 2 (user input); `nil` otherwise |

The owner must call `preflight()` before creating the event tap and must not
enter remote mode unless it is `ready` (M2-001). A disabled-tap diagnostic
means fail open: stop suppression and return to local.

## Tests

`EventTapPermissionServiceTests` (5) with an injected environment: ready,
denials, request only when missing, disabled-tap diagnostics, live
construction without prompting.

## Known limitations

Real permission prompts and System Settings behavior need manual
verification on hardware.

## Rollback

Revert the three M2-002 files.

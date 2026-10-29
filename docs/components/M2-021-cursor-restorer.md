# M2-021 Cursor Warp and Local Position Restore

## Outcome

`MacPlatform` now has `CursorRestorer` and `CursorRestoreOutcome`.
Declarations are `package`; the environment seam is module-internal.

## Behavior

- `saveCurrent()` stores the current cursor location before switching away;
  unreadable or non-finite locations keep the previous point.
- `restore(preferred:)` first re-associates mouse and cursor
  (`CGAssociateMouseAndMouseCursorPosition(true)`), so a cursor frozen for
  remote routing never stays frozen. It then warps to the first candidate on
  a currently active display whose warp succeeds, falling through on a
  failed warp: the preferred re-entry point from M2-020, the saved point, then
  the center of the first active display.
- Active displays are re-read on every restore, covering hot-plug and
  resolution changes. No display, or a failing warp, reports `failed`.
- `clear()` forgets the saved point. All calls are synchronous, idempotent and
  never log positions.

## Tests

`CursorRestorerTests` (6) with an injected environment (the live warp is never
called in tests): preferred point, saved point, hot-plug fallback, failures
with association still restored, save failure, idempotency.

## Known limitations

Real cursor warping, the CGWarp local-events suppression interval, and
multi-display coordinate behavior need real-hardware verification.

## Rollback

Revert the three M2-021 files.

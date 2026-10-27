# M2-004 macOS Mouse Capture Adapter

## Outcome

`MacPlatform` now has `MacMouseCapture` and `MacCapturedInput`.
`MacMouseCapture.map(_:)` turns one physical mouse `CGEvent` from the server
event tap into a `KVMEvent` plus the source `CGEvent` timestamp.
Declarations are `package`; `CGEvent` never crosses into `KVMContracts` or
`KVMCore`.

## Mapping

| `CGEventType` | `KVMEvent` |
| --- | --- |
| `mouseMoved`, `left/right/otherMouseDragged` | `mouseMove(position:)` normalized over the capture bounds with `(size − 1)` denominators, clamped |
| `leftMouseDown/Up` | `mouseButton(.left, .down/.up)` |
| `rightMouseDown/Up` | `mouseButton(.right, …)` |
| `otherMouseDown/Up` button 2 / 3 | `.middle` / `.auxiliary`; other numbers → `nil` (pass through) |
| `scrollWheel` | `scroll(deltaX: axis2, deltaY: axis1)` in line units; zero → `nil` |
| anything else | `nil` |

## Real-time safety

Pure value; no I/O, await, allocation beyond the result, or logging, so it
is safe inside the tap callback. The owner enqueues the result into the
M2-003 `CaptureQueue` and preserves order through it; the timestamp is kept
for timing.

## Tests

`MacMouseCaptureTests` (6) build real `CGEvent`s without permissions:
moves/drags, clamping and offset bounds, buttons, scroll, timestamps, invalid
inputs.

## Known limitations

- Scroll units are macOS line deltas; any Barrier wheel scaling is unfrozen
  (M2-023).
- The concrete event tap installation and multi-display bounds selection are
  integration work; real-hardware verification is pending.

## Rollback

Revert the three M2-004 files.

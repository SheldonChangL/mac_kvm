# M2-006 Synthetic Event Tagging and Self-event Filtering

## Outcome

`MacPlatform` now has `SyntheticEventFilter`. Declarations are `package`.

## Rules

1. Primary: first-party injected events carry a process-unique non-zero
   `eventSourceUserData` marker written by `tag(_:)` before posting.
   `classify` returns `synthetic(.marker)` for a matching marker.
2. Fallback: if the marker is missing or could not be written, an event whose
   `eventSourceUnixProcessID` equals this process is `synthetic(.ownProcess)`.
3. Everything else is `physical`. Physical HID events carry user data `0`
   and a different source process, so real user input is never filtered.

The filter never inspects key identity, text or position and never logs.
`live()` draws a random non-zero marker for this process.

## Observed platform behavior

A probe on this toolchain showed that CoreGraphics ignores a second write of
`eventSourceUserData` on the same `CGEvent` (write 0 then 7 reads back 0).
A tag can therefore fail silently when an event already carries user data;
rule 2 covers that case, and a test pins the behavior.

## Integration note

The existing M1-036 mouse-move injector does not tag yet; changing it is
outside this Issue's Exact Files. Its events are still classified synthetic
through the own-process fallback. Tagging injectors is a follow-up.

## Tests

`SyntheticEventFilterTests` (6): tagged events, unwritable tag fallback,
own-process fallback, physical events, invalid configuration, live filter.

## Rollback

Revert the three M2-006 files.

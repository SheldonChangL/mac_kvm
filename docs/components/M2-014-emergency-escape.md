# M2-014 Emergency Escape Hotkey and Fail-open Recovery

## Outcome

`KVMCore` now has `EmergencyEscape`, the pure detector for the fixed gesture
proposed in M2-001: **Control + Option + Command + Delete (Backspace)**, and,
since the M2-035 owner run, the same modifiers with **Return**. Declarations are
`package`.

| Call | Result |
| --- | --- |
| `action(for:)` | `.emergencyEscape` for the chord key down (Shift/Caps Lock ignored), else `nil` |
| `isChordKey(_:)` | true for any phase of the chord key with the chord modifiers; never forward these |

## Fail-open behavior

The action drives `InputStateReducer` to `local` from every state in one step.
Any remote leave or release emitted during escape is `bestEffort`, so escape
never waits on the network, another thread or a remote acknowledgement. The
capture owner evaluates the detector synchronously in the capture path before
suppression; MacPlatform receives it as an injected predicate because the
platform module cannot import KVMCore.

## Tests

`EmergencyEscapeTests` (4): chord match, non-matches (missing modifiers, other
keys, up/repeat, non-key events), local-first reduction from every state,
chord never forwarded.

## Known limitations

Hardware check (M2-035 owner run, macOS 26.6.2, Apple keyboard, 2026-10-28/29):

- With Control, Option and Command held, the system never delivers the Delete
  key down to an event tap. A session-level tap sees neither phase; the
  HID-level tap the server now uses sees only the release, which still
  triggers the escape because the server escapes on every phase of the chord
  key.
- Return with the same modifiers arrives in both phases, so it is accepted as
  the second chord key and is the gesture the server announces.

## Rollback

Revert the three M2-014 files.

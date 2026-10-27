# M2-014 Emergency Escape Hotkey and Fail-open Recovery

## Outcome

`KVMCore` now has `EmergencyEscape`, the pure detector for the fixed gesture
proposed in M2-001: **Control + Option + Command + Delete (Backspace)**.
Declarations are `package`.

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

Real-hardware verification that macOS delivers this chord to the event tap is
pending (manual E2E plan).

## Rollback

Revert the three M2-014 files.

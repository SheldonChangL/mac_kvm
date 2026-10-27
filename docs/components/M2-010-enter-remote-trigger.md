# M2-010 Local → EnteringRemote Edge Trigger

## Outcome

`KVMCore` now has `EnterRemoteTrigger` and `EnterIntent`. Declarations are
`package`.

## Behavior

`EnterRemoteTrigger` composes the M2-017 `EdgeDetector`, the M2-031
`ScreenRouter` and one M2-019 `OutboundCoordinateMapper` per remote screen.
`pointer(x:y:at:state:available:)` and `tick(at:state:available:)` return an
`EnterIntent` — the `edgeActivated(target:entry:)` reducer action, the local
edge and the remote entry point for the tracker — only when:

- the input state is `local` (any other state resets the dwell, so no intent
  repeats while a switch is in flight);
- no local key or mouse button is held, per the M2-008 activation
  precondition (`observe(_:)` records presses and releases from captured
  local events; while anything is held the dwell is reset);
- the edge dwell completed (once per dwell; re-arming needs leaving the edge);
- the edge is linked in the topology and its neighbor has a ready session;
- remote geometry for that neighbor is known.

Otherwise no switch happens. The trigger is pure: no clock, network or
platform dependency.

## Tests

`EnterRemoteTriggerTests` (6): intent with exact entry point, tick, no switch
for unlinked/unavailable/no-geometry, non-local states, held-input blocking, invalid local size.

Writing these tests exposed an offset-denominator mismatch in M2-017, fixed
separately in `fix(m2-017)` before this commit.

## Rollback

Revert the three M2-010 files.

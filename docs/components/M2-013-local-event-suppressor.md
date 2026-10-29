# M2-013 Remote State Local Event Suppression

## Outcome

`MacPlatform` now has `LocalEventSuppressor`, the decision core the server
event-tap callback uses to pass or swallow a local event. Declarations are
`package`.

## Decision order

1. `tapDisabledByTimeout` / `tapDisabledByUserInput`: stop suppression,
   return `failOpen` (owner reports `captureFailure` to the reducer).
2. Synthetic first-party events (M2-006): `passThrough`.
3. Emergency escape chord (Core predicate from M2-014, injected because
   MacPlatform cannot import KVMCore): stop suppression synchronously, return
   `emergencyEscape`; never swallowed.
4. System Force Quit chord (Command + Option + Escape): `passThrough`.
5. Otherwise `suppress` only while suppression is enabled, which the owner
   does solely for the reducer's `enableSuppression` effect on entering the
   committed `remote` state.

`disableSuppression()` and `tapFailed()` are idempotent and immediate, so
every failure path can fail open without waiting for anything.

## Real-time safety

One `NSLock` guards the flag; `decide` never awaits and never logs.

## Tests

`LocalEventSuppressorTests` (7): default pass-through and enable/disable,
tap-disabled fail open, tap failure, emergency chord, Force Quit, synthetic
events, concurrent toggling.

## Known limitations

The concrete `CGEvent.tapCreate` installation and run-loop wiring are
integration work outside this Issue's Exact Files; real-hardware
verification (including Secure Event Input behaviour) is pending.

## Rollback

Revert the three M2-013 files.

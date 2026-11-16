# M1-064 Cleanup Hooks

## Outcome

`KVMCore` provides `CleanupHooks`, `CleanupTrigger`, `CleanupGeneration` and
`CleanupOutcome` in `Packages/KVMCore/Sources/KVMCore/CleanupHooks.swift`, with
`package` access. Every terminal, error and cancel path of a client session
funnels into one logical cleanup per session generation (plan a.6.4, b.6).
Everything here is first-party policy. It never logs, and its outcome carries
no key, button or event identity (Frozen Decision 8).

## API

| Member | Meaning |
|---|---|
| `CleanupTrigger` | `streamEnded(DisconnectReason)`, `transportFailure(CoreError)`, `protocolViolation(CoreError)`, `keepaliveTimeout`, `cancelled`, `sleep`, `termination`, `displayLost` |
| `init(failSafe:plan:clearLedger:disconnect:clock:disconnectTimeout:)` | Hooks over one `FailSafeCoordinator` (M1-063); `plan` yields the ledger's release plan at cleanup time |
| `beginGeneration() -> CleanupGeneration` | One token per session instance |
| `runOnce(_:generation:) async -> CleanupOutcome` | The generation's one cleanup; later callers get `ran == false` |
| `trigger(for: DisconnectReason)` | Mapping table below |
| `disconnectReason(for: CleanupTrigger)` | The reason handed to `disconnect`; round-trips through `trigger(for:)` |
| `CleanupOutcome` | `ran`, `disposition` (the fail-safe's), `disconnectTimedOut` |

Additions beyond the plan's b.6 API: the `clearLedger`, `clock` and
`disconnectTimeout` init parameters (a.6.4 names the ledger clear; b.6's test
list names the `KVMClock` bound), `disconnectReason(for:)`,
`CleanupOutcome.disconnectTimedOut` (how a hung disconnect "still reports"),
`CleanupOutcome.skipped` and `defaultDisconnectTimeout` (2 s).

## Order

The first `runOnce` for a generation runs, in order:

1. `FailSafeCoordinator.recover(plan:)` on a dedicated `Thread` named
   `mackvm-cleanup`, never on the cooperative pool: the adapter's
   `clearTransientState()` stops and joins the injection drain worker (M1-063,
   h.6). The recovery is queue reset, the ledger's `ReleaseAllKeys` plan, the
   injector sweep `releaseRemaining()` (h.1) and `restoreLocalInput()`.
   Cleanups of different generations are serialized, so each gets a full run.
2. `clearLedger()`, on the same thread.
3. `disconnect(reason)`: awaited, but bounded by `disconnectTimeout` on the
   injected `KVMClock`. A disconnect that hangs is cancelled and abandoned; the
   outcome reports `disconnectTimedOut == true`. The releases have already run.

Nothing waits on UI or network before the releases. A failed or partial
recovery is reported in `disposition` (so the owner can raise
`inputSafety(.cleanupPartial/.cleanupFailed)`), and the disconnect still runs.

## Once per generation

`beginGeneration()` opens a token; `runOnce` closes it under a lock. A second
trigger for the same generation (from any thread) and a generation this
instance never issued return `ran == false`, `notRequired`, at once and run
nothing. An older generation whose cleanup has not run yet still runs after a
newer one began (the superseded attempt's cancellation path).

## Mapping table (`trigger(for:)`)

| `DisconnectReason` | Trigger |
|---|---|
| `userRequested`, `transportClosed` (EOF) | `streamEnded(reason)` |
| `cancellation(.shutdown)`, `applicationTermination` | `termination` |
| `cancellation(.requested/.superseded)` | `cancelled` |
| `failure` with `timeout(.keepalive)` | `keepaliveTimeout` |
| `failure` with other `timeout`, `transport` or `security` (TLS) | `transportFailure(error)` |
| `failure` with `protocolViolation` | `protocolViolation(error)` |
| `failure` with `cancellation` | as the cancellation rows |
| `failure` with `lifecycle(.sleep)` / `(.termination)` / `(.subsystemUnavailable)` | `sleep` / `termination` / `displayLost` |
| `failure` with anything else | `streamEnded(reason)` |

The switch is exhaustive, so a new error domain fails to compile until mapped.

## Evidence and known limitations

- Tests: `Packages/KVMCore/Tests/KVMCoreTests/CleanupHooksTests.swift` with a
  recording adapter, a manual clock and a hanging disconnect. Mutations:
  `evidence/issues/M1-064/mutations/`.
- The composition root (M4-020-FOLLOWUP-001) wires the session, the
  `ReconnectManager`, `RecoveryCoordinator`'s sleep hook and the signal
  handlers to `runOnce`; this issue proves the hooks against models only.
- An abandoned disconnect task keeps running until it honours cancellation.
- A process crash runs no cleanup (plan risk f.9).

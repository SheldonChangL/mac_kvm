# M1-063-FOLLOWUP-001 Client Coordinator

## Outcome

`KVMCore` provides `ClientCoordinator`, `ClientCoordinatorEffects`,
`ClientScreenState`, `ClientHandleOutcome` and `ClientCoordinatorDiagnostics` in
`Packages/KVMCore/Sources/KVMCore/ClientCoordinator.swift`, with `package`
access. It is the client mirror of `ServerCoordinator` (plan decision 5, a.3,
b.8): one `NSLock`, effects called with the lock held that only queue and never
call back. It consumes the client session's events in order. This is a
follow-up issue (GitHub #346) with no manifest entry (plan a.9). Every rule here
is first-party policy. It never logs, and its diagnostics hold counts by reason
only (Frozen Decision 8).

## API

| Member | Meaning |
|---|---|
| `ClientCoordinatorEffects` | `inject`, `moveLocalPointer`, `applyClipboard` (each returns `false` when it cannot queue), `screenBecameActive`, `screenBecameInactive` (status only) |
| `init(localScreen:effects:clipboardLimit:failSafe:hooks:)` | As b.8; begins the first session generation |
| `make(localScreen:effects:clipboardLimit:failSafe:disconnect:clock:disconnectTimeout:)` | Builds the coordinator and its `CleanupHooks`, whose `plan` and `clearLedger` read this coordinator's ledger |
| `state` | `.inactive` or `.active` |
| `handle(_:) -> ClientHandleOutcome` | One event of the open session: `accepted`, `dropped` or `failedClosed` |
| `localClipboardChanged(_:) -> ClipboardPayload?` | Admitted outbound payload (the caller sends it), or `nil` |
| `terminate(_:) async -> CleanupOutcome` | The only cleanup entry; at most one cleanup per generation |
| `run(_:) async -> CleanupOutcome` | Consumes one stream, then terminates it with the trigger below |
| `beginSession() -> Bool` | Opens the next generation once the previous cleanup has returned |
| `releasePlan()`, `clearLedger()` | Read by `CleanupHooks` at cleanup time |
| `diagnostics`, `ledgerSnapshot`, `lastFailSafeReport` | Counts and flags only |

Additions beyond b.8, and why:

- `handle` returns an outcome (discardable). A synchronous handler cannot await
  the cleanup, so a failed effect closes the session at once and the owner calls
  `terminate`; `run` does so with `injectionFailureTrigger`
  (`streamEnded(.failure(inputSafety.cleanupRequired))`, retry `backoff`).
- `run(_:)` maps stream ends: finished → `streamEnded(.transportClosed)`; a
  thrown `CoreError` → `CleanupHooks.trigger(for: .failure(error))` (transport,
  protocol violation, keepalive timeout, ...); task cancellation → `cancelled`;
  any other error → `protocolViolation(internal.unclassified)`.
- `make` and `beginSession`: `CleanupHooks` takes its plan and ledger closures
  at init, before the coordinator exists, and one `FailSafeCoordinator` must
  serve every generation (a concurrent `recover` returns `notRequired`). So the
  coordinator lives across generations; `beginSession()` refuses while a
  session is open or its cleanup is running, so the old generation's releases
  finish before the new one injects (h.5). Events from an old generation's
  stream are dropped.

## Data flow

1. `.enterScreen` for this screen: `moveLocalPointer` first, then `.active`
   and `screenBecameActive`. For another screen: dropped and counted.
2. Key, button, pointer and scroll input while `.inactive`: dropped and counted
   (defensive; the server does not send it).
3. `.key` and `.mouseButton`: `InputStateLedger.record` (M1-062). `inject` and
   `injectUnheldRelease` are injected; `dropDuplicateDown` and
   `dropUnheldRepeat` are dropped and counted. An unpaired repeat is never
   injected (a.6.2).
4. `.mouseMove` and `.scroll`: injected.
5. `.clipboard`: `ClipboardLoopGuard.admitInbound` (M1-054) with the clipboard
   limit, then `applyClipboard`. Clipboard is not input, so it is applied in
   either screen state. A failed apply is counted; the session goes on.
6. `.leaveScreen` for this screen: the `ReleaseAllKeys` plan (M1-050) over the
   ledger (non-modifier keys, buttons, then modifiers, each in reverse press
   order) is injected, the ledger reset, the state `.inactive`.
7. Outbound clipboard: only while `.active` and open, through
   `admitOutbound`; the admitted payload is returned to the caller to send
   (a.8).
8. A failed `inject` or `moveLocalPointer` fails closed: the session accepts
   nothing more and becomes `.inactive`. The ledger keeps what it recorded, so
   the cleanup releases it again; releasing an unpressed key is harmless.

## Terminal paths

Stream end, transport failure, protocol violation, keepalive timeout,
cancellation by a new reconnect generation, termination, sleep and display
loss all reach `terminate(trigger)`. Under the lock it claims the generation,
closes the session (no later event is injected) and leaves `.active`. Then
`CleanupHooks.runOnce` runs the one cleanup (a.6.4): drain worker joined and
queue reset, the ledger's release plan, the injector sweep `releaseRemaining()`
(h.1, h.6), the ledger clear and a bounded disconnect. The sweep covers
releases a queue reset or overflow dropped after the ledger counted them. A
second `terminate`, concurrent or later, returns `ran == false`.

## Diagnostics

`ClientCoordinatorDiagnostics` holds integer counts by reason (injected,
dropped while inactive, duplicate down, unheld repeat, unheld release, foreign
screen, after close, leave releases, inject and pointer failures, clipboard
admissions and rejections by reason, sessions, cleanups) and the last cleanup
disposition. It holds no key, button, position, text, hash or identifier.

## Tests

`Packages/KVMCore/Tests/KVMCoreTests/ClientCoordinatorTests.swift` uses a
scripted `KVMProtocolSession` fake and a platform model that queues, drains,
resets, releases and sweeps, and records violations (an unpaired repeat
reaching the platform, any injection after the cleanup started). After every
terminal path it asserts: nothing held, `.inactive`, ledger empty, a second
cleanup does not run, later events are dropped, and diagnostics hold no
identifiers. Most terminal tests disable the sweep, so the ledger's plan alone
must release everything. A property test runs 300 seeded random streams, cut
at random points by random terminal paths and injection failures, against the
same invariants.

## Limits

- The composition root (M4-020-FOLLOWUP-001) supplies the effects adapter
  (`CaptureQueue` plus the injector worker) and calls `run` per session.
- The ledger records an event before it is queued. When a release cannot be
  queued, the ledger has already freed the key, so the cleanup's plan does not
  include it; the injector sweep (h.1) is what releases it. The property test
  therefore runs injection failures only with the sweep enabled.
- Effects run with the lock held; an adapter that blocks stalls the session,
  as for `ServerCoordinator`.

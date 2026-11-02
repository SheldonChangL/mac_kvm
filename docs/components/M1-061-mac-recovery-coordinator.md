# M1-061 Network Change and Sleep/Wake Recovery

## Outcome

`KVMCore` now has `RecoverySignal`, the `RecoveryReconnector` protocol and the
`RecoveryCoordinator` actor. `ReconnectManager` (M1-060) conforms to
`RecoveryReconnector`. Declarations are `package`. The coordinator turns
platform-neutral sleep, wake and network signals into
`ReconnectManager.connect()` and `disconnect()` calls. The rules below are
first-party policy.

## Why the type is platform-neutral

The Issue's scope names `NWPathMonitor`. `KVMCore` may not import `Network`:
the architecture checker reports it as `kvmcore-forbidden-import`. The Linux
client cannot use `Network` either. So the Core type consumes signals, and the
platform monitors feed it:

- Linux: the lifecycle monitor of M4-020-FOLLOWUP-001. It detects a resume from
  the jump of `CLOCK_BOOTTIME` minus `CLOCK_MONOTONIC`, and the network from the
  interface addresses.
- macOS: an `NWPathMonitor` and sleep/wake adapter belongs to the Mac client
  role, which M4-SCOPE-001 defers.

Deviation: the type is named `RecoveryCoordinator`, but it lives in the Exact
File `MacRecoveryCoordinator.swift`, so the Exact Files stay as the Issue lists
them. M1-060 recorded its command deviation the same way.

## API

```swift
package enum RecoverySignal: Equatable, Sendable {
  case networkAvailable(Bool), willSleep, didWake
}
package protocol RecoveryReconnector: Sendable {
  func connect() async
  func disconnect() async
}
extension ReconnectManager: RecoveryReconnector {}
package actor RecoveryCoordinator {
  package init(
    reconnector: any RecoveryReconnector, onSleep: @escaping @Sendable () async -> Void)
  package private(set) var networkAvailable: Bool  // true before the first report
  package private(set) var awaitingNetworkAfterWake: Bool
  package func handle(_ signal: RecoverySignal) async
  package func waitForQueuedSignals(_ count: Int) async  // test scheduling barrier
}
```

This is the API of the master plan's section b.5, plus one test scheduling
barrier like `ReconnectManager.waitForState(_:)`.

## Rules

| Signal | Effect |
| --- | --- |
| `willSleep` | Drops a waiting wake, awaits `onSleep()`, then calls `disconnect()`. Every sleep runs the hook, also a repeated one. |
| `didWake`, network available | Calls `connect()` at once. |
| `didWake`, network unavailable | Does not connect. `awaitingNetworkAfterWake` becomes `true`. |
| `networkAvailable(true)`, a wake waiting | Calls `connect()` once and clears the waiting wake. |
| `networkAvailable(true)`, no wake waiting | Records the state only. |
| `networkAvailable(false)` | Records the state only. |

- **Sleep.** `onSleep` is the cleanup hook that releases the held keys and
  buttons. In the planned Linux client it is M1-064's `CleanupHooks` run for
  the sleep trigger. The coordinator calls `disconnect()` only after the hook
  returns, so nothing is torn down before the release (Frozen Decision 7).
  After the disconnect, `ReconnectManager` does not reconnect while the system
  sleeps.
- **Network loss.** Losing the network never disconnects. Keepalive finds a
  dead connection, and the backoff of M1-060 retries it.
- **Supersede rule.** Each wake leads to at most one `connect()`. With the
  network up, it connects at once. Otherwise it connects once when the network
  returns, however many wakes arrived in between. `ReconnectManager.connect()`
  cancels the previous generation before it starts the new one. So repeated
  wakes never leave two generations in force, as the Issue requires. The
  cancelled attempt may still be closing its connection while the new one
  connects. How the server treats a second connection under the same screen
  name during that overlap is not verified here. The coordinator creates no
  listener and no session itself.
- **Network state.** The coordinator acts on the last report. Before any
  report, the network counts as available. A wrong guess costs one failed
  attempt, which backoff retries. The opposite default could leave a woken
  client disconnected for good when a monitor reports only changes. A monitor
  must report the current state first, and again before each `didWake`,
  because after a resume the last report dates from before the sleep. With a
  stale `true`, the wake connects at once into a network that is not back yet;
  the attempt fails, and backoff retries it within 15 s instead of the wake
  waiting for the network.
- **Wake without sleep.** A wake needs no preceding sleep. Without logind, the
  Linux monitor sees a resume but not the suspend, so every resume arrives as a
  lone `didWake`.

## Order and concurrency

- Signals are processed one at a time, in the order `handle(_:)` receives them,
  by a drain task the actor owns. A signal that arrives during another one
  waits for it. Without this, the reentrant actor would let a wake's
  `connect()` run between a sleep's cleanup and its `disconnect()`, and the
  woken client would end up disconnected.
- `handle(_:)` returns once its signal has been processed. When the caller is
  cancelled, it returns at once, and the signal is still processed, so a
  cancelled caller never drops a sleep's cleanup.
- `onSleep` must return promptly; M1-064's plan bounds its disconnect with a
  `KVMClock` timeout. The hook must not wait for `handle(_:)`, because that
  call would wait behind the sleep that runs it.
- Every wait returns when its task is cancelled. Nothing here logs, and the
  signals carry no content.

## Tests

`MacRecoveryCoordinatorTests` has 15 Swift Testing tests under a one-minute
time limit. Every test barrier returns when its task is cancelled, so a
regression fails within the limit instead of hanging.

| Kind | Tests |
| --- | --- |
| Happy path | `sleepRunsTheCleanupHookBeforeDisconnecting` (the hook is held open, and no disconnect happens until it returns), `wakeConnectsAtOnceWhenTheNetworkIsAvailable` |
| Boundary | `beforeAnyNetworkSignalTheNetworkCountsAsAvailable`, `wakeWithoutNetworkDoesNotConnect`, `lateNetworkAfterWakeConnectsOnce`, `duplicateWakesConnectOncePerWakeAndOncePerOutage` |
| Invalid order, failure | `networkLossWhileConnectedDoesNothing`, `networkReportsWithoutAWakeCauseNoEffect` |
| Cancel, cleanup | `sleepCancelsAPendingWakeReconnect`, `repeatedSleepRunsTheCleanupEveryTime`, `signalsAreProcessedOneAtATimeInArrivalOrder`, `cancelledCallersStillHaveTheirSignalsProcessed` |
| Round trip through `ReconnectManager` | `sleepAndWakeDriveTheReconnectManager`, `duplicateWakeSupersedesThroughTheReconnectManager` |
| Source | `productionSourceImportsNoPlatformModuleAndNeverLogs` |

The two round trips use the real `ReconnectManager` with `TestKVMClock` and
attempts that hold a connection until they are cancelled:

- The sleep hook sees the manager still `connected`. After the sleep the
  manager is `idle`, and 60 s of clock time start no attempt. A wake without
  network starts none either; the network's return starts exactly one.
- After a duplicate wake, the first attempt is cancelled before the second one
  starts. At most one generation's attempt is ever in force; an attempt counts
  as out of force once it is cancelled, even while it is still closing.

The mutation checks are in `evidence/issues/M1-061/mutations/`.

## Hardware evidence

The Issue is Tier C/H. On 2026-11-02 the Product Owner accepted the Linux
sleep/wake case of the later owner end-to-end test M4-036-FOLLOWUP-001 as this
Issue's hardware evidence. That case is "Linux suspend/resume with the pointer
local"; the same run also covers Mac sleep/wake. It runs on the owner's
hardware, and a reviewer who is not the implementing agent verifies it. Until
that run passes, the hardware half of the acceptance criteria stays open. This
change carries the automated half only. The lead relayed the decision; it is
not recorded in the repository yet, so the evidence summary must record it.

## Required command note

The Issue lists `swift test --package-path Packages/KVMCore`. `KVMCore` has no
package manifest of its own, so the tests run from the root package: `swift
test --filter MacRecoveryCoordinator` and the full `swift test`, as M1-060 did.
The other required commands run as listed.

## Known limitations

- No monitor lives here, and none feeds the coordinator yet. The Linux monitor
  and the composition root are M4-020-FOLLOWUP-001. The Mac monitors belong to
  the deferred Mac client role.
- A wake calls `connect()` whatever state `ReconnectManager` is in, including
  `stopped`. The state carries only the error code, not its retry disposition.
  So the coordinator cannot tell an `immediateAfterStateChange` stop, which
  M1-060 leaves to this component, from a `userActionRequired` or `never` stop.
  A restarted attempt evaluates trust again and fails closed again (Frozen
  Decision 6). The planned Linux client exits on those stops, with exit code 69
  or 78. A future Mac client with a manual disconnect needs the coordinator to
  learn about that disconnect.
- A duplicate wake while the network is up reconnects again. Its `connect()`
  replaces the session that the first wake established, and that session's
  cleanup releases its input. A monitor should report one wake per resume.
- A network return without a waiting wake does not reconnect a stopped or
  waiting manager. Backoff reconnects a waiting manager within 15 s. So a
  generation stopped with `immediateAfterStateChange` restarts only on a wake,
  or on the network's return after a wake. M1-060's doc comment and
  `docs/components/M1-060-reconnect-manager.md` say that M1-061 restarts it. No
  client error uses that disposition today (master plan a.5). Reconciling the
  texts needs a follow-up, because the M1-060 files are outside this Issue's
  Exact Files.
- Linux without logind sends no `willSleep`. Keys held at suspend are released
  after resume, by a terminal path of the old connection: the cancellation
  that the wake's new generation causes, or the dead stream, whichever comes
  first (master plan a.6, item 4). This relies on the composition root routing
  the cancellation of an attempt into the cleanup hooks (M1-064,
  M4-020-FOLLOWUP-001).
- The coordinator does not bound `onSleep`. A hook that never returns holds
  every later signal.
- The coordinator has no stop. A signal queued behind a slow hook, or a late
  wake, can call `connect()` after a termination has disconnected. On
  termination the composition root must stop the monitors first and keep the
  reconnector from connecting again, for example with a reconnector adapter
  that ignores `connect()` once termination has started.

## Rollback

Revert the three M1-061 files and `evidence/issues/M1-061/`. Nothing depends on
them yet; M1-064 and M4-020-FOLLOWUP-001 will.

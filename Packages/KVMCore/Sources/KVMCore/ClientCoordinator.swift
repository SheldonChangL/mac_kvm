// The single owner of the first-party Linux client's input state (M1-063-FOLLOWUP-001), the
// client mirror of `ServerCoordinator`. It turns the client session's events, in order, into
// ledger decisions (M1-062) and injection effects, runs the release plan (M1-050) on a leave, and
// funnels every terminal path into the one idempotent cleanup of `CleanupHooks` (M1-064) over
// `FailSafeCoordinator` (M1-063). State lives behind one lock; effects are called with it held and
// never awaited. Every rule here is first-party policy. It never logs, and its diagnostics hold
// counts by reason only, never a key, button, position, text or identifier (Frozen Decision 8).

import Foundation
import KVMContracts

/// The platform effects the client coordinator drives.
///
/// Calls happen while the coordinator holds its lock, in event order. An implementation must
/// return promptly, must not wait for the platform or the network, and must never call back into
/// the coordinator synchronously.
package protocol ClientCoordinatorEffects: Sendable {
  /// Queues one key, button, pointer or scroll event for injection. Returns `false` when it cannot
  /// be queued; the coordinator then fails closed.
  func inject(_ event: KVMEvent) -> Bool
  /// Queues a move of the local pointer to a normalized position. Returns `false` when it cannot
  /// be queued; the coordinator then fails closed.
  func moveLocalPointer(to position: NormalizedPoint) -> Bool
  /// Queues an admitted inbound clipboard payload for the local clipboard. Returns `false` when it
  /// cannot be queued; the failure is counted and the session goes on.
  func applyClipboard(_ payload: ClipboardPayload) -> Bool
  /// Status only: the server moved input onto this screen.
  func screenBecameActive()
  /// Status only: input left this screen, or the session ended.
  func screenBecameInactive()
}

/// Whether input is on this client's screen.
package enum ClientScreenState: Equatable, Sendable {
  case inactive
  case active
}

/// What `handle(_:)` did with one event.
package enum ClientHandleOutcome: Equatable, Sendable {
  /// The event was injected, applied or changed the screen state.
  case accepted
  /// The event was dropped and counted.
  case dropped
  /// An effect could not be queued. The session accepts nothing more; the owner must call
  /// `terminate(_:)`, which `run(_:)` does with `injectionFailureTrigger`.
  case failedClosed
}

/// Counts by reason. No key, button, position, clipboard text, hash or identifier, so it may be
/// logged or reported (Frozen Decision 8).
package struct ClientCoordinatorDiagnostics: Equatable, Sendable {
  /// Key, button, pointer and scroll events queued for injection, release-plan steps included.
  package var injected = 0
  /// Input that arrived while the screen was inactive.
  package var droppedWhileInactive = 0
  /// Presses of a key or button the ledger already held.
  package var droppedDuplicateDown = 0
  /// Repeats of a key the ledger did not hold (Frozen Decision 7).
  package var droppedUnheldRepeat = 0
  /// Releases of a key or button the ledger did not hold; injected, not recorded.
  package var injectedUnheldRelease = 0
  /// Enter or leave naming a screen other than this client's.
  package var droppedForeignScreen = 0
  /// Events that arrived after the session failed closed or was terminated.
  package var droppedAfterClose = 0
  /// Release steps queued by leaves.
  package var leaveReleases = 0
  /// Effects that could not be queued and closed the session.
  package var injectFailures = 0
  package var pointerMoveFailures = 0
  package var inboundClipboardApplied = 0
  package var inboundClipboardLoopRejected = 0
  package var inboundClipboardOversized = 0
  package var clipboardApplyFailures = 0
  package var outboundClipboardAdmitted = 0
  package var outboundClipboardLoopRejected = 0
  package var outboundClipboardOversized = 0
  /// Outbound clipboard changes refused because the screen was inactive or the session closed.
  package var outboundClipboardWhileInactive = 0
  /// Sessions begun, the first one included.
  package var sessions = 0
  /// Cleanups this coordinator ran (at most one per session).
  package var cleanupsRun = 0
  /// The disposition of the last cleanup, or `nil` before the first.
  package var lastCleanupDisposition: CleanupDisposition?
}

/// Owns the client role's input state for a sequence of session generations. State lives behind
/// one `NSLock`, hence `@unchecked Sendable`.
///
/// One session is open at a time. The first opens at `init`; after its `terminate(_:)` has
/// returned, `beginSession()` opens the next, so the old generation's releases always finish
/// before the new one injects (plan h.5).
package final class ClientCoordinator: @unchecked Sendable {
  private struct State {
    var screen = ClientScreenState.inactive
    var ledger = InputStateLedger()
    var clipboardGuard = ClipboardLoopGuard()
    var generation: CleanupGeneration
    /// The session accepts events.
    var open = true
    /// The session's cleanup was claimed by `terminate`.
    var claimed = false
    /// A claimed cleanup has not returned yet.
    var cleaning = false
    var diagnostics = ClientCoordinatorDiagnostics()
  }

  /// The trigger `run(_:)` uses when an effect could not be queued: the session ends with an
  /// input-safety failure and the cleanup releases what it held.
  package static let injectionFailureTrigger = CleanupTrigger.streamEnded(
    .failure(
      CoreError(
        code: .inputSafety(.cleanupRequired), severity: .error, retryDisposition: .backoff,
        cleanupDisposition: .completed)))

  private let localScreen: ScreenID
  private let effects: any ClientCoordinatorEffects
  private let clipboardLimit: ClipboardByteLimit
  private let failSafe: FailSafeCoordinator
  private let hooks: CleanupHooks
  private let lock = NSLock()
  private var current: State

  /// `hooks` must be built over `failSafe` with `releasePlan()` and `clearLedger()` of this
  /// coordinator; `make(...)` wires it so. The first session generation is begun here.
  package init(
    localScreen: ScreenID, effects: any ClientCoordinatorEffects,
    clipboardLimit: ClipboardByteLimit, failSafe: FailSafeCoordinator, hooks: CleanupHooks
  ) {
    self.localScreen = localScreen
    self.effects = effects
    self.clipboardLimit = clipboardLimit
    self.failSafe = failSafe
    self.hooks = hooks
    current = State(generation: hooks.beginGeneration())
    current.diagnostics.sessions = 1
  }

  /// Builds the coordinator and its `CleanupHooks`, whose plan and ledger clear read this
  /// coordinator's ledger at cleanup time.
  package static func make(
    localScreen: ScreenID, effects: any ClientCoordinatorEffects,
    clipboardLimit: ClipboardByteLimit, failSafe: FailSafeCoordinator,
    disconnect: @escaping @Sendable (DisconnectReason) async -> Void,
    clock: any KVMClock = ContinuousKVMClock(),
    disconnectTimeout: Duration = CleanupHooks.defaultDisconnectTimeout
  ) -> ClientCoordinator {
    let box = WeakCoordinator()
    let hooks = CleanupHooks(
      failSafe: failSafe,
      plan: { box.get()?.releasePlan() ?? ReleasePlan(steps: []) },
      clearLedger: { box.get()?.clearLedger() },
      disconnect: disconnect, clock: clock, disconnectTimeout: disconnectTimeout)
    let coordinator = ClientCoordinator(
      localScreen: localScreen, effects: effects, clipboardLimit: clipboardLimit,
      failSafe: failSafe, hooks: hooks)
    box.set(coordinator)
    return coordinator
  }

  package var state: ClientScreenState {
    lock.withLock { current.screen }
  }

  package var diagnostics: ClientCoordinatorDiagnostics {
    lock.withLock { current.diagnostics }
  }

  /// Counts and flags of the ledger. No key or button identity; it does carry the last clipboard
  /// transaction ID, an opaque UUID, so callers must not log it as is.
  package var ledgerSnapshot: InputStateSnapshot {
    lock.withLock { current.ledger.snapshot() }
  }

  /// The fail-safe report of the last recovery, counts and step names only.
  package var lastFailSafeReport: FailSafeReport? {
    failSafe.lastReport
  }

  /// The ledger's release plan, read by `CleanupHooks` at cleanup time.
  package func releasePlan() -> ReleasePlan {
    lock.withLock { FailSafeCoordinator.releasePlan(for: current.ledger) }
  }

  /// Forgets everything the ledger holds, after the cleanup's releases.
  package func clearLedger() {
    lock.withLock { current.ledger.reset() }
  }

  /// Handles one event of the open session, in stream order.
  @discardableResult
  package func handle(_ event: KVMEvent) -> ClientHandleOutcome {
    lock.withLock { handleLocked(event, generation: current.generation) }
  }

  /// Opens the next session generation. Returns `false`, changing nothing, while the current
  /// session is open or its cleanup has not returned. The owner treats `false` after a
  /// `terminate` as "wait": it awaits the `terminate` call that ran the cleanup, then retries.
  package func beginSession() -> Bool {
    lock.withLock {
      guard current.claimed, !current.cleaning else { return false }
      current.generation = hooks.beginGeneration()
      current.open = true
      current.claimed = false
      current.screen = .inactive
      current.ledger.reset()
      current.clipboardGuard.reset()
      current.diagnostics.sessions += 1
      return true
    }
  }

  /// Offers a local clipboard change for sending. Returns the payload when it is admitted (the
  /// caller sends it), or `nil` when the screen is inactive, the session is closed, or the loop
  /// guard rejects it.
  package func localClipboardChanged(_ payload: ClipboardPayload) -> ClipboardPayload? {
    lock.withLock {
      guard current.open, current.screen == .active else {
        current.diagnostics.outboundClipboardWhileInactive += 1
        return nil
      }
      do throws(CoreError) {
        try current.clipboardGuard.admitOutbound(payload, limit: clipboardLimit)
      } catch {
        if error.code == .clipboard(.oversized) {
          current.diagnostics.outboundClipboardOversized += 1
        } else {
          current.diagnostics.outboundClipboardLoopRejected += 1
        }
        return nil
      }
      current.diagnostics.outboundClipboardAdmitted += 1
      return payload
    }
  }

  /// Ends the current session generation with its one cleanup: queue reset, the ledger's release
  /// plan, the injector sweep, the ledger clear and a bounded disconnect. The only cleanup entry.
  /// A second call for the same generation runs nothing and returns `ran == false` at once, even
  /// while the first call's cleanup is still running; it does not wait for that cleanup. Only the
  /// caller that got `ran == true` knows the cleanup has finished.
  package func terminate(_ trigger: CleanupTrigger) async -> CleanupOutcome {
    let generation = lock.withLock { current.generation }
    return await terminate(trigger, generation: generation)
  }

  /// Consumes one session's event stream in order, then terminates that session: a finished
  /// stream as `.streamEnded(.transportClosed)`, a thrown `CoreError` by the M1-064 mapping, task
  /// cancellation as `.cancelled`, and a failed-closed event with `injectionFailureTrigger`.
  package func run(_ events: AsyncThrowingStream<KVMEvent, any Error>) async -> CleanupOutcome {
    let generation = lock.withLock { current.generation }
    let trigger: CleanupTrigger
    do {
      var failed = false
      for try await event in events {
        if Task.isCancelled { break }
        let (outcome, stillOpen) = lock.withLock {
          let outcome = handleLocked(event, generation: generation)
          return (outcome, current.open && current.generation == generation)
        }
        if outcome == .failedClosed {
          failed = true
          break
        }
        // Terminated from elsewhere, or superseded: stop reading the old stream.
        if !stillOpen { break }
      }
      if failed {
        trigger = Self.injectionFailureTrigger
      } else if Task.isCancelled {
        trigger = .cancelled
      } else {
        trigger = .streamEnded(.transportClosed)
      }
    } catch let error as CoreError {
      trigger = CleanupHooks.trigger(for: .failure(error))
    } catch is CancellationError {
      trigger = .cancelled
    } catch {
      trigger = .protocolViolation(
        CoreError(
          code: .internalFailure(.unclassified), severity: .error, retryDisposition: .backoff,
          cleanupDisposition: .completed))
    }
    return await terminate(trigger, generation: generation)
  }

  private func terminate(_ trigger: CleanupTrigger, generation: CleanupGeneration) async
    -> CleanupOutcome
  {
    let claimed = lock.withLock { () -> Bool in
      guard current.generation == generation, !current.claimed else { return false }
      current.claimed = true
      current.cleaning = true
      close()
      return true
    }
    guard claimed else { return .skipped }
    let outcome = await hooks.runOnce(trigger, generation: generation)
    lock.withLock {
      current.cleaning = false
      if outcome.ran {
        current.diagnostics.cleanupsRun += 1
        current.diagnostics.lastCleanupDisposition = outcome.disposition
      }
    }
    return outcome
  }

  /// Stops accepting events and leaves the active state. Called with the lock held.
  private func close() {
    current.open = false
    if current.screen == .active {
      current.screen = .inactive
      effects.screenBecameInactive()
    }
  }

  private func failClosed() -> ClientHandleOutcome {
    close()
    return .failedClosed
  }

  /// Called with the lock held.
  private func handleLocked(_ event: KVMEvent, generation: CleanupGeneration)
    -> ClientHandleOutcome
  {
    guard current.open, current.generation == generation else {
      current.diagnostics.droppedAfterClose += 1
      return .dropped
    }
    switch event {
    case .enterScreen(let screen, let position):
      return enter(screen, at: position)
    case .leaveScreen(let screen):
      return leave(screen)
    case .clipboard(let payload):
      return applyInbound(payload, event: event)
    case .key, .mouseButton:
      guard current.screen == .active else { return dropInactive() }
      return routeHeld(event)
    case .mouseMove, .scroll:
      guard current.screen == .active else { return dropInactive() }
      return inject(event)
    }
  }

  private func dropInactive() -> ClientHandleOutcome {
    current.diagnostics.droppedWhileInactive += 1
    return .dropped
  }

  private func enter(_ screen: ScreenID, at position: NormalizedPoint) -> ClientHandleOutcome {
    guard screen == localScreen else {
      current.diagnostics.droppedForeignScreen += 1
      return .dropped
    }
    guard effects.moveLocalPointer(to: position) else {
      current.diagnostics.pointerMoveFailures += 1
      return failClosed()
    }
    if current.screen == .inactive {
      current.screen = .active
      effects.screenBecameActive()
    }
    return .accepted
  }

  private func leave(_ screen: ScreenID) -> ClientHandleOutcome {
    guard screen == localScreen else {
      current.diagnostics.droppedForeignScreen += 1
      return .dropped
    }
    let plan = FailSafeCoordinator.releasePlan(for: current.ledger)
    for step in plan.steps {
      guard effects.inject(step) else {
        // The ledger keeps what it holds, so the cleanup's plan releases it again.
        current.diagnostics.injectFailures += 1
        return failClosed()
      }
      current.diagnostics.injected += 1
      current.diagnostics.leaveReleases += 1
    }
    current.ledger.reset()
    if current.screen == .active {
      current.screen = .inactive
      effects.screenBecameInactive()
    }
    return .accepted
  }

  private func routeHeld(_ event: KVMEvent) -> ClientHandleOutcome {
    switch current.ledger.record(event) {
    case .inject:
      return inject(event)
    case .injectUnheldRelease:
      current.diagnostics.injectedUnheldRelease += 1
      return inject(event)
    case .dropDuplicateDown:
      current.diagnostics.droppedDuplicateDown += 1
      return .dropped
    case .dropUnheldRepeat:
      current.diagnostics.droppedUnheldRepeat += 1
      return .dropped
    case .ignore:
      return .dropped
    }
  }

  private func inject(_ event: KVMEvent) -> ClientHandleOutcome {
    guard effects.inject(event) else {
      current.diagnostics.injectFailures += 1
      return failClosed()
    }
    current.diagnostics.injected += 1
    return .accepted
  }

  private func applyInbound(_ payload: ClipboardPayload, event: KVMEvent) -> ClientHandleOutcome {
    do throws(CoreError) {
      try current.clipboardGuard.admitInbound(payload, limit: clipboardLimit)
    } catch {
      if error.code == .clipboard(.oversized) {
        current.diagnostics.inboundClipboardOversized += 1
      } else {
        current.diagnostics.inboundClipboardLoopRejected += 1
      }
      return .dropped
    }
    _ = current.ledger.record(event)
    guard effects.applyClipboard(payload) else {
      current.diagnostics.clipboardApplyFailures += 1
      return .dropped
    }
    current.diagnostics.inboundClipboardApplied += 1
    return .accepted
  }
}

/// Lets `CleanupHooks`, built before the coordinator, reach it without a retain cycle.
private final class WeakCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private weak var coordinator: ClientCoordinator?

  func set(_ coordinator: ClientCoordinator) {
    lock.withLock { self.coordinator = coordinator }
  }

  func get() -> ClientCoordinator? {
    lock.withLock { coordinator }
  }
}

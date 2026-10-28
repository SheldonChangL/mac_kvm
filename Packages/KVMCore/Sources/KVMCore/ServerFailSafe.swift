import Foundation
import KVMContracts

/// Local input safety operations the server fail-safe drives (C-011).
///
/// Implementations live in the platform layer and must be synchronous,
/// idempotent and best effort: each call completes without awaiting network
/// or UI and may be repeated safely.
package protocol ServerLocalInputSafety: Sendable {
  /// Stops local event suppression. Must take effect immediately.
  func stopSuppression() throws(CoreError)
  func releaseAllKeys() throws(CoreError)
  func releaseAllMouseButtons() throws(CoreError)
  func restoreLocalCursor() throws(CoreError)
  func clearTransientState() throws(CoreError)
}

/// Server-side fail-safe and local recovery coordinator (M2-033).
///
/// `recoverLocal()` restores local input synchronously in a fixed order —
/// stop suppression first, then release keys, release buttons, restore the
/// cursor and clear transient state — attempting every step even when an
/// earlier one fails. It never awaits, so any session, tap or router failure
/// can call it from any context. A call made while a recovery is already
/// running returns `notRequired` immediately instead of recursing or blocking.
/// `recoverAll` instead joins a recovery already running and waits for its
/// result, so remote teardown happens only after local input was restored.
package final class ServerFailSafe: @unchecked Sendable {
  private let local: any ServerLocalInputSafety
  private let lock = NSLock()
  private var recovering = false
  private var lastDisposition: CleanupDisposition?
  private var joiners: [CheckedContinuation<CleanupDisposition, Never>] = []
  private var joinerObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  package init(local: any ServerLocalInputSafety) {
    self.local = local
  }

  /// Restores local input. Returns `completed`, `partial`, `failed`, or
  /// `notRequired` when another recovery is in progress.
  @discardableResult
  package func recoverLocal() -> CleanupDisposition {
    let alreadyRunning = lock.withLock {
      let running = recovering
      recovering = true
      return running
    }
    guard !alreadyRunning else { return .notRequired }

    var failures = 0
    for step in Step.allCases {
      do throws(CoreError) {
        try run(step)
      } catch {
        failures += 1
      }
    }
    let disposition: CleanupDisposition
    switch failures {
    case 0: disposition = .completed
    case Step.allCases.count: disposition = .failed
    default: disposition = .partial
    }
    let waiting = lock.withLock { () -> [CheckedContinuation<CleanupDisposition, Never>] in
      recovering = false
      lastDisposition = disposition
      defer { joiners = [] }
      return joiners
    }
    for joiner in waiting { joiner.resume(returning: disposition) }
    return disposition
  }

  /// Restores local input, or, when a recovery is already running, waits for
  /// that recovery and returns its result. Only async callers wait; the
  /// synchronous `recoverLocal()` keeps returning at once.
  private func recoverLocalJoiningInFlight() async -> CleanupDisposition {
    let started = recoverLocal()
    guard started == .notRequired else { return started }
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<CleanupDisposition, Never>) in
      let finished = lock.withLock { () -> CleanupDisposition? in
        guard recovering else { return lastDisposition ?? .notRequired }
        joiners.append(continuation)
        let satisfied = joinerObservers.filter { joiners.count >= $0.count }
        joinerObservers.removeAll { joiners.count >= $0.count }
        for observer in satisfied { observer.continuation.resume() }
        return nil
      }
      if let finished { continuation.resume(returning: finished) }
    }
  }

  /// Test scheduling barrier: completes once `count` callers are waiting for
  /// an in-flight recovery.
  package func waitForJoinedRecoveries(count: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        guard joiners.count < count else { return true }
        joinerObservers.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  private enum Step: CaseIterable {
    case stopSuppression
    case releaseKeys
    case releaseButtons
    case restoreCursor
    case clearTransient
  }

  private func run(_ step: Step) throws(CoreError) {
    switch step {
    case .stopSuppression: try local.stopSuppression()
    case .releaseKeys: try local.releaseAllKeys()
    case .releaseButtons: try local.releaseAllMouseButtons()
    case .restoreCursor: try local.restoreLocalCursor()
    case .clearTransient: try local.clearTransientState()
    }
  }

  /// Result of `recoverAll`.
  package struct RecoveryOutcome: Equatable, Sendable {
    package let disposition: CleanupDisposition
    /// `sessionLost` for the active target that was cleared, if any; the
    /// owner must apply it so the input reducer also returns to `local`.
    package let recoveryAction: InputAction?
  }

  /// Restores local input first, then closes every session.
  ///
  /// If another local recovery is already running, this waits for it to
  /// finish and reports its result before any session is closed.
  /// `afterLocalRestore` runs between the two phases (test observation hook).
  package func recoverAll(
    sessions: SessionManager,
    reason: DisconnectReason = .failure(ServerFailSafe.recoveryError),
    afterLocalRestore: @Sendable () -> Void = {}
  ) async -> RecoveryOutcome {
    let disposition = await recoverLocalJoiningInFlight()
    afterLocalRestore()
    let clearedTarget = await sessions.closeAll(reason: reason)
    return RecoveryOutcome(
      disposition: disposition, recoveryAction: clearedTarget.map { .sessionLost($0) })
  }

  package static let recoveryError = CoreError(
    code: .inputSafety(.cleanupRequired), severity: .error, retryDisposition: .never,
    cleanupDisposition: .completed)
}

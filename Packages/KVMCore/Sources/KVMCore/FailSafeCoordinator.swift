// Fail-safe coordinator for the client role (M1-063, C-011). First-party policy: the one ordered,
// idempotent and best-effort cleanup that every terminal path of the client runs, so nothing it
// injected stays pressed on the platform. It never logs, and its report carries no key or button
// identity (Frozen Decision 8).

import Foundation
import KVMContracts

/// The platform adapter the client fail-safe drives (C-011).
///
/// Every call is synchronous, idempotent and best effort: it completes without awaiting network or
/// UI and may be repeated safely. `release(_:)` (from `InputReleaser`) releases one key or button.
package protocol ClientInputSafety: InputReleaser {
  /// Stops and joins the injection worker, then resets the injection queue and drops any pending
  /// clipboard work, so no queued press can be injected after the releases (plan a.3, h.6).
  /// The drain worker must be a dedicated `Thread`, never a `Task` on the cooperative pool: this
  /// call blocks while it joins the worker, and `recover(plan:)` may run on a pool thread
  /// (`recoverJoiningInFlight`), so a pool-hosted worker could deadlock. Owners (M1-064) should run
  /// `recover(plan:)` off the cooperative pool.
  func clearTransientState() throws(CoreError)
  /// Releases everything the platform still holds from this client, whatever the plan said: the
  /// injector's own record of what it pressed is the authority (plan h.1). Idempotent.
  func releaseRemaining() throws(CoreError)
  /// Restores local input. A client that never suppresses local input implements it as a no-op;
  /// it is kept for C-011.
  func restoreLocalInput() throws(CoreError)
}

/// One step of the client fail-safe, in the order it runs.
package enum FailSafeStep: String, CaseIterable, Equatable, Sendable {
  case clearTransientState
  case releasePlan
  case releaseRemaining
  case restoreLocalInput
}

/// The outcome of one recovery. Counts and step names only: it never carries a key or button
/// identity, so it may be logged or reported.
package struct FailSafeReport: Equatable, Sendable {
  /// The disposition of `ReleaseAllKeys.execute` over the plan.
  package let releaseDisposition: CleanupDisposition
  package let releaseAttempted: Int
  package let releaseFailed: Int
  /// Steps that threw, or for `releasePlan`, whose plan was `partial` or `failed`.
  package let failedSteps: [FailSafeStep]
  /// The disposition of the whole recovery.
  package let disposition: CleanupDisposition

  package init(
    releaseDisposition: CleanupDisposition, releaseAttempted: Int, releaseFailed: Int,
    failedSteps: [FailSafeStep], disposition: CleanupDisposition
  ) {
    self.releaseDisposition = releaseDisposition
    self.releaseAttempted = releaseAttempted
    self.releaseFailed = releaseFailed
    self.failedSteps = failedSteps
    self.disposition = disposition
  }
}

/// Client-side fail-safe (M1-063), the client mirror of `ServerFailSafe`.
///
/// `recover(plan:)` runs, synchronously and in this order, attempting every step even when an
/// earlier one fails:
///
/// 1. `clearTransientState()`: the queue is reset first, so nothing injects after the releases.
/// 2. `ReleaseAllKeys.execute(plan)`: the ledger's release plan (keys, buttons, then modifiers).
/// 3. `releaseRemaining()`: the injector sweep, which covers releases dropped with the queue and
///    keys the ledger overflowed or never tracked (plan h.1). It runs whatever step 2 reported.
/// 4. `restoreLocalInput()`.
///
/// Disposition: `completed` when no step failed (an empty plan, `notRequired`, is not a failure);
/// `failed` when no step did any work successfully (an empty plan does none); `partial` otherwise. A `partial` or `failed` plan
/// is never swallowed: the sweep is its next step and the whole recovery reports at most
/// `partial`. A call made while a recovery is running returns `notRequired` at once instead of
/// recursing or blocking; `recoverJoiningInFlight(plan:)` instead waits for that run's result. A
/// later call runs the steps again, which the idempotent adapter makes harmless.
package final class FailSafeCoordinator: @unchecked Sendable {
  private let safety: any ClientInputSafety
  private let lock = NSLock()
  private var recovering = false
  private var lastDisposition: CleanupDisposition?
  private var storedReport: FailSafeReport?
  private var joiners: [CheckedContinuation<CleanupDisposition, Never>] = []
  private var joinerObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  package init(safety: any ClientInputSafety) {
    self.safety = safety
  }

  /// The report of the last finished recovery, or `nil` before the first one.
  package var lastReport: FailSafeReport? {
    lock.withLock { storedReport }
  }

  /// Maps the ledger's held keys and buttons to a release plan (plan h.7). Overflowed and
  /// untracked presses are not in it; the sweep covers them.
  package static func releasePlan(for ledger: InputStateLedger) -> ReleasePlan {
    ReleaseAllKeys.plan(
      keys: ledger.heldKeys.map { (key: $0.key, modifiers: $0.modifiers) },
      buttons: ledger.heldButtons)
  }

  /// Runs the recovery. Returns `completed`, `partial`, `failed`, or `notRequired` when another
  /// recovery is in progress.
  @discardableResult
  package func recover(plan: ReleasePlan) -> CleanupDisposition {
    let alreadyRunning = lock.withLock {
      let running = recovering
      recovering = true
      return running
    }
    guard !alreadyRunning else { return .notRequired }

    var failedSteps: [FailSafeStep] = []
    var succeeded = 0
    do throws(CoreError) {
      try safety.clearTransientState()
      succeeded += 1
    } catch {
      failedSteps.append(.clearTransientState)
    }
    let release = ReleaseAllKeys.execute(plan, with: safety)
    switch release.disposition {
    case .notRequired:
      break
    case .completed:
      succeeded += 1
    case .partial:
      succeeded += 1
      failedSteps.append(.releasePlan)
    case .failed:
      failedSteps.append(.releasePlan)
    }
    do throws(CoreError) {
      try safety.releaseRemaining()
      succeeded += 1
    } catch {
      failedSteps.append(.releaseRemaining)
    }
    do throws(CoreError) {
      try safety.restoreLocalInput()
      succeeded += 1
    } catch {
      failedSteps.append(.restoreLocalInput)
    }

    let disposition: CleanupDisposition
    if failedSteps.isEmpty {
      disposition = .completed
    } else if succeeded == 0 {
      disposition = .failed
    } else {
      disposition = .partial
    }
    let report = FailSafeReport(
      releaseDisposition: release.disposition, releaseAttempted: release.attempted,
      releaseFailed: release.failed, failedSteps: failedSteps, disposition: disposition)
    let waiting = lock.withLock { () -> [CheckedContinuation<CleanupDisposition, Never>] in
      recovering = false
      lastDisposition = disposition
      storedReport = report
      defer { joiners = [] }
      return joiners
    }
    for joiner in waiting { joiner.resume(returning: disposition) }
    return disposition
  }

  /// Runs the recovery, or, when one is already running, waits for it and returns its result.
  /// Only async callers wait; the synchronous `recover(plan:)` keeps returning at once.
  package func recoverJoiningInFlight(plan: ReleasePlan) async -> CleanupDisposition {
    let started = recover(plan: plan)
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

  /// Test scheduling barrier: completes once `count` callers are waiting for an in-flight
  /// recovery.
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
}

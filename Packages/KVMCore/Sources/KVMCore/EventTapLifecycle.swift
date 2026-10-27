import Foundation
import KVMContracts

/// Platform event-tap operations driven by the lifecycle.
///
/// The platform implementation owns the concrete tap and its run-loop
/// source. Every call is synchronous; `remove` must be idempotent.
package protocol EventTapControl: Sendable {
  func install() throws(CoreError)
  func reenable()
  func remove()
}

/// Outcome of a system tap-disable notification.
package enum EventTapRestartDecision: Equatable, Sendable {
  case restarted
  /// The budget is spent; the tap was removed and capture must fail open.
  case gaveUp
  case notRunning
}

/// Start/stop/restart lifecycle of the server event tap (M2-007).
///
/// `start` and `stop` are idempotent. When macOS disables the tap, the owner
/// first fails open (M2-013 stops suppression immediately), then calls
/// `handleSystemDisable()`, which re-enables the tap at most `restartBudget`
/// times per start and then removes it. `terminate()` removes the tap and
/// blocks later starts, so application termination always releases it.
/// State lives behind one `NSLock`; nothing awaits or logs.
package final class EventTapLifecycle: @unchecked Sendable {
  /// Upper bound for `restartBudget`.
  package static let maximumRestartBudget = 10

  private let control: any EventTapControl
  private let restartBudget: Int
  private let lock = NSLock()
  private var running = false
  private var terminated = false
  private var restarts = 0

  /// Returns `nil` for a budget outside `0...maximumRestartBudget`.
  package init?(control: any EventTapControl, restartBudget: Int) {
    guard (0...Self.maximumRestartBudget).contains(restartBudget) else { return nil }
    self.control = control
    self.restartBudget = restartBudget
  }

  package var isRunning: Bool { lock.withLock { running } }

  package func start() throws(CoreError) {
    lock.lock()
    defer { lock.unlock() }
    guard !terminated else { throw Self.terminatedError }
    guard !running else { return }
    try control.install()
    running = true
    restarts = 0
  }

  package func stop() {
    lock.withLock { removeLocked() }
  }

  package func handleSystemDisable() -> EventTapRestartDecision {
    lock.withLock {
      guard running else { return .notRunning }
      guard restarts < restartBudget else {
        removeLocked()
        return .gaveUp
      }
      restarts += 1
      control.reenable()
      return .restarted
    }
  }

  package func terminate() {
    lock.withLock {
      terminated = true
      removeLocked()
    }
  }

  private func removeLocked() {
    guard running else { return }
    running = false
    control.remove()
  }

  private static let terminatedError = CoreError(
    code: .lifecycle(.termination), severity: .info, retryDisposition: .never,
    cleanupDisposition: .completed)
}

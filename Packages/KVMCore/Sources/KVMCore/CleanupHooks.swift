// Cleanup hooks for the client role (M1-064). First-party policy: every terminal, error and cancel
// path of a client session (stream end, transport or TLS failure, protocol violation, keepalive
// timeout, cancellation, sleep, termination, display loss) funnels into one logical cleanup per
// session generation: the fail-safe recovery (queue reset, release plan, injector sweep), the ledger
// clear, then a bounded disconnect. It never waits on UI or network before the releases, and never
// logs (Frozen Decision 8).

import Foundation
import KVMContracts

/// Why a client session generation is being cleaned up (plan b.6, a.6.4).
package enum CleanupTrigger: Equatable, Sendable {
  /// The session ended for a reason no more specific trigger covers (EOF, user request).
  case streamEnded(DisconnectReason)
  /// A transport or TLS failure.
  case transportFailure(CoreError)
  case protocolViolation(CoreError)
  case keepaliveTimeout
  /// A newer reconnect generation or an explicit request cancelled the session.
  case cancelled
  case sleep
  /// SIGINT, SIGTERM, SIGHUP or application termination.
  case termination
  case displayLost
}

/// One session instance's cleanup token, issued by `CleanupHooks.beginGeneration()`.
package struct CleanupGeneration: Equatable, Hashable, Sendable {
  package let rawValue: UInt64
}

/// The result of `CleanupHooks.runOnce`. It carries no key, button or event identity.
package struct CleanupOutcome: Equatable, Sendable {
  /// `true` only for the one caller that ran the generation's cleanup.
  package let ran: Bool
  /// The fail-safe recovery's disposition; `notRequired` when `ran` is `false`.
  package let disposition: CleanupDisposition
  /// `true` when the disconnect did not finish within the timeout. The releases had already run.
  package let disconnectTimedOut: Bool

  package init(ran: Bool, disposition: CleanupDisposition, disconnectTimedOut: Bool = false) {
    self.ran = ran
    self.disposition = disposition
    self.disconnectTimedOut = disconnectTimedOut
  }

  package static let skipped = CleanupOutcome(ran: false, disposition: .notRequired)
}

/// Exactly one logical cleanup per session generation (M1-064).
///
/// `runOnce` claims the generation; the first caller runs, in order:
///
/// 1. `FailSafeCoordinator.recover(plan:)` over `plan()`, on a dedicated thread, never on the
///    cooperative pool (the adapter's `clearTransientState()` blocks while it joins the injection
///    worker, M1-063). Cleanups of different generations run one after the other.
/// 2. `clearLedger()`.
/// 3. `disconnect(reason)`, awaited but bounded by `disconnectTimeout` on `clock`; a disconnect
///    that hangs is abandoned (its task is cancelled) and reported with `disconnectTimedOut`.
///
/// Later callers for the same generation, and callers with a generation this instance never
/// issued, get `ran == false` at once and run nothing.
package final class CleanupHooks: @unchecked Sendable {
  package static let defaultDisconnectTimeout: Duration = .seconds(2)
  /// At most 15 bytes: Linux truncates or rejects longer pthread names.
  static let threadName = "mackvm-cleanup"

  private let failSafe: FailSafeCoordinator
  private let plan: @Sendable () -> ReleasePlan
  private let clearLedger: @Sendable () -> Void
  private let disconnect: @Sendable (DisconnectReason) async -> Void
  private let clock: any KVMClock
  private let disconnectTimeout: Duration
  private let lock = NSLock()
  private let recoveryLock = NSLock()
  private var nextGeneration: UInt64 = 0
  private var open: Set<UInt64> = []

  package init(
    failSafe: FailSafeCoordinator, plan: @escaping @Sendable () -> ReleasePlan,
    clearLedger: @escaping @Sendable () -> Void = {},
    disconnect: @escaping @Sendable (DisconnectReason) async -> Void,
    clock: any KVMClock = ContinuousKVMClock(),
    disconnectTimeout: Duration = CleanupHooks.defaultDisconnectTimeout
  ) {
    self.failSafe = failSafe
    self.plan = plan
    self.clearLedger = clearLedger
    self.disconnect = disconnect
    self.clock = clock
    self.disconnectTimeout = disconnectTimeout
  }

  /// Issues the token for a new session instance. Call once per session.
  package func beginGeneration() -> CleanupGeneration {
    lock.withLock {
      nextGeneration &+= 1
      open.insert(nextGeneration)
      return CleanupGeneration(rawValue: nextGeneration)
    }
  }

  /// Runs the generation's one logical cleanup, or returns `ran == false` when it was already
  /// claimed or the generation is unknown.
  package func runOnce(_ trigger: CleanupTrigger, generation: CleanupGeneration) async
    -> CleanupOutcome
  {
    let claimed = lock.withLock { open.remove(generation.rawValue) != nil }
    guard claimed else { return .skipped }

    let disposition = await recoverOffPool()
    let timedOut = await boundedDisconnect(Self.disconnectReason(for: trigger))
    return CleanupOutcome(ran: true, disposition: disposition, disconnectTimedOut: timedOut)
  }

  /// Residual risk: the recovery itself is not bounded. If an adapter step hangs, this
  /// `runOnce` never returns, and through `recoveryLock` every later generation's cleanup waits
  /// behind it, each parking one OS thread. The adapter contract (M1-063) requires every step to
  /// return promptly; the bound here covers only the disconnect.
  private func recoverOffPool() async -> CleanupDisposition {
    let failSafe = failSafe
    let plan = plan
    let clearLedger = clearLedger
    let recoveryLock = recoveryLock
    return await withCheckedContinuation {
      (continuation: CheckedContinuation<CleanupDisposition, Never>) in
      let thread = Thread {
        // Named from inside as well: Linux Foundation may not apply a name set before
        // start() to the running pthread.
        Thread.current.name = Self.threadName
        let disposition = recoveryLock.withLock { () -> CleanupDisposition in
          let result = failSafe.recover(plan: plan())
          clearLedger()
          return result
        }
        continuation.resume(returning: disposition)
      }
      thread.name = Self.threadName
      thread.start()
    }
  }

  /// Returns `true` when the disconnect timed out.
  private func boundedDisconnect(_ reason: DisconnectReason) async -> Bool {
    let gate = OnceGate()
    let disconnect = disconnect
    let clock = clock
    let timeout = disconnectTimeout
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let work = TaskBox()
      let timer = Task {
        do {
          try await clock.sleep(for: timeout)
        } catch {
          // A failed or cancelled timer still bounds the wait: treat it as expired. A timer
          // cancelled because the disconnect finished loses the gate below and does nothing.
        }
        if gate.claim() {
          work.cancel()
          continuation.resume(returning: true)
        }
      }
      work.set(
        Task {
          await disconnect(reason)
          if gate.claim() {
            timer.cancel()
            continuation.resume(returning: false)
          }
        })
    }
  }

  /// The trigger for a session's `DisconnectReason` (first-party mapping table).
  package static func trigger(for reason: DisconnectReason) -> CleanupTrigger {
    switch reason {
    case .userRequested, .transportClosed:
      return .streamEnded(reason)
    case .cancellation(let cancellation):
      return cancellation == .shutdown ? .termination : .cancelled
    case .applicationTermination:
      return .termination
    case .failure(let error):
      return trigger(for: error, reason: reason)
    }
  }

  private static func trigger(for error: CoreError, reason: DisconnectReason) -> CleanupTrigger {
    switch error.code {
    case .timeout(.keepalive):
      return .keepaliveTimeout
    case .timeout, .transport, .security:
      return .transportFailure(error)
    case .protocolViolation:
      return .protocolViolation(error)
    case .cancellation(let cancellation):
      return cancellation == .shutdown ? .termination : .cancelled
    case .lifecycle(.sleep):
      return .sleep
    case .lifecycle(.termination):
      return .termination
    case .lifecycle(.subsystemUnavailable):
      return .displayLost
    case .lifecycle(.wake), .permission, .inputSafety, .clipboard, .internalFailure:
      return .streamEnded(reason)
    }
  }

  /// The reason handed to `disconnect` for a trigger.
  package static func disconnectReason(for trigger: CleanupTrigger) -> DisconnectReason {
    switch trigger {
    case .streamEnded(let reason):
      return reason
    case .transportFailure(let error), .protocolViolation(let error):
      return .failure(error)
    case .keepaliveTimeout:
      return .failure(error(.timeout(.keepalive), retry: .backoff))
    case .cancelled:
      return .cancellation(.superseded)
    case .sleep:
      return .failure(error(.lifecycle(.sleep), retry: .backoff))
    case .termination:
      return .applicationTermination
    case .displayLost:
      return .failure(error(.lifecycle(.subsystemUnavailable), retry: .never))
    }
  }

  private static func error(_ code: CoreErrorCode, retry: RetryDisposition) -> CoreError {
    CoreError(
      code: code, severity: .error, retryDisposition: retry, cleanupDisposition: .completed)
  }
}

/// Holds the disconnect task so the timer, created first, can cancel it.
private final class TaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var cancelled = false

  func set(_ task: Task<Void, Never>) {
    let cancelNow = lock.withLock { () -> Bool in
      self.task = task
      return cancelled
    }
    if cancelNow { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock { () -> Task<Void, Never>? in
      cancelled = true
      return self.task
    }
    task?.cancel()
  }
}

/// Lets exactly one of two racing completions resume a continuation.
private final class OnceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      guard !claimed else { return false }
      claimed = true
      return true
    }
  }
}

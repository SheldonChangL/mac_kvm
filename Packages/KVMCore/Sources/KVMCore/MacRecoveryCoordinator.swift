/// A platform-neutral lifecycle or network signal (M1-061).
///
/// `KVMCore` may not import a platform network or power framework, so the
/// monitors live in the platform layers and translate their events into these
/// signals: on Linux, the lifecycle monitor of M4-020-FOLLOWUP-001; on macOS,
/// the monitors of the deferred Mac client.
package enum RecoverySignal: Equatable, Sendable {
  /// The network became available (`true`) or unavailable (`false`).
  case networkAvailable(Bool)
  /// The system is about to sleep.
  case willSleep
  /// The system woke from sleep.
  case didWake
}

/// The reconnect operations `RecoveryCoordinator` drives.
///
/// `ReconnectManager` conforms: `connect()` starts a new generation at once and
/// supersedes the previous one, and `disconnect()` stops the current generation
/// so that nothing reconnects until the next `connect()`. Both must return
/// promptly.
package protocol RecoveryReconnector: Sendable {
  func connect() async
  func disconnect() async
}

extension ReconnectManager: RecoveryReconnector {}

/// Turns lifecycle and network signals into reconnects (M1-061).
///
/// - `willSleep` runs the `onSleep` hook, which releases held input, and calls
///   `disconnect()` only after the hook returns. Every sleep runs the hook, and
///   a sleep drops a wake that still waits for the network.
/// - `didWake` calls `connect()` when the network is available. Otherwise it
///   remembers the wake, and the next `networkAvailable(true)` calls
///   `connect()` once, however many wakes arrived in between.
/// - `networkAvailable(_:)` records the network state. Losing the network never
///   disconnects, because keepalive and backoff handle a dead connection.
///   Regaining it connects only for a wake that waits for it.
///
/// Before any network signal the network counts as available. Each wake leads
/// to at most one `connect()`, and `ReconnectManager.connect()` supersedes the
/// previous generation, so repeated wakes never leave two sessions in force.
///
/// Signals are processed one at a time, in the order `handle(_:)` receives
/// them. A signal that arrives while another one is processed waits for it.
/// The `onSleep` hook must return promptly and must not wait for
/// `handle(_:)`. Nothing here logs.
package actor RecoveryCoordinator {
  /// The last reported network state; `true` before the first report.
  package private(set) var networkAvailable = true
  /// Whether a wake waits for the network before it connects.
  package private(set) var awaitingNetworkAfterWake = false

  private enum Condition {
    case processed(UInt64)
    case queued(Int)
  }

  private let reconnector: any RecoveryReconnector
  private let onSleep: @Sendable () async -> Void
  private var queued: [RecoverySignal] = []
  private var draining = false
  private var received: UInt64 = 0
  private var processed: UInt64 = 0
  private var nextWaiter: UInt64 = 0
  private var waiters:
    [UInt64: (condition: Condition, continuation: CheckedContinuation<Void, Never>)] = [:]

  package init(
    reconnector: any RecoveryReconnector, onSleep: @escaping @Sendable () async -> Void
  ) {
    self.reconnector = reconnector
    self.onSleep = onSleep
  }

  /// Queues `signal` behind every signal received before it and returns once
  /// it has been processed, or at once when the calling task is cancelled. A
  /// received signal is processed even after its caller stops waiting.
  package func handle(_ signal: RecoverySignal) async {
    received &+= 1
    let ticket = received
    queued.append(signal)
    resumeWaiters()
    if !draining {
      draining = true
      Task { await self.drain() }
    }
    await wait(for: .processed(ticket))
  }

  /// Test scheduling barrier: completes once at least `count` signals wait
  /// behind the one being processed, or when the waiting task is cancelled.
  package func waitForQueuedSignals(_ count: Int) async {
    await wait(for: .queued(count))
  }

  private func drain() async {
    while !queued.isEmpty {
      await apply(queued.removeFirst())
      processed &+= 1
      resumeWaiters()
    }
    draining = false
  }

  private func apply(_ signal: RecoverySignal) async {
    switch signal {
    case .networkAvailable(let available):
      networkAvailable = available
      guard available, awaitingNetworkAfterWake else { return }
      awaitingNetworkAfterWake = false
      await reconnector.connect()
    case .willSleep:
      awaitingNetworkAfterWake = false
      await onSleep()
      await reconnector.disconnect()
    case .didWake:
      guard networkAvailable else {
        awaitingNetworkAfterWake = true
        return
      }
      await reconnector.connect()
    }
  }

  private func satisfied(_ condition: Condition) -> Bool {
    switch condition {
    case .processed(let ticket): processed >= ticket
    case .queued(let count): queued.count >= count
    }
  }

  private func wait(for condition: Condition) async {
    guard !satisfied(condition) else { return }
    nextWaiter &+= 1
    let id = nextWaiter
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters[id] = (condition, continuation)
        }
      }
    } onCancel: {
      Task { await self.release(id) }
    }
  }

  private func release(_ id: UInt64) {
    waiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func resumeWaiters() {
    for (id, waiter) in waiters where satisfied(waiter.condition) {
      waiters[id] = nil
      waiter.continuation.resume()
    }
  }
}

import KVMContracts

/// The delay before each automatic reconnect attempt (M1-060).
///
/// The standard schedule waits 1, 2, 4 and 8 seconds, then 15 seconds for every
/// later retry. M1-018 leaves the sequence and its cap to this component.
package struct ReconnectBackoff: Equatable, Sendable {
  package static let standard = ReconnectBackoff(
    delays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8)], cap: .seconds(15))!

  private let delays: [Duration]
  private let cap: Duration

  /// `nil` unless `delays` is non-empty, positive and non-decreasing, and
  /// `cap` is at least the last delay.
  package init?(delays: [Duration], cap: Duration) {
    guard let last = delays.last, delays.allSatisfy({ $0 > .zero }),
      zip(delays, delays.dropFirst()).allSatisfy({ $0 <= $1 }), cap >= last
    else { return nil }
    self.delays = delays
    self.cap = cap
  }

  /// The delay before retry `retry`, counted from 1; `nil` below 1.
  package func delay(beforeRetry retry: Int) -> Duration? {
    guard retry >= 1 else { return nil }
    return retry <= delays.count ? delays[retry - 1] : cap
  }
}

/// Where a `ReconnectManager` is.
package enum ReconnectState: Equatable, Sendable {
  /// Never started, or stopped by a manual disconnect.
  case idle
  /// An attempt is running and has not reported a connection yet.
  case connecting
  /// The running attempt reported an established connection.
  case connected
  /// Waiting `delay` before retry `retry`, counted from 1.
  case waiting(retry: Int, delay: Duration)
  /// Stopped after a failure that is not retried automatically.
  case stopped(CoreErrorCode)
}

/// One connection attempt. It connects, awaits `established` once the
/// connection is up, and returns when the connection ends cleanly or throws
/// the error that ended it. It must stop promptly when its task is cancelled.
package typealias ReconnectAttempt =
  @Sendable (_ established: @escaping @Sendable () async -> Void) async throws(CoreError) -> Void

/// Runs connection attempts with capped backoff (M1-060).
///
/// `connect()` starts a new generation at once and cancels the previous one,
/// whether it is waiting or mid-attempt; a superseded generation's outcome is
/// ignored and it never attempts again. `disconnect()` is a manual disconnect:
/// it cancels the current generation and nothing reconnects until the next
/// `connect()`.
///
/// A connection that ends cleanly, or fails with retry disposition `backoff`,
/// is retried after the next backoff delay. An established connection resets
/// the backoff to its first delay. Any other disposition stops the generation:
/// `never` and `userActionRequired` need the user, and
/// `immediateAfterStateChange` waits for the owner of that state change (M1-061)
/// to call `connect()`. Waiting goes through `KVMClock`, and nothing here logs.
package actor ReconnectManager {
  package private(set) var state = ReconnectState.idle {
    didSet { resumeWaiters() }
  }

  private enum Condition {
    case settled
    case state(@Sendable (ReconnectState) -> Bool)
  }

  private let backoff: ReconnectBackoff
  private let clock: any KVMClock
  private let attempt: ReconnectAttempt
  private var generation: UInt64 = 0
  private var retries = 0
  private var task: Task<Void, Never>?
  private var runningLoops = 0
  private var nextWaiter: UInt64 = 0
  private var waiters:
    [UInt64: (condition: Condition, continuation: CheckedContinuation<Void, Never>)] =
      [:]

  package init(
    backoff: ReconnectBackoff = .standard, clock: any KVMClock,
    attempt: @escaping ReconnectAttempt
  ) {
    self.backoff = backoff
    self.clock = clock
    self.attempt = attempt
  }

  /// Starts a new connect generation and attempts at once.
  package func connect() {
    retire()
    generation &+= 1
    retries = 0
    state = .connecting
    let current = generation
    task = Task { await self.run(current) }
  }

  /// Cancels the current generation; nothing reconnects until `connect()`.
  /// Repeated calls are no-ops.
  package func disconnect() {
    retire()
    generation &+= 1
    state = .idle
  }

  /// Test scheduling barrier: completes once no generation is running, or
  /// when the waiting task is cancelled.
  package func waitUntilSettled() async {
    await wait(for: .settled)
  }

  /// Test scheduling barrier: completes once `matches(state)` holds, or when
  /// the waiting task is cancelled.
  package func waitForState(_ matches: @escaping @Sendable (ReconnectState) -> Bool) async {
    await wait(for: .state(matches))
  }

  private func retire() {
    task?.cancel()
    task = nil
  }

  private func run(_ current: UInt64) async {
    runningLoops += 1
    defer {
      runningLoops -= 1
      resumeWaiters()
    }
    while generation == current, !Task.isCancelled {
      state = .connecting
      var failure: CoreError?
      do throws(CoreError) {
        try await attempt { await self.established(current) }
      } catch {
        failure = error
      }
      guard generation == current, !Task.isCancelled else { return }
      if let failure, failure.retryDisposition != .backoff {
        state = .stopped(failure.code)
        return
      }
      retries += 1
      guard let delay = backoff.delay(beforeRetry: retries) else { return }
      state = .waiting(retry: retries, delay: delay)
      do throws(CoreError) {
        try await clock.sleep(for: delay)
      } catch {
        return
      }
    }
  }

  private func established(_ current: UInt64) {
    guard generation == current else { return }
    retries = 0
    state = .connected
  }

  private func satisfied(_ condition: Condition) -> Bool {
    switch condition {
    case .settled: runningLoops == 0
    case .state(let matches): matches(state)
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

import Foundation
import KVMCore
import Testing

@testable import KVMContracts

private func failure(_ retry: RetryDisposition) -> CoreError {
  CoreError(
    code: .transport(.reset), severity: .error, retryDisposition: retry,
    cleanupDisposition: .notRequired)
}

/// What one scripted attempt does.
private enum Step: Sendable {
  case fail(CoreError)
  case establishThenFail(CoreError)
  case establishThenEnd
  /// Suspends until the attempt's task is cancelled.
  case hang
}

/// Plays a script of attempt outcomes and records when each attempt started.
private final class AttemptScript: @unchecked Sendable {
  private let lock = NSLock()
  private let clock: TestKVMClock
  private var steps: [Step]
  private var startTimes: [Duration] = []
  private var cancelled = 0
  private var nextWaiter = 0
  private var waiters: [(id: Int, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  init(clock: TestKVMClock, _ steps: [Step]) {
    self.clock = clock
    self.steps = steps
  }

  var starts: [Duration] { lock.withLock { startTimes } }
  var cancellations: Int { lock.withLock { cancelled } }

  /// Completes once at least `count` attempts have started, or when the
  /// waiting task is cancelled (the suite's time limit turns a hang into a
  /// failure).
  func waitForAttempts(_ count: Int) async {
    let id = lock.withLock { () -> Int in
      nextWaiter += 1
      return nextWaiter
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          guard startTimes.count < count, !Task.isCancelled else { return true }
          waiters.append((id, count, continuation))
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
      }
      waiter?.resume()
    }
  }

  func attempt(_ established: @escaping @Sendable () async -> Void) async throws(CoreError) {
    let now = await clock.elapsed
    let (step, due) = lock.withLock { () -> (Step, [CheckedContinuation<Void, Never>]) in
      startTimes.append(now)
      let step = steps.isEmpty ? Step.hang : steps.removeFirst()
      let due = waiters.filter { startTimes.count >= $0.count }.map(\.continuation)
      waiters.removeAll { startTimes.count >= $0.count }
      return (step, due)
    }
    for waiter in due { waiter.resume() }
    switch step {
    case .fail(let error):
      throw error
    case .establishThenFail(let error):
      await established()
      throw error
    case .establishThenEnd:
      await established()
    case .hang:
      do {
        try await Task.sleep(for: .seconds(3600))
      } catch {
        lock.withLock { cancelled += 1 }
        throw failure(.never)
      }
    }
  }
}

private func manager(_ clock: TestKVMClock, _ script: AttemptScript) -> ReconnectManager {
  ReconnectManager(clock: clock) { established async throws(CoreError) in
    try await script.attempt(established)
  }
}

@Suite("M1-060 Reconnect backoff and manual disconnect", .timeLimit(.minutes(1)))
struct ReconnectManagerTests {
  @Test("the standard backoff is 1, 2, 4 and 8 seconds, then 15 seconds")
  func standardBackoff() {
    let backoff = ReconnectBackoff.standard
    let seconds = (1...8).map { backoff.delay(beforeRetry: $0) }
    #expect(
      seconds == [1, 2, 4, 8, 15, 15, 15, 15].map { Duration.seconds($0) })
    #expect(backoff.delay(beforeRetry: 0) == nil)
    #expect(backoff.delay(beforeRetry: -1) == nil)
    #expect(backoff.delay(beforeRetry: Int.max) == .seconds(15))
  }

  @Test("invalid: empty, non-positive, decreasing or under-capped schedules are refused")
  func invalidBackoff() {
    #expect(ReconnectBackoff(delays: [], cap: .seconds(1)) == nil)
    #expect(ReconnectBackoff(delays: [.zero], cap: .seconds(1)) == nil)
    #expect(ReconnectBackoff(delays: [.seconds(2), .seconds(1)], cap: .seconds(3)) == nil)
    #expect(ReconnectBackoff(delays: [.seconds(1), .seconds(4)], cap: .seconds(2)) == nil)
    #expect(ReconnectBackoff(delays: [.seconds(1)], cap: .seconds(1)) != nil)
  }

  @Test("failures are retried after 1, 2 and 4 seconds until a connection is established")
  func retriesUntilConnected() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(
      clock: clock,
      [.fail(failure(.backoff)), .fail(failure(.backoff)), .fail(failure(.backoff)), .hang])
    let reconnect = manager(clock, script)
    await reconnect.connect()
    for (attempt, delay) in [(1, 1), (2, 2), (3, 4)] {
      await script.waitForAttempts(attempt)
      try await clock.waitUntilPendingSleepCount(1)
      #expect(await reconnect.state == .waiting(retry: attempt, delay: .seconds(Int64(delay))))
      try await clock.advance(by: .seconds(Int64(delay)))
    }
    await script.waitForAttempts(4)
    #expect(script.starts == [0, 1, 3, 7].map { Duration.seconds($0) })
    #expect(await reconnect.state == .connecting)
    await reconnect.disconnect()
  }

  @Test("boundary: after four failures every wait is capped at 15 seconds")
  func capsAtFifteenSeconds() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(clock: clock, Array(repeating: .fail(failure(.backoff)), count: 7))
    let reconnect = manager(clock, script)
    await reconnect.connect()
    for (attempt, delay) in [(1, 1), (2, 2), (3, 4), (4, 8), (5, 15), (6, 15), (7, 15)] {
      await script.waitForAttempts(attempt)
      try await clock.waitUntilPendingSleepCount(1)
      #expect(await reconnect.state == .waiting(retry: attempt, delay: .seconds(Int64(delay))))
      try await clock.advance(by: .seconds(Int64(delay)))
    }
    await script.waitForAttempts(8)
    await reconnect.disconnect()
  }

  @Test("an established connection resets the backoff, and a clean end is retried")
  func establishedResetsBackoff() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(
      clock: clock,
      [
        .fail(failure(.backoff)), .fail(failure(.backoff)), .establishThenFail(failure(.backoff)),
        .establishThenEnd, .hang,
      ])
    let reconnect = manager(clock, script)
    await reconnect.connect()
    for (attempt, delay) in [(1, 1), (2, 2), (3, 1), (4, 1)] {
      await script.waitForAttempts(attempt)
      try await clock.waitUntilPendingSleepCount(1)
      #expect(
        await reconnect.state == .waiting(retry: delay == 2 ? 2 : 1, delay: .seconds(Int64(delay))))
      try await clock.advance(by: .seconds(Int64(delay)))
    }
    await script.waitForAttempts(5)
    await reconnect.disconnect()
  }

  @Test("failures that are not backoff-retryable stop without another attempt")
  func nonRetryableStops() async throws {
    for disposition in [RetryDisposition.never, .userActionRequired, .immediateAfterStateChange] {
      let clock = TestKVMClock()
      let error = failure(disposition)
      let script = AttemptScript(clock: clock, [.fail(error), .fail(error)])
      let reconnect = manager(clock, script)
      await reconnect.connect()
      await script.waitForAttempts(1)
      await reconnect.waitForState { if case .stopped = $0 { true } else { false } }
      #expect(await reconnect.state == .stopped(error.code))
      await reconnect.waitUntilSettled()
      #expect(await clock.pendingSleepCount == 0)
      #expect(script.starts.count == 1)
    }
  }

  @Test("manual disconnect cancels the wait and the attempt, and never reconnects")
  func manualDisconnectNeverReconnects() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(clock: clock, [.fail(failure(.backoff)), .hang])
    let reconnect = manager(clock, script)
    await reconnect.connect()
    await script.waitForAttempts(1)
    try await clock.waitUntilPendingSleepCount(1)
    await reconnect.disconnect()
    await reconnect.waitUntilSettled()
    #expect(await reconnect.state == .idle)
    #expect(await clock.pendingSleepCount == 0)
    try await clock.advance(by: .seconds(60))
    #expect(script.starts.count == 1)

    // A disconnect during an attempt cancels it; its failure is not retried.
    let busy = AttemptScript(clock: clock, [.hang])
    let second = manager(clock, busy)
    await second.connect()
    await busy.waitForAttempts(1)
    await second.disconnect()
    await second.waitUntilSettled()
    #expect(busy.cancellations == 1)
    #expect(await second.state == .idle)
    #expect(await clock.pendingSleepCount == 0)
  }

  @Test("cleanup: disconnect is idempotent and a later connect starts afresh")
  func disconnectIdempotent() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(
      clock: clock, [.fail(failure(.backoff)), .fail(failure(.backoff)), .hang])
    let reconnect = manager(clock, script)
    await reconnect.disconnect()
    await reconnect.connect()
    await script.waitForAttempts(1)
    try await clock.waitUntilPendingSleepCount(1)
    await reconnect.disconnect()
    await reconnect.disconnect()
    #expect(await reconnect.state == .idle)
    await reconnect.connect()
    await script.waitForAttempts(2)
    try await clock.waitUntilPendingSleepCount(1)
    #expect(await reconnect.state == .waiting(retry: 1, delay: .seconds(1)))
    await reconnect.disconnect()
  }

  @Test("a new connect generation cancels the old wait and attempts at once")
  func newGenerationCancelsOld() async throws {
    let clock = TestKVMClock()
    let script = AttemptScript(clock: clock, [.fail(failure(.backoff)), .hang])
    let reconnect = manager(clock, script)
    await reconnect.connect()
    await script.waitForAttempts(1)
    try await clock.waitUntilPendingSleepCount(1)
    await reconnect.connect()
    await script.waitForAttempts(2)
    #expect(script.starts == [.zero, .zero])
    #expect(await reconnect.state == .connecting)

    // The superseded generation's wait never fires another attempt.
    try await clock.advance(by: .seconds(60))
    #expect(script.starts.count == 2)
    await reconnect.disconnect()
    await reconnect.waitUntilSettled()
    #expect(script.cancellations == 1)
    #expect(await clock.pendingSleepCount == 0)
  }
}

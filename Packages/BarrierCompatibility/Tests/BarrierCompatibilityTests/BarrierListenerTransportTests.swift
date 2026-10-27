import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

/// Minimal fake transport: connect either succeeds, fails, or waits for an
/// explicit release so timeouts can be driven by `TestKVMClock`.
private final class FakeTransport: Transport, @unchecked Sendable {
  enum ConnectBehavior {
    case succeed
    case fail(CoreError)
    case hang
  }

  private let lock = NSLock()
  private let behavior: ConnectBehavior
  private var disconnects = 0
  private var hanging: CheckedContinuation<Void, Never>?
  let incomingBytes: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init(_ behavior: ConnectBehavior = .succeed) {
    self.behavior = behavior
    (incomingBytes, continuation) = AsyncThrowingStream.makeStream()
  }

  var disconnectCount: Int { lock.withLock { disconnects } }

  func connect() async throws(CoreError) {
    switch behavior {
    case .succeed:
      return
    case .fail(let error):
      throw error
    case .hang:
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          lock.withLock { hanging = continuation }
        }
      } onCancel: {
        let waiting = lock.withLock {
          let waiting = hanging
          hanging = nil
          return waiting
        }
        waiting?.resume()
      }
      throw CoreError(
        code: .cancellation(.requested), severity: .info, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    }
  }

  func send(_ data: Data) async throws(CoreError) {}

  func disconnect() async {
    lock.withLock { disconnects += 1 }
    continuation.finish()
  }
}

/// Test clock whose sleeps complete only when `fire()` is called or the
/// sleeping task is cancelled, with an arrival barrier so tests never poll.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var nextID = 0
  private var sleepers: [Int: CheckedContinuation<Bool, Never>] = [:]
  private var arrivals: [CheckedContinuation<Void, Never>] = []

  func sleep(for duration: Duration) async throws(CoreError) {
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    let fired = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let waiting: [CheckedContinuation<Void, Never>]? = lock.withLock {
          if Task.isCancelled { return nil }
          sleepers[id] = continuation
          let waiting = arrivals
          arrivals = []
          return waiting
        }
        guard let waiting else {
          continuation.resume(returning: false)
          return
        }
        for arrival in waiting { arrival.resume() }
      }
    } onCancel: {
      let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
      sleeper?.resume(returning: false)
    }
    guard fired else {
      throw CoreError(
        code: .cancellation(.requested), severity: .info, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    }
  }

  func waitForSleeper() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock {
        if sleepers.isEmpty { arrivals.append(continuation) }
        return !sleepers.isEmpty
      }
      if ready { continuation.resume() }
    }
  }

  func fire() {
    let due = lock.withLock {
      let due = Array(sleepers.values)
      sleepers = [:]
      return due
    }
    for sleeper in due { sleeper.resume(returning: true) }
  }
}

private let refused = CoreError(
  code: .transport(.refused), severity: .warning, retryDisposition: .backoff,
  cleanupDisposition: .notRequired)

private func policy(_ max: Int = 2, timeoutMilliseconds: Int = 500) throws -> BarrierListenerPolicy
{
  try BarrierListenerPolicy(
    maximumConcurrentConnections: max, connectTimeout: .milliseconds(timeoutMilliseconds))
}

@Suite("M2-024 BarrierListenerTransport")
struct BarrierListenerTransportTests {
  @Test("policy bounds are validated")
  func policyBounds() {
    #expect(throws: BarrierListenerError.invalidPolicy) {
      try BarrierListenerPolicy(maximumConcurrentConnections: 0, connectTimeout: .seconds(1))
    }
    #expect(throws: BarrierListenerError.invalidPolicy) {
      try BarrierListenerPolicy(
        maximumConcurrentConnections: BarrierListenerPolicy.largestConnectionLimit + 1,
        connectTimeout: .seconds(1))
    }
    #expect(throws: BarrierListenerError.invalidPolicy) {
      try BarrierListenerPolicy(maximumConcurrentConnections: 1, connectTimeout: .zero)
    }
  }

  @Test("happy path: an accepted connection is admitted and counted")
  func admit() async throws {
    let listener = BarrierListenerTransport(policy: try policy(), clock: ManualClock())
    let transport = FakeTransport()
    let admission = try await listener.admit(transport)
    #expect(await listener.activeCount == 1)
    await listener.release(admission)
    await listener.release(admission)
    #expect(await listener.activeCount == 0)
    #expect(transport.disconnectCount == 0)
  }

  @Test("boundary: connections over the limit are disconnected and rejected")
  func capacity() async throws {
    let listener = BarrierListenerTransport(policy: try policy(1), clock: ManualClock())
    _ = try await listener.admit(FakeTransport())
    let extra = FakeTransport()
    await #expect(throws: BarrierListenerError.capacityExceeded) {
      try await listener.admit(extra)
    }
    #expect(extra.disconnectCount == 1)
    #expect(await listener.activeCount == 1)
  }

  @Test("failure: a connect failure disconnects and maps to a typed error")
  func connectFailure() async throws {
    let listener = BarrierListenerTransport(policy: try policy(), clock: ManualClock())
    let failing = FakeTransport(.fail(refused))
    await #expect(throws: BarrierListenerError.connectFailed(refused)) {
      try await listener.admit(failing)
    }
    #expect(failing.disconnectCount == 1)
    #expect(await listener.activeCount == 0)
  }

  @Test("timeout: a connect that does not finish in time is disconnected")
  func connectTimeout() async throws {
    let clock = ManualClock()
    let listener = BarrierListenerTransport(policy: try policy(), clock: clock)
    let slow = FakeTransport(.hang)
    let attempt = Task { try await listener.admit(slow) }
    await clock.waitForSleeper()
    clock.fire()
    await #expect(throws: BarrierListenerError.connectTimedOut) { try await attempt.value }
    #expect(slow.disconnectCount == 1)
    #expect(await listener.activeCount == 0)
  }

  @Test("stop disconnects admitted transports, is idempotent and rejects later connections")
  func stop() async throws {
    let listener = BarrierListenerTransport(policy: try policy(), clock: ManualClock())
    let first = FakeTransport()
    _ = try await listener.admit(first)
    await listener.stop()
    await listener.stop()
    #expect(first.disconnectCount == 1)
    #expect(await listener.activeCount == 0)
    let late = FakeTransport()
    await #expect(throws: BarrierListenerError.stopped) { try await listener.admit(late) }
    #expect(late.disconnectCount == 1)
  }
}

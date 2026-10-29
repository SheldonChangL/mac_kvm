import Foundation
import KVMContracts
import KVMCore
import Testing

private let stepFailure = CoreError(
  code: .inputSafety(.cleanupFailed), severity: .error, retryDisposition: .never,
  cleanupDisposition: .failed)

/// Records the order of local safety steps; any step can be made to fail, and
/// one step can re-enter the fail-safe to prove reentrancy is safe.
private final class RecordingLocalSafety: ServerLocalInputSafety, @unchecked Sendable {
  enum Step: Equatable { case stopSuppression, releaseKeys, releaseButtons, restoreCursor, clear }

  private let lock = NSLock()
  private var recorded: [Step] = []
  private var failing: Set<String> = []
  var reenter: (() -> CleanupDisposition)?
  private(set) var nestedResult: CleanupDisposition?

  var steps: [Step] { lock.withLock { recorded } }

  func fail(_ step: Step) { lock.withLock { _ = failing.insert("\(step)") } }

  private func run(_ step: Step) throws(CoreError) {
    let shouldFail = lock.withLock {
      recorded.append(step)
      return failing.contains("\(step)")
    }
    if shouldFail { throw stepFailure }
  }

  func stopSuppression() throws(CoreError) {
    try run(.stopSuppression)
    if let reenter {
      self.reenter = nil
      nestedResult = reenter()
    }
  }
  func releaseAllKeys() throws(CoreError) { try run(.releaseKeys) }
  func releaseAllMouseButtons() throws(CoreError) { try run(.releaseButtons) }
  func restoreLocalCursor() throws(CoreError) { try run(.restoreCursor) }
  func clearTransientState() throws(CoreError) { try run(.clear) }
}

private let fullOrder: [RecordingLocalSafety.Step] = [
  .stopSuppression, .releaseKeys, .releaseButtons, .restoreCursor, .clear,
]

@Suite("M2-033 ServerFailSafe")
struct ServerFailSafeTests {
  @Test("happy path: suppression stops first, then every step runs in order")
  func order() {
    let local = RecordingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    #expect(failSafe.recoverLocal() == .completed)
    #expect(local.steps == fullOrder)
  }

  @Test("failure: a failing step does not skip later steps and reports partial")
  func partial() {
    let local = RecordingLocalSafety()
    local.fail(.releaseKeys)
    let failSafe = ServerFailSafe(local: local)
    #expect(failSafe.recoverLocal() == .partial)
    #expect(local.steps == fullOrder)
  }

  @Test("failure: all steps failing reports failed but still attempts each")
  func failed() {
    let local = RecordingLocalSafety()
    for step in fullOrder { local.fail(step) }
    #expect(ServerFailSafe(local: local).recoverLocal() == .failed)
    #expect(local.steps == fullOrder)
  }

  @Test("idempotent: repeated recovery reruns the idempotent steps")
  func repeated() {
    let local = RecordingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    #expect(failSafe.recoverLocal() == .completed)
    #expect(failSafe.recoverLocal() == .completed)
    #expect(local.steps == fullOrder + fullOrder)
  }

  @Test("reentrant: recovery triggered during recovery returns without recursion")
  func reentrancy() {
    let local = RecordingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    local.reenter = { failSafe.recoverLocal() }
    #expect(failSafe.recoverLocal() == .completed)
    #expect(local.nestedResult == .notRequired)
    #expect(local.steps == fullOrder)
  }

  @Test("concurrent recoveries never interleave steps")
  func concurrent() async {
    let local = RecordingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { _ = failSafe.recoverLocal() } }
    }
    let steps = local.steps
    #expect(steps.count % fullOrder.count == 0)
    #expect(!steps.isEmpty)
    for start in stride(from: 0, to: steps.count, by: fullOrder.count) {
      #expect(Array(steps[start..<start + fullOrder.count]) == fullOrder)
    }
  }

  @Test("recoverAll restores local before awaiting remote teardown")
  func recoverAll() async throws {
    let local = RecordingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    let manager = try #require(SessionManager(maximumSessions: 2))
    let order = OrderProbe()
    let outcome = await failSafe.recoverAll(sessions: manager) {
      order.mark(local.steps == fullOrder)
    }
    #expect(outcome.disposition == .completed)
    #expect(outcome.recoveryAction == nil)
    #expect(order.localFirst == true)
    #expect(await manager.count == 0)
  }
}

@Suite("M2-033 ServerFailSafe active target")
struct ServerFailSafeActiveTargetTests {
  @Test("recoverAll reports the cleared active target as a sessionLost action")
  func reportsActiveTarget() async throws {
    let target = ScreenID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x33, 1)))
    let manager = try #require(SessionManager(maximumSessions: 1))
    let session = ServerSession(
      id: SessionID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x33, 2))),
      screen: target, protocolSession: NoopProtocolSession())
    try await manager.register(session)
    try await manager.activate(target)
    let outcome = await ServerFailSafe(local: RecordingLocalSafety()).recoverAll(sessions: manager)
    #expect(outcome.recoveryAction == .sessionLost(target))
  }
}

private final class NoopProtocolSession: KVMProtocolSession, @unchecked Sendable {
  let events: AsyncThrowingStream<KVMEvent, any Error> = AsyncThrowingStream { $0.finish() }
  func connect() async throws(CoreError) {}
  func send(_ event: KVMEvent) async throws(CoreError) {}
  func disconnect(reason: DisconnectReason) async {}
}

/// Holds the first `stopSuppression` until released, so one recovery can be
/// kept in flight while another caller arrives.
private final class BlockingLocalSafety: ServerLocalInputSafety, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var shouldBlock = true
  private var isBlocked = false
  private var blockedArrival: CheckedContinuation<Void, Never>?
  private var completed = 0

  /// Recoveries that reached their last step.
  var completedRecoveries: Int { lock.withLock { completed } }

  func waitUntilBlocked() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        if isBlocked { return true }
        blockedArrival = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }

  func release() { gate.signal() }

  func stopSuppression() throws(CoreError) {
    let (block, arrival) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Never>?) in
      guard shouldBlock else { return (false, nil) }
      shouldBlock = false
      isBlocked = true
      defer { blockedArrival = nil }
      return (true, blockedArrival)
    }
    guard block else { return }
    arrival?.resume()
    gate.wait()
  }
  func releaseAllKeys() throws(CoreError) {}
  func releaseAllMouseButtons() throws(CoreError) {}
  func restoreLocalCursor() throws(CoreError) {}
  func clearTransientState() throws(CoreError) { lock.withLock { completed += 1 } }
}

@Suite("M2-033 ServerFailSafe in-flight recovery")
struct ServerFailSafeInFlightTests {
  /// Codex review H-7: recoverAll must not reach remote teardown while
  /// another local recovery is still running; it joins that recovery.
  @Test("recoverAll joins an in-flight recovery before remote teardown")
  func recoverAllJoinsInFlightRecovery() async throws {
    let local = BlockingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    let manager = try #require(SessionManager(maximumSessions: 1))
    let first = Task.detached { failSafe.recoverLocal() }
    await local.waitUntilBlocked()

    let order = OrderProbe()
    let second = Task {
      await failSafe.recoverAll(sessions: manager) {
        order.mark(local.completedRecoveries == 1)
      }
    }
    await failSafe.waitForJoinedRecoveries(count: 1)
    #expect(order.localFirst == nil, "remote teardown started before local recovery finished")
    local.release()

    #expect(await first.value == .completed)
    let outcome = await second.value
    #expect(order.localFirst == true)
    #expect(outcome.disposition == .completed)
    #expect(local.completedRecoveries == 1, "the joiner ran a second recovery instead of joining")
  }

  /// A synchronous caller never waits for the in-flight recovery.
  @Test("recoverLocal still returns notRequired at once during an in-flight recovery")
  func synchronousCallerNeverWaits() async {
    let local = BlockingLocalSafety()
    let failSafe = ServerFailSafe(local: local)
    let first = Task.detached { failSafe.recoverLocal() }
    await local.waitUntilBlocked()
    #expect(failSafe.recoverLocal() == .notRequired)
    local.release()
    #expect(await first.value == .completed)
  }
}

private final class OrderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?
  var localFirst: Bool? { lock.withLock { value } }
  func mark(_ observed: Bool) { lock.withLock { value = observed } }
}

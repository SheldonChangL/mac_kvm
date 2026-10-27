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
    let disposition = await failSafe.recoverAll(sessions: manager) {
      order.mark(local.steps == fullOrder)
    }
    #expect(disposition == .completed)
    #expect(order.localFirst == true)
    #expect(await manager.count == 0)
  }
}

private final class OrderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?
  var localFirst: Bool? { lock.withLock { value } }
  func mark(_ observed: Bool) { lock.withLock { value = observed } }
}

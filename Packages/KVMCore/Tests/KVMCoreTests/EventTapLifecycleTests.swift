import Foundation
import KVMContracts
import KVMCore
import Testing

private let installFailure = CoreError(
  code: .permission(.capabilityUnavailable), severity: .error,
  retryDisposition: .userActionRequired, cleanupDisposition: .notRequired)

private final class FakeTap: EventTapControl, @unchecked Sendable {
  private let lock = NSLock()
  private var log: [String] = []
  var failInstall = false

  var calls: [String] { lock.withLock { log } }

  func install() throws(CoreError) {
    lock.withLock { log.append("install") }
    if failInstall { throw installFailure }
  }
  func reenable() { lock.withLock { log.append("reenable") } }
  func remove() { lock.withLock { log.append("remove") } }
}

private func lifecycle(_ tap: FakeTap, budget: Int = 2) throws -> EventTapLifecycle {
  try #require(EventTapLifecycle(control: tap, restartBudget: budget))
}

@Suite("M2-007 EventTapLifecycle")
struct EventTapLifecycleTests {
  @Test("start and stop are idempotent")
  func idempotent() throws {
    let tap = FakeTap()
    let life = try lifecycle(tap)
    try life.start()
    try life.start()
    #expect(life.isRunning)
    life.stop()
    life.stop()
    #expect(!life.isRunning)
    #expect(tap.calls == ["install", "remove"])
  }

  @Test("install failure leaves the tap stopped and rethrows")
  func installFails() throws {
    let tap = FakeTap()
    tap.failInstall = true
    let life = try lifecycle(tap)
    #expect(throws: installFailure) { try life.start() }
    #expect(!life.isRunning)
    life.stop()
    #expect(tap.calls == ["install"])
  }

  @Test("system disable restarts within the budget, then gives up and removes the tap")
  func restartBudget() throws {
    let tap = FakeTap()
    let life = try lifecycle(tap, budget: 2)
    try life.start()
    #expect(life.handleSystemDisable() == .restarted)
    #expect(life.handleSystemDisable() == .restarted)
    #expect(life.handleSystemDisable() == .gaveUp)
    #expect(!life.isRunning)
    #expect(life.handleSystemDisable() == .notRunning)
    #expect(tap.calls == ["install", "reenable", "reenable", "remove"])
  }

  @Test("a fresh start resets the restart budget")
  func budgetReset() throws {
    let tap = FakeTap()
    let life = try lifecycle(tap, budget: 1)
    try life.start()
    #expect(life.handleSystemDisable() == .restarted)
    life.stop()
    try life.start()
    #expect(life.handleSystemDisable() == .restarted)
  }

  @Test("terminate releases the tap and blocks later starts")
  func terminate() throws {
    let tap = FakeTap()
    let life = try lifecycle(tap)
    try life.start()
    life.terminate()
    life.terminate()
    #expect(!life.isRunning)
    let terminated = CoreError(
      code: .lifecycle(.termination), severity: .info, retryDisposition: .never,
      cleanupDisposition: .completed)
    #expect(throws: terminated) { try life.start() }
    #expect(tap.calls == ["install", "remove"])
  }

  @Test("invalid restart budgets are rejected")
  func invalidBudget() {
    #expect(EventTapLifecycle(control: FakeTap(), restartBudget: -1) == nil)
    #expect(
      EventTapLifecycle(
        control: FakeTap(), restartBudget: EventTapLifecycle.maximumRestartBudget + 1) == nil)
    #expect(EventTapLifecycle(control: FakeTap(), restartBudget: 0) != nil)
  }
}

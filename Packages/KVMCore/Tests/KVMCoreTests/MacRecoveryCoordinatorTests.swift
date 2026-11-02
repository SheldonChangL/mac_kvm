import Foundation
import KVMContracts
import KVMCore
import Testing

/// One effect of the coordinator, in the order it happened.
private enum Effect: Equatable, Sendable {
  case cleanup
  case connect
  case disconnect
}

/// A scripted reconnector. It records `connect()` and `disconnect()`, and the sleep hooks of the
/// tests record `cleanup` into the same log, so the order across both is visible.
private final class EffectLog: RecoveryReconnector, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Effect] = []

  var effects: [Effect] { lock.withLock { recorded } }

  func record(_ effect: Effect) {
    lock.withLock { recorded.append(effect) }
  }

  func connect() async { record(.connect) }

  func disconnect() async { record(.disconnect) }
}

/// Holds every caller of `pass()` until `open()`; an open gate only counts arrivals. Every wait
/// here also ends when the waiting task is cancelled, so a regression fails within the suite's
/// time limit instead of hanging.
private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var arrivals = 0
  private var nextID = 0
  private var held: [Int: CheckedContinuation<Void, Never>] = [:]
  private var arrivalWaiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] =
    [:]

  /// Counts an arrival, then suspends until the gate is open or the calling task is cancelled.
  func pass() async {
    let id = makeID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let (proceed, due) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
          arrivals += 1
          let due = takeSatisfiedArrivalWaiters()
          guard !isOpen, !Task.isCancelled else { return (true, due) }
          held[id] = continuation
          return (false, due)
        }
        for waiter in due { waiter.resume() }
        if proceed { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { held.removeValue(forKey: id) }?.resume()
    }
  }

  func open() {
    let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      isOpen = true
      defer { held = [:] }
      return Array(held.values)
    }
    for continuation in released { continuation.resume() }
  }

  /// Completes once `count` callers have reached `pass()`, or when the waiting task is cancelled.
  func waitForArrivals(_ count: Int) async {
    let id = makeID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          guard arrivals < count, !Task.isCancelled else { return true }
          arrivalWaiters[id] = (count, continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { arrivalWaiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }

  private func makeID() -> Int {
    lock.withLock {
      nextID += 1
      return nextID
    }
  }

  /// Removes and returns the arrival waiters that are now satisfied. Call with the lock held.
  private func takeSatisfiedArrivalWaiters() -> [CheckedContinuation<Void, Never>] {
    let due = arrivalWaiters.filter { arrivals >= $0.value.count }
    for id in due.keys { arrivalWaiters[id] = nil }
    return due.values.map(\.continuation)
  }
}

/// Attempts for a real `ReconnectManager`. Each one reports an established connection and holds
/// it until its task is cancelled. It tracks the attempts in force (started and not cancelled),
/// so a test can check that two sessions are never in force together.
private final class HeldConnections: @unchecked Sendable {
  private let lock = NSLock()
  private var nextID = 0
  private var started = 0
  private var cancelled = 0
  private var inForce: Set<Int> = []
  private var cancelledIDs: Set<Int> = []
  private var mostInForce = 0
  private var startWaiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] =
    [:]

  var starts: Int { lock.withLock { started } }
  var cancellations: Int { lock.withLock { cancelled } }
  var maximumInForce: Int { lock.withLock { mostInForce } }

  func attempt(_ established: @escaping @Sendable () async -> Void) async throws(CoreError) {
    let id = makeID()
    await withTaskCancellationHandler {
      let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        started += 1
        if !Task.isCancelled, !cancelledIDs.contains(id) {
          inForce.insert(id)
          mostInForce = max(mostInForce, inForce.count)
        }
        let due = startWaiters.filter { started >= $0.value.count }
        for key in due.keys { startWaiters[key] = nil }
        return due.values.map(\.continuation)
      }
      for waiter in due { waiter.resume() }
      await established()
      try? await Task.sleep(for: .seconds(3600))
    } onCancel: {
      lock.withLock {
        cancelled += 1
        cancelledIDs.insert(id)
        inForce.remove(id)
      }
    }
    throw CoreError(
      code: .cancellation(.superseded), severity: .notice, retryDisposition: .never,
      cleanupDisposition: .notRequired)
  }

  /// Completes once `count` attempts have started, or when the waiting task is cancelled.
  func waitForStarts(_ count: Int) async {
    let id = makeID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          guard started < count, !Task.isCancelled else { return true }
          startWaiters[id] = (count, continuation)
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { startWaiters.removeValue(forKey: id) }?.continuation.resume()
    }
  }

  private func makeID() -> Int {
    lock.withLock {
      nextID += 1
      return nextID
    }
  }
}

/// The reconnect manager's states as a sleep hook saw them.
private final class StateProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var seen: [ReconnectState] = []

  var states: [ReconnectState] { lock.withLock { seen } }

  func record(_ state: ReconnectState) {
    lock.withLock { seen.append(state) }
  }
}

/// A coordinator over a scripted reconnector whose sleep hook records `cleanup`.
private func recordingCoordinator(_ log: EffectLog) -> RecoveryCoordinator {
  RecoveryCoordinator(reconnector: log) { log.record(.cleanup) }
}

/// A reconnect manager whose attempts are `connections`.
private func heldManager(_ clock: TestKVMClock, _ connections: HeldConnections)
  -> ReconnectManager
{
  ReconnectManager(clock: clock) { established async throws(CoreError) in
    try await connections.attempt(established)
  }
}

@Suite("M1-061 Network change and sleep/wake recovery", .timeLimit(.minutes(1)))
struct MacRecoveryCoordinatorTests {
  @Test("sleep: the cleanup hook runs and returns before disconnect()")
  func sleepRunsTheCleanupHookBeforeDisconnecting() async {
    let log = EffectLog()
    let cleanup = Gate()
    let coordinator = RecoveryCoordinator(reconnector: log) {
      log.record(.cleanup)
      await cleanup.pass()
    }
    async let sleep: Void = coordinator.handle(.willSleep)
    await cleanup.waitForArrivals(1)
    #expect(log.effects == [.cleanup])
    cleanup.open()
    await sleep
    #expect(log.effects == [.cleanup, .disconnect])
  }

  @Test("a wake with the network available connects at once")
  func wakeConnectsAtOnceWhenTheNetworkIsAvailable() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.networkAvailable(true))
    await coordinator.handle(.didWake)
    #expect(log.effects == [.connect])
    #expect(await coordinator.awaitingNetworkAfterWake == false)
  }

  @Test("boundary: before any network signal the network counts as available")
  func beforeAnyNetworkSignalTheNetworkCountsAsAvailable() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    #expect(await coordinator.networkAvailable)
    #expect(await coordinator.awaitingNetworkAfterWake == false)
    await coordinator.handle(.didWake)
    #expect(log.effects == [.connect])
  }

  @Test("boundary: a wake without network does not connect; it waits for the network")
  func wakeWithoutNetworkDoesNotConnect() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.networkAvailable(false))
    await coordinator.handle(.didWake)
    #expect(log.effects.isEmpty)
    #expect(await coordinator.networkAvailable == false)
    #expect(await coordinator.awaitingNetworkAfterWake)
  }

  @Test("the network returning after a wake connects once; a later flap does not reconnect")
  func lateNetworkAfterWakeConnectsOnce() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.networkAvailable(false))
    await coordinator.handle(.didWake)
    #expect(log.effects.isEmpty)
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.connect])
    #expect(await coordinator.awaitingNetworkAfterWake == false)
    await coordinator.handle(.networkAvailable(false))
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.connect])
  }

  @Test("duplicate wakes: one connect per outage, and one per wake while the network is up")
  func duplicateWakesConnectOncePerWakeAndOncePerOutage() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.networkAvailable(false))
    for _ in 0..<3 { await coordinator.handle(.didWake) }
    #expect(log.effects.isEmpty)
    #expect(await coordinator.awaitingNetworkAfterWake)
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.connect])
    #expect(await coordinator.awaitingNetworkAfterWake == false)
    // Each later wake connects once; ReconnectManager supersedes the earlier generation
    // (duplicateWakeSupersedesThroughTheReconnectManager).
    await coordinator.handle(.didWake)
    await coordinator.handle(.didWake)
    #expect(log.effects == [.connect, .connect, .connect])
  }

  @Test("failure: losing the network while connected neither disconnects nor reconnects")
  func networkLossWhileConnectedDoesNothing() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.didWake)
    #expect(log.effects == [.connect])
    await coordinator.handle(.networkAvailable(false))
    #expect(log.effects == [.connect])
    #expect(await coordinator.networkAvailable == false)
    #expect(await coordinator.awaitingNetworkAfterWake == false)
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.connect])
  }

  @Test("invalid order: network reports with no wake waiting only update the network state")
  func networkReportsWithoutAWakeCauseNoEffect() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    for available in [true, true, false, false] {
      await coordinator.handle(.networkAvailable(available))
    }
    #expect(await coordinator.networkAvailable == false)
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects.isEmpty)
    #expect(await coordinator.networkAvailable)
    #expect(await coordinator.awaitingNetworkAfterWake == false)
  }

  @Test("cancel: a sleep drops a wake that still waits for the network")
  func sleepCancelsAPendingWakeReconnect() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.networkAvailable(false))
    await coordinator.handle(.didWake)
    await coordinator.handle(.willSleep)
    #expect(log.effects == [.cleanup, .disconnect])
    #expect(await coordinator.awaitingNetworkAfterWake == false)
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.cleanup, .disconnect])
    await coordinator.handle(.didWake)
    #expect(log.effects == [.cleanup, .disconnect, .connect])
  }

  @Test("cleanup: every sleep runs the hook before disconnect(), also a repeated one")
  func repeatedSleepRunsTheCleanupEveryTime() async {
    let log = EffectLog()
    let coordinator = recordingCoordinator(log)
    await coordinator.handle(.willSleep)
    await coordinator.handle(.willSleep)
    #expect(log.effects == [.cleanup, .disconnect, .cleanup, .disconnect])
  }

  @Test("ordering: a wake that arrives during the sleep cleanup waits for the sleep to finish")
  func signalsAreProcessedOneAtATimeInArrivalOrder() async {
    let log = EffectLog()
    let cleanup = Gate()
    let coordinator = RecoveryCoordinator(reconnector: log) {
      log.record(.cleanup)
      await cleanup.pass()
    }
    async let sleep: Void = coordinator.handle(.willSleep)
    await cleanup.waitForArrivals(1)
    async let wake: Void = coordinator.handle(.didWake)
    await coordinator.waitForQueuedSignals(1)
    #expect(log.effects == [.cleanup])
    cleanup.open()
    await sleep
    await wake
    #expect(log.effects == [.cleanup, .disconnect, .connect])
  }

  @Test("cancel: callers that stop waiting still have their signals processed, in order")
  func cancelledCallersStillHaveTheirSignalsProcessed() async {
    let log = EffectLog()
    let cleanup = Gate()
    let returned = Gate()
    returned.open()
    let coordinator = RecoveryCoordinator(reconnector: log) {
      log.record(.cleanup)
      await cleanup.pass()
    }
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await coordinator.handle(.willSleep)
        await returned.pass()
      }
      await cleanup.waitForArrivals(1)
      group.addTask {
        await coordinator.handle(.didWake)
        await returned.pass()
      }
      await coordinator.waitForQueuedSignals(1)
      group.cancelAll()
      // Both callers return while the sleep cleanup still holds.
      await returned.waitForArrivals(2)
      #expect(log.effects == [.cleanup])
      cleanup.open()
    }
    // Signals are processed in order, so this returns after the sleep and the wake.
    await coordinator.handle(.networkAvailable(true))
    #expect(log.effects == [.cleanup, .disconnect, .connect])
  }

  @Test("round trip: sleep stops ReconnectManager after the cleanup; the network reconnects it")
  func sleepAndWakeDriveTheReconnectManager() async throws {
    let clock = TestKVMClock()
    let connections = HeldConnections()
    let manager = heldManager(clock, connections)
    let log = EffectLog()
    let probe = StateProbe()
    let coordinator = RecoveryCoordinator(reconnector: manager) {
      log.record(.cleanup)
      probe.record(await manager.state)
    }
    await manager.connect()
    await connections.waitForStarts(1)
    await manager.waitForState { $0 == .connected }

    await coordinator.handle(.willSleep)
    #expect(log.effects == [.cleanup])
    #expect(probe.states == [.connected])
    #expect(await manager.state == .idle)
    await manager.waitUntilSettled()
    #expect(connections.cancellations == 1)
    try await clock.advance(by: .seconds(60))
    #expect(connections.starts == 1)

    await coordinator.handle(.networkAvailable(false))
    await coordinator.handle(.didWake)
    #expect(await manager.state == .idle)
    #expect(connections.starts == 1)

    await coordinator.handle(.networkAvailable(true))
    await connections.waitForStarts(2)
    await manager.waitForState { $0 == .connected }
    #expect(connections.maximumInForce == 1)
    await manager.disconnect()
    await manager.waitUntilSettled()
    #expect(connections.starts == 2)
    #expect(connections.cancellations == 2)
  }

  @Test("round trip: a duplicate wake supersedes the first generation; one session is in force")
  func duplicateWakeSupersedesThroughTheReconnectManager() async {
    let clock = TestKVMClock()
    let connections = HeldConnections()
    let manager = heldManager(clock, connections)
    let coordinator = RecoveryCoordinator(reconnector: manager) {}
    await coordinator.handle(.didWake)
    await connections.waitForStarts(1)
    await coordinator.handle(.didWake)
    #expect(connections.cancellations == 1)
    await connections.waitForStarts(2)
    await manager.waitForState { $0 == .connected }
    #expect(connections.maximumInForce == 1)
    await manager.disconnect()
    await manager.waitUntilSettled()
    #expect(connections.starts == 2)
    #expect(connections.cancellations == 2)
  }

  @Test("the production source imports no platform module and never logs")
  func productionSourceImportsNoPlatformModuleAndNeverLogs() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // KVMCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // KVMCore
      .appendingPathComponent("Sources/KVMCore/MacRecoveryCoordinator.swift")
    let code = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("//") }
    #expect(code.contains { $0.hasPrefix("package actor RecoveryCoordinator") })
    #expect(code.filter { $0.hasPrefix("import ") }.allSatisfy { $0 == "import KVMContracts" })
    let forbidden = [
      "NWPath", "NSWorkspace", "IORegister", "Glibc", "print(", "Print(", "dump(", "Logger",
      "os_log", "NSLog", "fputs",
    ]
    for word in forbidden {
      #expect(!code.contains { $0.contains(word) }, "production code mentions \(word)")
    }
  }
}

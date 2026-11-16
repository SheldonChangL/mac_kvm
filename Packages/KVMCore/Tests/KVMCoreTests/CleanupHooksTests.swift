import Foundation
import KVMContracts
import KVMCore
import Testing

private func failure(_ code: CoreErrorCode) -> CoreError {
  CoreError(
    code: code, severity: .error, retryDisposition: .backoff, cleanupDisposition: .completed)
}

private enum Call: Equatable {
  case clear
  case release(KVMEvent)
  case sweep, restore, ledger
  case disconnect(DisconnectReason)
  case disconnectFinished
}

/// Records every step of a cleanup in order, from the adapter, the ledger and the disconnect.
private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Call] = []
  private var threads: [String] = []
  private var failing = false

  var calls: [Call] { lock.withLock { recorded } }
  var stepThreadNames: [String] { lock.withLock { threads } }
  func append(_ call: Call) { lock.withLock { recorded.append(call) } }
  func failEverything() { lock.withLock { failing = true } }
  var shouldFail: Bool { lock.withLock { failing } }
  func noteThread() {
    let name = Thread.current.name ?? ""
    lock.withLock { threads.append(name) }
  }
}

private let stepFailure = CoreError(
  code: .inputSafety(.cleanupFailed), severity: .error, retryDisposition: .never,
  cleanupDisposition: .failed)

private struct RecordingSafety: ClientInputSafety {
  let recorder: Recorder

  func clearTransientState() throws(CoreError) {
    recorder.noteThread()
    recorder.append(.clear)
    if recorder.shouldFail { throw stepFailure }
  }
  func release(_ event: KVMEvent) throws(CoreError) {
    recorder.append(.release(event))
    if recorder.shouldFail { throw stepFailure }
  }
  func releaseRemaining() throws(CoreError) {
    recorder.append(.sweep)
    if recorder.shouldFail { throw stepFailure }
  }
  func restoreLocalInput() throws(CoreError) {
    recorder.append(.restore)
    if recorder.shouldFail { throw stepFailure }
  }
}

/// A clock whose sleeps finish only when the test fires them; it reports when a sleep starts.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var sleeper: CheckedContinuation<Void, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private var sleepCount = 0

  func sleep(for duration: Duration) async throws(CoreError) {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let observer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        sleeper = continuation
        sleepCount += 1
        defer { started = nil }
        return started
      }
      observer?.resume()
    }
  }

  func waitForSleep() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        guard sleepCount == 0 else { return true }
        started = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }

  /// Releases a `waitForSleep()` caller even if no sleep ever started, so a broken
  /// implementation fails the test instead of hanging it.
  func stopWaiting() {
    let observer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      sleepCount += 1
      defer { started = nil }
      return started
    }
    observer?.resume()
  }

  func fire() {
    let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { sleeper = nil }
      return sleeper
    }
    pending?.resume()
  }
}

/// A disconnect that never returns until the test releases it.
private final class HangingDisconnect: @unchecked Sendable {
  private let lock = NSLock()
  private var waiter: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?
  private var didEnter = false

  func run() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let observer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        waiter = continuation
        didEnter = true
        defer { entered = nil }
        return entered
      }
      observer?.resume()
    }
  }

  func waitUntilEntered() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        guard !didEnter else { return true }
        entered = continuation
        return false
      }
      if ready { continuation.resume() }
    }
  }

  /// Releases a `waitUntilEntered()` caller even if the disconnect never started.
  func stopWaiting() {
    let observer = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      didEnter = true
      defer { entered = nil }
      return entered
    }
    observer?.resume()
  }

  func release() {
    let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { waiter = nil }
      return waiter
    }
    pending?.resume()
  }
}

private let heldPlan = ReleaseAllKeys.plan(
  keys: [(key: .letter(0), modifiers: ModifierState()), (key: .shift, modifiers: ModifierState())],
  buttons: [.left])

private func makeHooks(
  _ recorder: Recorder, plan: ReleasePlan = heldPlan, clock: any KVMClock = ContinuousKVMClock(),
  disconnect: (@Sendable (DisconnectReason) async -> Void)? = nil
) -> CleanupHooks {
  let failSafe = FailSafeCoordinator(safety: RecordingSafety(recorder: recorder))
  let defaultDisconnect: @Sendable (DisconnectReason) async -> Void = { reason in
    recorder.append(.disconnect(reason))
  }
  return CleanupHooks(
    failSafe: failSafe, plan: { plan }, clearLedger: { recorder.append(.ledger) },
    disconnect: disconnect ?? defaultDisconnect, clock: clock)
}

private let allTriggers: [CleanupTrigger] = [
  .streamEnded(.transportClosed),
  .streamEnded(.userRequested),
  .transportFailure(failure(.transport(.reset))),
  .transportFailure(failure(.security(.trustRejected))),
  .protocolViolation(failure(.protocolViolation(.malformed))),
  .keepaliveTimeout,
  .cancelled,
  .sleep,
  .termination,
  .displayLost,
]

private func expectedCalls(for trigger: CleanupTrigger) -> [Call] {
  [.clear] + heldPlan.steps.map { Call.release($0) } + [
    .sweep, .restore, .ledger, .disconnect(CleanupHooks.disconnectReason(for: trigger)),
  ]
}

@Suite("CleanupHooks (M1-064)", .timeLimit(.minutes(1)))
struct CleanupHooksTests {
  @Test(
    "each trigger runs the one cleanup in order: recovery, ledger clear, then disconnect",
    arguments: allTriggers)
  func eachTriggerRunsOnceInOrder(trigger: CleanupTrigger) async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    let outcome = await hooks.runOnce(trigger, generation: hooks.beginGeneration())
    #expect(outcome == CleanupOutcome(ran: true, disposition: .completed))
    #expect(recorder.calls == expectedCalls(for: trigger))
  }

  @Test("a second trigger for the same generation runs nothing")
  func secondTriggerSameGenerationDoesNotRun() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    let generation = hooks.beginGeneration()
    let first = await hooks.runOnce(.keepaliveTimeout, generation: generation)
    let callsAfterFirst = recorder.calls
    let second = await hooks.runOnce(.termination, generation: generation)
    #expect(first.ran)
    #expect(second == CleanupOutcome(ran: false, disposition: .notRequired))
    #expect(recorder.calls == callsAfterFirst)
  }

  @Test("a new generation runs its own cleanup")
  func newGenerationRunsAgain() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    let first = hooks.beginGeneration()
    _ = await hooks.runOnce(.cancelled, generation: first)
    let second = hooks.beginGeneration()
    #expect(first != second)
    let outcome = await hooks.runOnce(.streamEnded(.transportClosed), generation: second)
    #expect(outcome.ran)
    #expect(
      recorder.calls
        == expectedCalls(for: .cancelled) + expectedCalls(for: .streamEnded(.transportClosed)))
  }

  @Test("an older generation not yet cleaned up still cleans up after a newer one began")
  func olderGenerationStillRuns() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    let old = hooks.beginGeneration()
    _ = hooks.beginGeneration()
    let outcome = await hooks.runOnce(.cancelled, generation: old)
    #expect(outcome.ran)
    #expect(recorder.calls == expectedCalls(for: .cancelled))
  }

  @Test("a generation this instance never issued runs nothing")
  func unknownGenerationIsRejected() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    _ = hooks.beginGeneration()
    let other = makeHooks(Recorder())
    _ = other.beginGeneration()
    let foreign = other.beginGeneration()
    let outcome = await hooks.runOnce(.termination, generation: foreign)
    #expect(outcome == CleanupOutcome(ran: false, disposition: .notRequired))
    #expect(recorder.calls.isEmpty)
  }

  @Test("concurrent triggers for one generation: exactly one runs")
  func concurrentTriggersRunOnce() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    let generation = hooks.beginGeneration()
    let outcomes = await withTaskGroup(of: CleanupOutcome.self) { group in
      for trigger in allTriggers {
        group.addTask { await hooks.runOnce(trigger, generation: generation) }
      }
      var collected: [CleanupOutcome] = []
      for await outcome in group { collected.append(outcome) }
      return collected
    }
    #expect(outcomes.filter(\.ran).count == 1)
    #expect(recorder.calls.filter { $0 == .clear }.count == 1)
    #expect(recorder.calls.filter { $0 == .ledger }.count == 1)
  }

  @Test("the releases finish before the disconnect starts, even when the disconnect hangs")
  func hangingDisconnectIsBoundedAndReported() async {
    let recorder = Recorder()
    let clock = ManualClock()
    let hanging = HangingDisconnect()
    let hooks = makeHooks(recorder, clock: clock) { reason in
      recorder.append(.disconnect(reason))
      await hanging.run()
      recorder.append(.disconnectFinished)
    }
    let generation = hooks.beginGeneration()
    let outcome = Task {
      let result = await hooks.runOnce(.keepaliveTimeout, generation: generation)
      hanging.stopWaiting()
      clock.stopWaiting()
      return result
    }
    await hanging.waitUntilEntered()
    await clock.waitForSleep()
    #expect(recorder.calls == expectedCalls(for: .keepaliveTimeout))
    clock.fire()
    let result = await outcome.value
    #expect(result == CleanupOutcome(ran: true, disposition: .completed, disconnectTimedOut: true))
    #expect(!recorder.calls.contains(.disconnectFinished))
    hanging.release()
  }

  @Test("a disconnect that finishes before the timeout is not reported as timed out")
  func promptDisconnectIsNotTimedOut() async {
    let recorder = Recorder()
    let clock = ManualClock()
    let hooks = makeHooks(recorder, clock: clock)
    let outcome = await hooks.runOnce(.termination, generation: hooks.beginGeneration())
    #expect(!outcome.disconnectTimedOut)
    clock.fire()
  }

  @Test("the recovery runs on the dedicated cleanup thread, off the cooperative pool")
  func recoveryRunsOnDedicatedThread() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder)
    _ = await hooks.runOnce(.sleep, generation: hooks.beginGeneration())
    #expect(recorder.stepThreadNames == ["mackvm.cleanup-hooks"])
  }

  @Test("a failed recovery is reported, never swallowed, and the disconnect still runs")
  func failedRecoveryIsReported() async {
    let recorder = Recorder()
    recorder.failEverything()
    let hooks = makeHooks(recorder)
    let outcome = await hooks.runOnce(.displayLost, generation: hooks.beginGeneration())
    #expect(outcome == CleanupOutcome(ran: true, disposition: .failed))
    #expect(recorder.calls.last == .disconnect(CleanupHooks.disconnectReason(for: .displayLost)))
    #expect(recorder.calls.contains(.ledger))
  }

  @Test("an empty plan still runs the sweep and the disconnect")
  func emptyPlanBoundary() async {
    let recorder = Recorder()
    let hooks = makeHooks(recorder, plan: ReleasePlan(steps: []))
    let outcome = await hooks.runOnce(.cancelled, generation: hooks.beginGeneration())
    #expect(outcome == CleanupOutcome(ran: true, disposition: .completed))
    #expect(
      recorder.calls == [
        .clear, .sweep, .restore, .ledger, .disconnect(.cancellation(.superseded)),
      ])
  }

  @Test("mapping table: every disconnect reason maps to its trigger")
  func mappingTable() {
    let cases: [(DisconnectReason, CleanupTrigger)] = [
      (.userRequested, .streamEnded(.userRequested)),
      (.transportClosed, .streamEnded(.transportClosed)),
      (.cancellation(.requested), .cancelled),
      (.cancellation(.superseded), .cancelled),
      (.cancellation(.shutdown), .termination),
      (.applicationTermination, .termination),
      (.failure(failure(.transport(.reset))), .transportFailure(failure(.transport(.reset)))),
      (
        .failure(failure(.security(.trustRejected))),
        .transportFailure(failure(.security(.trustRejected)))
      ),
      (.failure(failure(.timeout(.handshake))), .transportFailure(failure(.timeout(.handshake)))),
      (.failure(failure(.timeout(.keepalive))), .keepaliveTimeout),
      (
        .failure(failure(.protocolViolation(.oversized))),
        .protocolViolation(failure(.protocolViolation(.oversized)))
      ),
      (.failure(failure(.cancellation(.superseded))), .cancelled),
      (.failure(failure(.cancellation(.shutdown))), .termination),
      (.failure(failure(.lifecycle(.sleep))), .sleep),
      (.failure(failure(.lifecycle(.termination))), .termination),
      (.failure(failure(.lifecycle(.subsystemUnavailable))), .displayLost),
      (.failure(failure(.lifecycle(.wake))), .streamEnded(.failure(failure(.lifecycle(.wake))))),
      (
        .failure(failure(.internalFailure(.unclassified))),
        .streamEnded(.failure(failure(.internalFailure(.unclassified))))
      ),
    ]
    for (reason, trigger) in cases {
      #expect(CleanupHooks.trigger(for: reason) == trigger, "\(reason)")
    }
  }

  @Test(
    "round trip: a trigger's disconnect reason maps back to the same trigger",
    arguments: allTriggers)
  func roundTrip(trigger: CleanupTrigger) {
    #expect(CleanupHooks.trigger(for: CleanupHooks.disconnectReason(for: trigger)) == trigger)
  }

  @Test("the outcome carries no key, button or event identity")
  func outcomeIsPrivacySafe() {
    let labels = Mirror(reflecting: CleanupOutcome(ran: true, disposition: .completed))
      .children.compactMap(\.label)
    #expect(labels == ["ran", "disposition", "disconnectTimedOut"])
  }
}

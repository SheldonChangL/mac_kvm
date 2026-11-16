import Foundation
import KVMContracts
import KVMCore
import Testing

private let stepFailure = CoreError(
  code: .inputSafety(.cleanupFailed), severity: .error, retryDisposition: .never,
  cleanupDisposition: .failed)

private let none = ModifierState()
private let shiftHeld = ModifierState(shift: true)

private func down(_ key: VirtualKey, _ modifiers: ModifierState = ModifierState()) -> KVMEvent {
  .key(key: key, phase: .down, modifiers: modifiers)
}
private func up(_ key: VirtualKey, _ modifiers: ModifierState = ModifierState()) -> KVMEvent {
  .key(key: key, phase: .up, modifiers: modifiers)
}

/// A model platform adapter. It records every call in order, models what the platform holds
/// (presses the injector delivered) and the injection queue, and can fail any step.
private final class RecordingSafety: ClientInputSafety, @unchecked Sendable {
  enum Call: Equatable {
    case clear
    case release(KVMEvent)
    case sweep, restore
  }
  enum Held: Equatable {
    case key(VirtualKey)
    case button(MouseButton)
  }

  private let lock = NSLock()
  private var recorded: [Call] = []
  private var platform: [Held] = []
  private var queue: [KVMEvent] = []
  private var failClear = false
  private var failSweep = false
  private var failRestore = false
  private var failingReleases: [Held] = []
  private var failAllReleases = false
  var reenter: (() -> CleanupDisposition)?
  private(set) var nestedResult: CleanupDisposition?

  var calls: [Call] { lock.withLock { recorded } }
  var platformHeld: [Held] { lock.withLock { platform } }

  func press(_ held: Held) {
    lock.withLock { if !platform.contains(held) { platform.append(held) } }
  }
  func enqueue(_ event: KVMEvent) { lock.withLock { queue.append(event) } }
  func failRelease(of held: Held) { lock.withLock { failingReleases.append(held) } }
  func failEveryRelease() { lock.withLock { failAllReleases = true } }
  func failClearStep() { lock.withLock { failClear = true } }
  func failSweepStep() { lock.withLock { failSweep = true } }
  func failRestoreStep() { lock.withLock { failRestore = true } }
  func failEverything() {
    lock.withLock {
      failClear = true
      failSweep = true
      failRestore = true
      failAllReleases = true
    }
  }

  private static func held(of event: KVMEvent) -> Held? {
    switch event {
    case .key(let key, _, _): return .key(key)
    case .mouseButton(let button, _): return .button(button)
    default: return nil
    }
  }

  func clearTransientState() throws(CoreError) {
    let shouldFail = lock.withLock {
      recorded.append(.clear)
      if !failClear { queue = [] }
      return failClear
    }
    if let reenter {
      self.reenter = nil
      nestedResult = reenter()
    }
    if shouldFail { throw stepFailure }
  }

  func release(_ event: KVMEvent) throws(CoreError) {
    let shouldFail = lock.withLock { () -> Bool in
      recorded.append(.release(event))
      guard let held = Self.held(of: event) else { return false }
      if failAllReleases || failingReleases.contains(held) { return true }
      platform.removeAll { $0 == held }
      return false
    }
    if shouldFail { throw stepFailure }
  }

  func releaseRemaining() throws(CoreError) {
    let shouldFail = lock.withLock {
      recorded.append(.sweep)
      if !failSweep { platform = [] }
      return failSweep
    }
    if shouldFail { throw stepFailure }
  }

  func restoreLocalInput() throws(CoreError) {
    let shouldFail = lock.withLock {
      recorded.append(.restore)
      return failRestore
    }
    if shouldFail { throw stepFailure }
  }
}

/// Walks a value and reports whether any part of it is a key or button identity or an event.
private func containsIdentity(_ value: Any) -> Bool {
  if value is VirtualKey || value is MouseButton || value is KVMEvent || value is HeldKey {
    return true
  }
  return Mirror(reflecting: value).children.contains { containsIdentity($0.value) }
}

private let keyAndButtonPlan = ReleaseAllKeys.plan(
  keys: [(key: .shift, modifiers: none), (key: .letter(0), modifiers: shiftHeld)],
  buttons: [.left])

@Suite("M1-063 FailSafeCoordinator", .timeLimit(.minutes(1)))
struct FailSafeCoordinatorTests {
  @Test("happy path: queue reset, ledger plan, injector sweep, then restore, in that order")
  func order() {
    let safety = RecordingSafety()
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .completed)
    let expected: [RecordingSafety.Call] =
      [.clear] + keyAndButtonPlan.steps.map { .release($0) } + [.sweep, .restore]
    #expect(safety.calls == expected)
    #expect(
      keyAndButtonPlan.steps == [
        up(.letter(0), shiftHeld), .mouseButton(button: .left, phase: .up), up(.shift),
      ])
    #expect(coordinator.lastReport?.disposition == .completed)
    #expect(coordinator.lastReport?.releaseDisposition == .completed)
    #expect(coordinator.lastReport?.releaseAttempted == 3)
    #expect(coordinator.lastReport?.failedSteps == [])
  }

  @Test("release disposition notRequired: an empty plan still sweeps and reports completed")
  func emptyPlan() {
    let safety = RecordingSafety()
    safety.press(.key(.letter(4)))
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: ReleasePlan(steps: [])) == .completed)
    #expect(safety.calls == [.clear, .sweep, .restore])
    #expect(safety.platformHeld.isEmpty)
    #expect(coordinator.lastReport?.releaseDisposition == .notRequired)
  }

  @Test("release disposition partial: the sweep still runs and the recovery reports partial")
  func releasePartial() {
    let safety = RecordingSafety()
    safety.press(.key(.letter(0)))
    safety.press(.key(.shift))
    safety.failRelease(of: .key(.letter(0)))
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .partial)
    #expect(safety.calls.last == .restore)
    #expect(safety.calls.contains(.sweep))
    #expect(safety.platformHeld.isEmpty)
    let report = coordinator.lastReport
    #expect(report?.releaseDisposition == .partial)
    #expect(report?.releaseFailed == 1)
    #expect(report?.failedSteps == [.releasePlan])
  }

  @Test("release disposition failed: the sweep is the next step and the recovery reports partial")
  func releaseFailed() {
    let safety = RecordingSafety()
    safety.press(.key(.letter(0)))
    safety.failEveryRelease()
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .partial)
    #expect(Array(safety.calls.suffix(2)) == [.sweep, .restore])
    #expect(safety.platformHeld.isEmpty)
    #expect(coordinator.lastReport?.releaseDisposition == .failed)
    #expect(coordinator.lastReport?.failedSteps == [.releasePlan])
  }

  @Test("failure: a failing step does not skip later steps")
  func everyStepAttempted() {
    for failing in ["clear", "sweep", "restore"] {
      let safety = RecordingSafety()
      switch failing {
      case "clear": safety.failClearStep()
      case "sweep": safety.failSweepStep()
      default: safety.failRestoreStep()
      }
      let coordinator = FailSafeCoordinator(safety: safety)
      #expect(coordinator.recover(plan: keyAndButtonPlan) == .partial, "\(failing)")
      let expected: [RecordingSafety.Call] =
        [.clear] + keyAndButtonPlan.steps.map { .release($0) } + [.sweep, .restore]
      #expect(safety.calls == expected, "\(failing)")
      #expect(coordinator.lastReport?.failedSteps.count == 1, "\(failing)")
    }
  }

  @Test("failure: every step failing reports failed and still attempts each")
  func allFailed() {
    let safety = RecordingSafety()
    safety.failEverything()
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .failed)
    #expect(safety.calls.count == 3 + keyAndButtonPlan.steps.count)
    #expect(
      coordinator.lastReport?.failedSteps
        == [.clearTransientState, .releasePlan, .releaseRemaining, .restoreLocalInput])
  }

  @Test("boundary: an empty plan with every other step failing reports failed")
  func emptyPlanAllOthersFail() {
    let safety = RecordingSafety()
    safety.failEverything()
    #expect(FailSafeCoordinator(safety: safety).recover(plan: ReleasePlan(steps: [])) == .failed)
  }

  @Test("h.1: a release dropped with the queue is released only by the injector sweep")
  func droppedReleaseCoveredBySweep() {
    let safety = RecordingSafety()
    var ledger = InputStateLedger()
    _ = ledger.record(down(.letter(5)))
    safety.press(.key(.letter(5)))
    _ = ledger.record(up(.letter(5)))
    safety.enqueue(up(.letter(5)))
    let plan = FailSafeCoordinator.releasePlan(for: ledger)
    #expect(plan.steps.isEmpty)
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: plan) == .completed)
    #expect(safety.platformHeld.isEmpty)
  }

  @Test("boundary: overflowed and untracked presses are released by the sweep")
  func overflowCoveredBySweep() {
    let safety = RecordingSafety()
    var ledger = InputStateLedger(maximumHeldKeys: 1, maximumHeldButtons: 0)
    for index in UInt8(0)..<4 {
      _ = ledger.record(down(.letter(index)))
      safety.press(.key(.letter(index)))
    }
    _ = ledger.record(.mouseButton(button: .right, phase: .down))
    safety.press(.button(.right))
    #expect(ledger.snapshot().hasOverflowed)
    let plan = FailSafeCoordinator.releasePlan(for: ledger)
    #expect(plan.steps == [up(.letter(0))])
    #expect(FailSafeCoordinator(safety: safety).recover(plan: plan) == .completed)
    #expect(safety.platformHeld.isEmpty)
  }

  @Test("releasePlan(for:) maps held keys and buttons in ReleaseAllKeys order")
  func planFromLedger() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.shift))
    _ = ledger.record(down(.letter(1), shiftHeld))
    _ = ledger.record(.mouseButton(button: .left, phase: .down))
    let plan = FailSafeCoordinator.releasePlan(for: ledger)
    #expect(
      plan.steps == [
        up(.letter(1), shiftHeld), .mouseButton(button: .left, phase: .up), up(.shift),
      ]
    )
  }

  @Test("idempotent: a later recovery reruns the idempotent steps with no extra effect")
  func repeated() {
    let safety = RecordingSafety()
    safety.press(.key(.letter(0)))
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .completed)
    let first = safety.calls
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .completed)
    #expect(safety.calls == first + first)
    #expect(safety.platformHeld.isEmpty)
  }

  @Test("reentrant: a recovery triggered during a recovery returns notRequired without running")
  func reentrancy() {
    let safety = RecordingSafety()
    let coordinator = FailSafeCoordinator(safety: safety)
    safety.reenter = { coordinator.recover(plan: keyAndButtonPlan) }
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .completed)
    #expect(safety.nestedResult == .notRequired)
    #expect(safety.calls.filter { $0 == .clear }.count == 1)
    #expect(safety.calls.filter { $0 == .sweep }.count == 1)
  }

  @Test("concurrent recoveries never interleave steps")
  func concurrent() async {
    let safety = RecordingSafety()
    let coordinator = FailSafeCoordinator(safety: safety)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 { group.addTask { _ = coordinator.recover(plan: keyAndButtonPlan) } }
    }
    let one: [RecordingSafety.Call] =
      [.clear] + keyAndButtonPlan.steps.map { .release($0) } + [.sweep, .restore]
    let calls = safety.calls
    #expect(!calls.isEmpty)
    #expect(calls.count % one.count == 0)
    for start in stride(from: 0, to: calls.count, by: one.count) {
      #expect(Array(calls[start..<min(start + one.count, calls.count)]) == one)
    }
  }

  @Test("privacy: the report carries no key or button identity")
  func reportHasNoIdentity() throws {
    let safety = RecordingSafety()
    safety.failRelease(of: .key(.letter(0)))
    let coordinator = FailSafeCoordinator(safety: safety)
    _ = coordinator.recover(plan: keyAndButtonPlan)
    let report = try #require(coordinator.lastReport)
    #expect(!containsIdentity(report))
    let text = String(describing: report)
    #expect(!text.contains("letter"))
    #expect(!text.contains("shift"))
    #expect(!text.contains("left"))
  }

  @Test("lastReport is nil before the first recovery")
  func noReportBeforeRecovery() {
    #expect(FailSafeCoordinator(safety: RecordingSafety()).lastReport == nil)
  }
}

/// Holds the first step it sees until released, so one recovery stays in flight while
/// other callers arrive.
private final class BlockingSafety: ClientInputSafety, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var shouldBlock = true
  private var isBlocked = false
  private var blockedArrival: CheckedContinuation<Void, Never>?
  private var clears = 0
  private var failRestore = false

  var clearCount: Int { lock.withLock { clears } }

  func failRestoreStep() { lock.withLock { failRestore = true } }

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

  /// Lets the blocked step go and stops blocking later ones.
  func open() {
    lock.withLock { shouldBlock = false }
    gate.signal()
  }

  /// Blocks the first call of any step, so a recovery stays in flight whatever step runs first.
  private func enter() {
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

  func clearTransientState() throws(CoreError) {
    enter()
    lock.withLock { clears += 1 }
  }
  func release(_ event: KVMEvent) throws(CoreError) { enter() }
  func releaseRemaining() throws(CoreError) { enter() }
  func restoreLocalInput() throws(CoreError) {
    enter()
    if lock.withLock({ failRestore }) { throw stepFailure }
  }
}

@Suite("M1-063 FailSafeCoordinator in-flight recovery", .timeLimit(.minutes(1)))
struct FailSafeCoordinatorInFlightTests {
  @Test("joiners wait for the in-flight recovery and get its result; the steps run once")
  func joinersGetFirstResult() async {
    let safety = BlockingSafety()
    safety.failRestoreStep()
    let coordinator = FailSafeCoordinator(safety: safety)
    let first = Task.detached { coordinator.recover(plan: keyAndButtonPlan) }
    await safety.waitUntilBlocked()
    #expect(coordinator.recover(plan: keyAndButtonPlan) == .notRequired)
    let joiners = (0..<3).map { _ in
      Task { await coordinator.recoverJoiningInFlight(plan: keyAndButtonPlan) }
    }
    // Whichever comes first: all three joiners waiting, or a joiner returning before the run ended.
    let (signals, signal) = AsyncStream<Bool>.makeStream()
    Task {
      await coordinator.waitForJoinedRecoveries(count: 3)
      signal.yield(true)
    }
    Task {
      _ = await joiners[0].value
      signal.yield(false)
    }
    var iterator = signals.makeAsyncIterator()
    let allJoined = await iterator.next()
    #expect(allJoined == true, "a joiner returned before the in-flight recovery finished")
    safety.open()
    #expect(await first.value == .partial)
    for joiner in joiners {
      #expect(await joiner.value == .partial)
    }
    #expect(safety.clearCount == 1)
  }

  @Test("an async caller with nothing in flight runs the recovery itself")
  func asyncCallerRuns() async {
    let safety = RecordingSafety()
    let coordinator = FailSafeCoordinator(safety: safety)
    #expect(await coordinator.recoverJoiningInFlight(plan: keyAndButtonPlan) == .completed)
    #expect(safety.calls.first == .clear)
    #expect(safety.calls.last == .restore)
  }
}

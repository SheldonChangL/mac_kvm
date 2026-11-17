import Foundation
import KVMContracts
import KVMCore
import Testing

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x63, value))
}

private let localScreen = ScreenID(rawValue: fixedUUID(1))
private let otherScreen = ScreenID(rawValue: fixedUUID(2))
private let serverDevice = DeviceID(rawValue: fixedUUID(3))
private let limit = ClipboardByteLimit(byteCount: 64)!
private let origin = NormalizedPoint(x: 0.25, y: 0.75)
private let noModifiers = ModifierState()
private let shifted = ModifierState(shift: true)

private func down(_ key: VirtualKey, _ modifiers: ModifierState = ModifierState()) -> KVMEvent {
  .key(key: key, phase: .down, modifiers: modifiers)
}
private func up(_ key: VirtualKey, _ modifiers: ModifierState = ModifierState()) -> KVMEvent {
  .key(key: key, phase: .up, modifiers: modifiers)
}
private func repeated(_ key: VirtualKey) -> KVMEvent {
  .key(key: key, phase: .repeatKey, modifiers: ModifierState())
}
private func press(_ button: MouseButton) -> KVMEvent {
  .mouseButton(button: button, phase: .down)
}
private func release(_ button: MouseButton) -> KVMEvent {
  .mouseButton(button: button, phase: .up)
}
private let enter = KVMEvent.enterScreen(screen: localScreen, position: origin)
private let leave = KVMEvent.leaveScreen(screen: localScreen)

private func failure(_ code: CoreErrorCode) -> CoreError {
  CoreError(
    code: code, severity: .error, retryDisposition: .backoff, cleanupDisposition: .completed)
}

private func inbound(_ text: String, hash: String, id: UInt8) -> ClipboardPayload {
  ClipboardPayload(
    transactionID: ClipboardTransactionID(rawValue: fixedUUID(0x80 | id)),
    origin: .remote(serverDevice), utf8Text: text, contentHash: hash)
}
private func outbound(_ text: String, hash: String, id: UInt8) -> ClipboardPayload {
  ClipboardPayload(
    transactionID: ClipboardTransactionID(rawValue: fixedUUID(0x40 | id)), origin: .local,
    utf8Text: text, contentHash: hash)
}

private enum Effect: Equatable {
  case inject(KVMEvent)
  case move(NormalizedPoint)
  case clipboard(ClipboardPayload)
  case active, inactive
}

private enum PlatformKey: Hashable {
  case key(String)
  case button(MouseButton)
}

/// A model of the Linux injection pipeline: effects queue events, a drain applies them to the
/// platform, and the fail-safe adapter resets the queue, releases and sweeps. It records every
/// safety violation it can see.
private final class Platform: @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [KVMEvent] = []
  private var heldSet: Set<PlatformKey> = []
  private var log: [Effect] = []
  private var violationList: [String] = []
  private var cleanupStarted = false
  private var clears = 0
  private var injectsLeft = Int.max
  private var moveFails = false
  private var clipboardFails = false
  /// When true, `inject` queues and only `drain()` applies; otherwise it applies at once.
  var queued = false
  /// When false, `releaseRemaining` does nothing, so the ledger's plan must release everything.
  var sweepEnabled = true

  var effects: [Effect] { lock.withLock { log } }
  var held: Set<PlatformKey> { lock.withLock { heldSet } }
  var violations: [String] { lock.withLock { violationList } }
  var clearCount: Int { lock.withLock { clears } }
  var injected: [KVMEvent] {
    effects.compactMap { effect in
      if case .inject(let event) = effect { return event }
      return nil
    }
  }

  func failInjects(after count: Int) { lock.withLock { injectsLeft = count } }
  func failMoves() { lock.withLock { moveFails = true } }
  func failClipboard() { lock.withLock { clipboardFails = true } }

  func record(_ effect: Effect) { lock.withLock { log.append(effect) } }

  func inject(_ event: KVMEvent) -> Bool {
    lock.withLock {
      if cleanupStarted { violationList.append("inject after cleanup") }
      guard injectsLeft > 0 else { return false }
      injectsLeft -= 1
      log.append(.inject(event))
      if queued { queue.append(event) } else { applyLocked(event) }
      return true
    }
  }

  func move(_ position: NormalizedPoint) -> Bool {
    lock.withLock {
      if cleanupStarted { violationList.append("move after cleanup") }
      guard !moveFails else { return false }
      log.append(.move(position))
      return true
    }
  }

  func applyClipboard(_ payload: ClipboardPayload) -> Bool {
    lock.withLock {
      guard !clipboardFails else { return false }
      log.append(.clipboard(payload))
      return true
    }
  }

  func drain() {
    lock.withLock {
      for event in queue { applyLocked(event) }
      queue = []
    }
  }

  func clearTransientState() {
    lock.withLock {
      cleanupStarted = true
      clears += 1
      queue = []
    }
  }

  func releaseNow(_ event: KVMEvent) { lock.withLock { applyLocked(event) } }

  /// When set, `sweep` signals `sweepEntered` and blocks until the gate is signalled.
  var sweepGate: DispatchSemaphore?
  let sweepEntered = DispatchSemaphore(value: 0)

  func sweep() {
    if let sweepGate {
      sweepEntered.signal()
      sweepGate.wait()
    }
    lock.withLock {
      guard sweepEnabled else { return }
      heldSet = []
    }
  }

  /// A new session may inject again.
  func reopen() { lock.withLock { cleanupStarted = false } }

  private func applyLocked(_ event: KVMEvent) {
    switch event {
    case .key(let key, let phase, _):
      let id = PlatformKey.key(String(describing: key))
      switch phase {
      case .down: heldSet.insert(id)
      case .up: heldSet.remove(id)
      case .repeatKey:
        if !heldSet.contains(id) { violationList.append("unpaired repeat injected") }
      }
    case .mouseButton(let button, let phase):
      if phase == .down {
        heldSet.insert(.button(button))
      } else {
        heldSet.remove(.button(button))
      }
    case .mouseMove, .scroll, .clipboard, .enterScreen, .leaveScreen:
      break
    }
  }
}

private struct Effects: ClientCoordinatorEffects {
  let platform: Platform
  func inject(_ event: KVMEvent) -> Bool { platform.inject(event) }
  func moveLocalPointer(to position: NormalizedPoint) -> Bool { platform.move(position) }
  func applyClipboard(_ payload: ClipboardPayload) -> Bool { platform.applyClipboard(payload) }
  func screenBecameActive() { platform.record(.active) }
  func screenBecameInactive() { platform.record(.inactive) }
}

private struct Safety: ClientInputSafety {
  let platform: Platform
  func clearTransientState() throws(CoreError) { platform.clearTransientState() }
  func release(_ event: KVMEvent) throws(CoreError) { platform.releaseNow(event) }
  func releaseRemaining() throws(CoreError) { platform.sweep() }
  func restoreLocalInput() throws(CoreError) {}
}

/// A scripted `KVMProtocolSession`: its stream yields the script, then finishes or throws.
private final class ScriptedSession: KVMProtocolSession, @unchecked Sendable {
  enum End {
    case finish
    case fail(any Error)
    case open
  }

  let events: AsyncThrowingStream<KVMEvent, any Error>
  private let continuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation
  private let lock = NSLock()
  private var reasons: [DisconnectReason] = []

  init(_ script: [KVMEvent], end: End = .finish) {
    (events, continuation) = AsyncThrowingStream.makeStream(of: KVMEvent.self)
    for event in script { continuation.yield(event) }
    switch end {
    case .finish: continuation.finish()
    case .fail(let error): continuation.finish(throwing: error)
    case .open: break
    }
  }

  var disconnects: [DisconnectReason] { lock.withLock { reasons } }

  func connect() async throws(CoreError) {}
  func send(_ event: KVMEvent) async throws(CoreError) {}
  func disconnect(reason: DisconnectReason) async {
    lock.withLock { reasons.append(reason) }
    continuation.finish()
  }
}

private struct Fixture {
  let platform = Platform()
  let session: ScriptedSession
  let coordinator: ClientCoordinator

  init(_ script: [KVMEvent] = [], end: ScriptedSession.End = .finish) {
    let session = ScriptedSession(script, end: end)
    self.session = session
    coordinator = ClientCoordinator.make(
      localScreen: localScreen, effects: Effects(platform: platform),
      clipboardLimit: limit, failSafe: FailSafeCoordinator(safety: Safety(platform: platform)),
      disconnect: { reason in await session.disconnect(reason: reason) })
  }

  @discardableResult
  func feed(_ events: [KVMEvent]) -> [ClientHandleOutcome] {
    events.map { coordinator.handle($0) }
  }
}

/// The TEST_STRATEGY safety invariants after a terminal path.
private func expectSafeAfterTerminal(
  _ fixture: Fixture, _ outcome: CleanupOutcome, sourceLocation: SourceLocation = #_sourceLocation
) async {
  #expect(outcome.ran, sourceLocation: sourceLocation)
  #expect(
    fixture.platform.held.isEmpty, "a key or button is still held", sourceLocation: sourceLocation)
  #expect(fixture.platform.violations.isEmpty, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.state == .inactive, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.ledgerSnapshot.heldKeyCount == 0, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.ledgerSnapshot.heldButtonCount == 0, sourceLocation: sourceLocation)
  let again = await fixture.coordinator.terminate(.termination)
  #expect(!again.ran, "a second cleanup ran", sourceLocation: sourceLocation)
  #expect(fixture.platform.clearCount == 1, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.diagnostics.cleanupsRun == 1, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.handle(enter) == .dropped, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.handle(down(.letter(1))) == .dropped, sourceLocation: sourceLocation)
  #expect(fixture.coordinator.state == .inactive, sourceLocation: sourceLocation)
  #expect(fixture.platform.violations.isEmpty, sourceLocation: sourceLocation)
  #expect(fixture.platform.held.isEmpty, sourceLocation: sourceLocation)
  expectNoIdentifiers(fixture.coordinator.diagnostics, sourceLocation: sourceLocation)
}

private func expectNoIdentifiers(
  _ diagnostics: ClientCoordinatorDiagnostics,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let text = String(describing: diagnostics) + String(reflecting: diagnostics)
  for forbidden in [
    "letter", "shift", "left", "right", "button", "secret", "hash", "0000-", "x:", "y:",
  ] {
    #expect(
      !text.lowercased().contains(forbidden), "diagnostics contain \(forbidden)",
      sourceLocation: sourceLocation)
  }
}

@Suite("ClientCoordinator (M1-063-FOLLOWUP-001)")
struct ClientCoordinatorTests {
  // MARK: Enter, inactive input

  @Test func enterMovesThePointerFirstThenBecomesActive() {
    let fixture = Fixture()
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.handle(enter) == .accepted)
    #expect(fixture.platform.effects == [.move(origin), .active])
    #expect(fixture.coordinator.state == .active)
  }

  @Test func enterForAnotherScreenIsDroppedAndCounted() {
    let fixture = Fixture()
    #expect(
      fixture.coordinator.handle(.enterScreen(screen: otherScreen, position: origin)) == .dropped)
    #expect(fixture.platform.effects.isEmpty)
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.diagnostics.droppedForeignScreen == 1)
  }

  @Test func inputWhileInactiveIsDroppedAndCounted() {
    let fixture = Fixture()
    let outcomes = fixture.feed([
      down(.letter(1)), press(.left), .mouseMove(position: origin), .scroll(deltaX: 0, deltaY: 1),
      up(.letter(1)),
    ])
    #expect(outcomes == Array(repeating: .dropped, count: 5))
    #expect(fixture.platform.effects.isEmpty)
    #expect(fixture.coordinator.diagnostics.droppedWhileInactive == 5)
    #expect(fixture.coordinator.ledgerSnapshot.heldKeyCount == 0)
  }

  @Test func pointerMoveFailureFailsClosed() async {
    let fixture = Fixture()
    fixture.platform.failMoves()
    #expect(fixture.coordinator.handle(enter) == .failedClosed)
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.handle(down(.letter(1))) == .dropped)
    #expect(fixture.platform.injected.isEmpty)
    #expect(fixture.coordinator.diagnostics.pointerMoveFailures == 1)
    let outcome = await fixture.coordinator.terminate(ClientCoordinator.injectionFailureTrigger)
    await expectSafeAfterTerminal(fixture, outcome)
  }

  // MARK: Ledger routing

  @Test func unpairedRepeatIsNeverInjected() {
    let fixture = Fixture()
    fixture.feed([enter, repeated(.letter(1))])
    #expect(fixture.platform.injected.isEmpty)
    #expect(fixture.coordinator.diagnostics.droppedUnheldRepeat == 1)
    #expect(fixture.platform.violations.isEmpty)
  }

  @Test func repeatOfAHeldKeyIsInjected() {
    let fixture = Fixture()
    fixture.feed([enter, down(.letter(1)), repeated(.letter(1))])
    #expect(fixture.platform.injected == [down(.letter(1)), repeated(.letter(1))])
  }

  @Test func duplicateDownIsDropped() {
    let fixture = Fixture()
    let outcomes = fixture.feed([
      enter, down(.letter(2)), down(.letter(2)), press(.left), press(.left),
    ])
    #expect(outcomes == [.accepted, .accepted, .dropped, .accepted, .dropped])
    #expect(fixture.platform.injected == [down(.letter(2)), press(.left)])
    #expect(fixture.coordinator.diagnostics.droppedDuplicateDown == 2)
  }

  @Test func unheldReleaseIsInjectedButNotRecorded() {
    let fixture = Fixture()
    fixture.feed([enter, up(.letter(3)), release(.right)])
    #expect(fixture.platform.injected == [up(.letter(3)), release(.right)])
    #expect(fixture.coordinator.diagnostics.injectedUnheldRelease == 2)
    #expect(fixture.coordinator.releasePlan().steps.isEmpty)
  }

  @Test func pointerMovesAndScrollsAreInjected() {
    let fixture = Fixture()
    let move = KVMEvent.mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5))
    let scroll = KVMEvent.scroll(deltaX: -1, deltaY: 2)
    fixture.feed([enter, move, scroll])
    #expect(fixture.platform.injected == [move, scroll])
    #expect(fixture.coordinator.diagnostics.injected == 2)
  }

  // MARK: Leave

  @Test func leaveReleasesInPlanOrderThenResetsAndBecomesInactive() {
    let fixture = Fixture()
    fixture.feed([
      enter, down(.shift), down(.letter(1), shifted), press(.left), down(.letter(2), shifted),
      press(.right),
    ])
    let before = fixture.platform.effects.count
    #expect(fixture.coordinator.handle(leave) == .accepted)
    let after = Array(fixture.platform.effects.dropFirst(before))
    #expect(
      after == [
        .inject(up(.letter(2), shifted)), .inject(up(.letter(1), shifted)),
        .inject(release(.right)), .inject(release(.left)), .inject(up(.shift)), .inactive,
      ])
    #expect(fixture.platform.held.isEmpty)
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.ledgerSnapshot.heldKeyCount == 0)
    #expect(fixture.coordinator.diagnostics.leaveReleases == 5)
    // Input after the leave is dropped until the next enter.
    #expect(fixture.coordinator.handle(down(.letter(1))) == .dropped)
  }

  @Test func leaveForAnotherScreenChangesNothing() {
    let fixture = Fixture()
    fixture.feed([enter, down(.letter(1))])
    #expect(fixture.coordinator.handle(.leaveScreen(screen: otherScreen)) == .dropped)
    #expect(fixture.coordinator.state == .active)
    #expect(fixture.coordinator.ledgerSnapshot.heldKeyCount == 1)
  }

  @Test func failedLeaveReleaseFailsClosedAndCleanupReleases() async {
    let fixture = Fixture()
    fixture.platform.sweepEnabled = false
    fixture.feed([enter, down(.letter(1)), down(.letter(2))])
    fixture.platform.failInjects(after: 1)
    #expect(fixture.coordinator.handle(leave) == .failedClosed)
    #expect(fixture.coordinator.ledgerSnapshot.heldKeyCount == 2)
    let outcome = await fixture.coordinator.terminate(ClientCoordinator.injectionFailureTrigger)
    await expectSafeAfterTerminal(fixture, outcome)
  }

  // MARK: Clipboard

  @Test func inboundClipboardPassesTheLoopGuardBeforeItIsApplied() {
    let fixture = Fixture()
    let first = inbound("one", hash: "h1", id: 1)
    #expect(fixture.coordinator.handle(.clipboard(first)) == .accepted)
    #expect(fixture.coordinator.handle(.clipboard(first)) == .dropped)
    #expect(fixture.coordinator.handle(.clipboard(inbound("one", hash: "h1", id: 2))) == .dropped)
    #expect(fixture.platform.effects == [.clipboard(first)])
    #expect(fixture.coordinator.diagnostics.inboundClipboardApplied == 1)
    #expect(fixture.coordinator.diagnostics.inboundClipboardLoopRejected == 2)
  }

  @Test func oversizedInboundClipboardIsRejected() {
    let fixture = Fixture()
    let big = inbound(String(repeating: "x", count: 65), hash: "big", id: 3)
    #expect(fixture.coordinator.handle(.clipboard(big)) == .dropped)
    #expect(fixture.platform.effects.isEmpty)
    #expect(fixture.coordinator.diagnostics.inboundClipboardOversized == 1)
  }

  @Test func clipboardApplyFailureIsCountedAndTheSessionGoesOn() {
    let fixture = Fixture()
    fixture.platform.failClipboard()
    #expect(fixture.coordinator.handle(.clipboard(inbound("a", hash: "a", id: 4))) == .dropped)
    #expect(fixture.coordinator.diagnostics.clipboardApplyFailures == 1)
    #expect(fixture.coordinator.handle(enter) == .accepted)
  }

  @Test func localClipboardEchoOfAppliedPayloadIsRejected() {
    let fixture = Fixture()
    fixture.feed([enter, .clipboard(inbound("one", hash: "h1", id: 5))])
    #expect(fixture.coordinator.localClipboardChanged(outbound("one", hash: "h1", id: 5)) == nil)
    let fresh = outbound("two", hash: "h2", id: 6)
    #expect(fixture.coordinator.localClipboardChanged(fresh) == fresh)
    #expect(fixture.coordinator.localClipboardChanged(fresh) == nil)
    let diagnostics = fixture.coordinator.diagnostics
    #expect(diagnostics.outboundClipboardAdmitted == 1)
    #expect(diagnostics.outboundClipboardLoopRejected == 2)
  }

  @Test func localClipboardWhileInactiveIsNotSent() {
    let fixture = Fixture()
    #expect(fixture.coordinator.localClipboardChanged(outbound("a", hash: "a", id: 7)) == nil)
    #expect(fixture.coordinator.diagnostics.outboundClipboardWhileInactive == 1)
  }

  // MARK: Injection failure

  @Test func injectFailureFailsClosed() {
    let fixture = Fixture()
    fixture.platform.failInjects(after: 0)
    #expect(fixture.coordinator.handle(enter) == .accepted)
    #expect(fixture.coordinator.handle(down(.letter(1))) == .failedClosed)
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.handle(enter) == .dropped)
    #expect(fixture.coordinator.diagnostics.injectFailures == 1)
    #expect(fixture.coordinator.diagnostics.droppedAfterClose == 1)
  }

  @Test func runTerminatesWithTheInjectionFailureTrigger() async {
    let fixture = Fixture([enter, down(.letter(1)), press(.left), down(.letter(2)), up(.letter(1))])
    fixture.platform.sweepEnabled = false
    fixture.platform.failInjects(after: 2)
    let outcome = await fixture.coordinator.run(fixture.session.events)
    #expect(
      fixture.session.disconnects
        == [CleanupHooks.disconnectReason(for: ClientCoordinator.injectionFailureTrigger)])
    await expectSafeAfterTerminal(fixture, outcome)
  }

  // MARK: Terminal paths

  private static let heldScript: [KVMEvent] = [
    enter, down(.shift), down(.letter(1), shifted), press(.left), repeated(.letter(1)),
  ]

  @Test func streamEndReleasesEverything() async {
    let fixture = Fixture(Self.heldScript, end: .finish)
    fixture.platform.sweepEnabled = false
    let outcome = await fixture.coordinator.run(fixture.session.events)
    #expect(fixture.session.disconnects == [.transportClosed])
    await expectSafeAfterTerminal(fixture, outcome)
  }

  @Test(
    arguments: [
      (failure(.transport(.reset)), DisconnectReason.failure(failure(.transport(.reset)))),
      (
        failure(.protocolViolation(.malformed)),
        DisconnectReason.failure(failure(.protocolViolation(.malformed)))
      ),
      (
        failure(.timeout(.keepalive)),
        CleanupHooks.disconnectReason(for: .keepaliveTimeout)
      ),
    ])
  func streamErrorReleasesEverything(error: CoreError, expected: DisconnectReason) async {
    let fixture = Fixture(Self.heldScript, end: .fail(error))
    fixture.platform.sweepEnabled = false
    let outcome = await fixture.coordinator.run(fixture.session.events)
    #expect(fixture.session.disconnects == [expected])
    await expectSafeAfterTerminal(fixture, outcome)
  }

  @Test(arguments: [
    CleanupTrigger.cancelled, .termination, .keepaliveTimeout,
    .transportFailure(failure(.transport(.refused))),
    .protocolViolation(failure(.protocolViolation(.unsupportedMessage))),
    .streamEnded(.transportClosed), .sleep, .displayLost,
  ])
  func terminateReleasesEverything(trigger: CleanupTrigger) async {
    let fixture = Fixture()
    fixture.platform.sweepEnabled = false
    fixture.feed(Self.heldScript)
    #expect(!fixture.platform.held.isEmpty)
    let outcome = await fixture.coordinator.terminate(trigger)
    #expect(fixture.session.disconnects == [CleanupHooks.disconnectReason(for: trigger)])
    await expectSafeAfterTerminal(fixture, outcome)
  }

  @Test func cancelledRunTerminatesAsCancelled() async {
    let fixture = Fixture(Self.heldScript, end: .open)
    fixture.platform.sweepEnabled = false
    let coordinator = fixture.coordinator
    let events = fixture.session.events
    let task = Task { await coordinator.run(events) }
    var spins = 0
    while fixture.platform.injected.count < 3, spins < 100_000 {
      spins += 1
      await Task.yield()
    }
    task.cancel()
    let outcome = await task.value
    #expect(fixture.session.disconnects == [.cancellation(.superseded)])
    await expectSafeAfterTerminal(fixture, outcome)
  }

  @Test func sweepReleasesWhatTheQueueResetDropped() async {
    let fixture = Fixture()
    fixture.platform.queued = true
    fixture.feed([enter, down(.letter(1)), press(.left)])
    fixture.platform.drain()
    // The leave's releases sit in the queue; the terminal path resets it before they run.
    fixture.feed([leave])
    #expect(fixture.coordinator.releasePlan().steps.isEmpty)
    let outcome = await fixture.coordinator.terminate(.termination)
    await expectSafeAfterTerminal(fixture, outcome)
  }

  @Test func concurrentTerminatesRunOneCleanup() async {
    let fixture = Fixture()
    fixture.feed(Self.heldScript)
    let coordinator = fixture.coordinator
    async let first = coordinator.terminate(.termination)
    async let second = coordinator.terminate(.cancelled)
    let outcomes = await [first, second]
    #expect(outcomes.filter(\.ran).count == 1)
    #expect(fixture.platform.clearCount == 1)
    #expect(fixture.platform.held.isEmpty)
  }

  // MARK: Generations

  @Test func newGenerationStartsOnlyAfterTheOldCleanup() async {
    let fixture = Fixture()
    fixture.platform.sweepEnabled = false
    fixture.feed(Self.heldScript)
    #expect(!fixture.coordinator.beginSession())
    let outcome = await fixture.coordinator.terminate(.cancelled)
    #expect(outcome.ran)
    #expect(fixture.platform.held.isEmpty)
    fixture.platform.reopen()
    #expect(fixture.coordinator.beginSession())
    #expect(fixture.coordinator.state == .inactive)
    #expect(fixture.coordinator.handle(enter) == .accepted)
    #expect(fixture.coordinator.handle(down(.letter(4))) == .accepted)
    #expect(fixture.platform.held == [.key(String(describing: VirtualKey.letter(4)))])
    let second = await fixture.coordinator.terminate(.termination)
    #expect(second.ran)
    #expect(fixture.platform.held.isEmpty)
    #expect(fixture.coordinator.diagnostics.cleanupsRun == 2)
    #expect(fixture.coordinator.diagnostics.sessions == 2)
  }

  @Test func oldGenerationStreamCannotInjectIntoTheNewSession() async {
    let fixture = Fixture()
    let coordinator = fixture.coordinator
    let (oldEvents, oldFeed) = AsyncThrowingStream.makeStream(of: KVMEvent.self)
    let oldRun = Task { await coordinator.run(oldEvents) }
    oldFeed.yield(enter)
    var spins = 0
    while fixture.platform.effects.isEmpty, spins < 100_000 {
      spins += 1
      await Task.yield()
    }
    let cleanup = await coordinator.terminate(.cancelled)
    #expect(cleanup.ran)
    fixture.platform.reopen()
    #expect(coordinator.beginSession())
    // A late event of the old stream arrives after the new generation opened.
    oldFeed.yield(down(.letter(1)))
    oldFeed.finish()
    let oldOutcome = await oldRun.value
    #expect(!oldOutcome.ran)
    #expect(fixture.platform.injected.isEmpty)
    #expect(coordinator.state == .inactive)
    #expect(coordinator.diagnostics.droppedAfterClose == 1)
    #expect(coordinator.diagnostics.cleanupsRun == 1)
  }

  @Test func beginSessionWaitsForAnInFlightCleanup() async {
    let fixture = Fixture()
    let gate = DispatchSemaphore(value: 0)
    fixture.platform.sweepGate = gate
    fixture.feed(Self.heldScript)
    let coordinator = fixture.coordinator
    let cleanup = Task { await coordinator.terminate(.cancelled) }
    // Wait (off the cooperative pool) until the cleanup is inside the injector sweep.
    let entered = fixture.platform.sweepEntered
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      Thread {
        entered.wait()
        continuation.resume()
      }.start()
    }
    let late = await coordinator.terminate(.termination)
    #expect(!late.ran)
    #expect(!coordinator.beginSession(), "a session began during the old cleanup")
    gate.signal()
    let outcome = await cleanup.value
    #expect(outcome.ran)
    #expect(fixture.platform.held.isEmpty)
    fixture.platform.reopen()
    #expect(coordinator.beginSession())
  }

  @Test func runStopsReadingOnceItsGenerationIsClosed() async {
    let fixture = Fixture()
    let coordinator = fixture.coordinator
    let (events, feed) = AsyncThrowingStream.makeStream(of: KVMEvent.self)
    let finished = Flag()
    let running = Task {
      let outcome = await coordinator.run(events)
      finished.set()
      return outcome
    }
    feed.yield(enter)
    var spins = 0
    while fixture.platform.effects.isEmpty, spins < 100_000 {
      spins += 1
      await Task.yield()
    }
    let cleanup = await coordinator.terminate(.termination)
    #expect(cleanup.ran)
    // One more event of the closed generation; the stream itself stays open.
    feed.yield(down(.letter(1)))
    spins = 0
    while !finished.value, spins < 200_000 {
      spins += 1
      await Task.yield()
    }
    #expect(finished.value, "run kept reading a closed generation's stream")
    feed.finish()
    let outcome = await running.value
    #expect(!outcome.ran)
    #expect(fixture.platform.injected.isEmpty)
  }

  // MARK: Diagnostics

  @Test func diagnosticsHoldNoIdentifiers() {
    let fixture = Fixture()
    fixture.feed([
      enter, down(.letter(1), shifted), press(.left), repeated(.letter(9)),
      .clipboard(inbound("secret", hash: "hash-secret", id: 8)), leave,
    ])
    _ = fixture.coordinator.localClipboardChanged(outbound("secret", hash: "hash-secret", id: 9))
    expectNoIdentifiers(fixture.coordinator.diagnostics)
  }

  // MARK: Property

  @Test func randomStreamsCutAtRandomPointsKeepTheInvariants() async {
    var generator = SplitMix64(seed: 0x6301)
    for _ in 0..<300 {
      let count = Int(generator.next() % 40)
      var script: [KVMEvent] = []
      for _ in 0..<count { script.append(Self.randomEvent(&generator)) }
      let endChoice = generator.next() % 5
      let end: ScriptedSession.End
      switch endChoice {
      case 0: end = .fail(failure(.transport(.reset)))
      case 1: end = .fail(failure(.protocolViolation(.malformed)))
      case 2: end = .fail(failure(.timeout(.keepalive)))
      default: end = .finish
      }
      let fixture = Fixture(script, end: end)
      // Without the sweep the ledger's plan alone must release everything. A failed inject of a
      // release leaves the platform holding a key the ledger already freed; only the injector
      // sweep (plan h.1) covers that, so injection failures always run with the sweep.
      let sweepOff = generator.next() % 2 == 0
      if !sweepOff, generator.next() % 2 == 0 {
        fixture.platform.failInjects(after: Int(generator.next() % 10))
      }
      fixture.platform.sweepEnabled = !sweepOff
      let outcome: CleanupOutcome
      if endChoice == 4 {
        // Cut mid-stream by an external terminal trigger.
        let cut = Int(generator.next() % UInt64(count + 1))
        fixture.feed(Array(script.prefix(cut)))
        let triggers: [CleanupTrigger] = [.cancelled, .termination, .keepaliveTimeout, .sleep]
        outcome = await fixture.coordinator.terminate(
          triggers[Int(generator.next() % UInt64(triggers.count))])
      } else {
        outcome = await fixture.coordinator.run(fixture.session.events)
      }
      await expectSafeAfterTerminal(fixture, outcome)
    }
  }

  private static func randomEvent(_ generator: inout SplitMix64) -> KVMEvent {
    let keys: [VirtualKey] = [.letter(1), .letter(2), .shift, .control, .capsLock, .space]
    let buttons: [MouseButton] = [.left, .right, .middle]
    let key = keys[Int(generator.next() % UInt64(keys.count))]
    let button = buttons[Int(generator.next() % UInt64(buttons.count))]
    switch generator.next() % 10 {
    case 0: return enter
    case 1: return leave
    case 2: return down(key)
    case 3: return up(key)
    case 4: return repeated(key)
    case 5: return press(button)
    case 6: return release(button)
    case 7: return .mouseMove(position: origin)
    case 8: return .scroll(deltaX: 0, deltaY: 1)
    default:
      let id = UInt8(generator.next() % 4)
      return .clipboard(inbound("c", hash: "h\(id)", id: id))
    }
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var raised = false
  var value: Bool { lock.withLock { raised } }
  func set() { lock.withLock { raised = true } }
}

private struct SplitMix64 {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

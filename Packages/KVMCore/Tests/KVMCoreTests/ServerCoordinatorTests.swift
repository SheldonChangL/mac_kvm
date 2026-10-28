import Foundation
import KVMContracts
import KVMCore
import Testing

private func screen(_ value: UInt8) -> ScreenID {
  ScreenID(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20, value)))
}

private let mac = screen(1)
private let linux = screen(2)
private let localSize = EdgeDetector.ScreenSize(width: 1001, height: 501)
private let noModifiers = ModifierState()

/// Everything the coordinator asked the platform to do, in order.
private enum Call: Equatable {
  case saveCursor
  case enableSuppression
  case disableSuppression
  case restoreCursor(NormalizedPoint)
  case recoverLocal(cursorWasParked: Bool)
  case deliver(KVMEvent, ScreenID)
  case startTimeout(ScreenID)
  case cancelTimeout(ScreenID)
}

private final class FakeEffects: ServerCoordinatorEffects, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Call] = []
  private var deliveryAccepted = true

  var calls: [Call] { lock.withLock { recorded } }
  var deliveries: [KVMEvent] {
    calls.compactMap { if case .deliver(let event, _) = $0 { event } else { nil } }
  }

  func reset() { lock.withLock { recorded = [] } }
  func acceptDeliveries(_ accepted: Bool) { lock.withLock { deliveryAccepted = accepted } }

  private func record(_ call: Call) { lock.withLock { recorded.append(call) } }

  func saveLocalCursor() { record(.saveCursor) }
  func enableSuppression() { record(.enableSuppression) }
  func disableSuppression() { record(.disableSuppression) }
  func restoreLocalCursor(at position: NormalizedPoint) { record(.restoreCursor(position)) }
  func recoverLocal(cursorWasParked: Bool) {
    record(.recoverLocal(cursorWasParked: cursorWasParked))
  }
  func deliver(_ event: KVMEvent, to screen: ScreenID) -> Bool {
    record(.deliver(event, screen))
    return lock.withLock { deliveryAccepted }
  }
  func startEnterTimeout(for screen: ScreenID) { record(.startTimeout(screen)) }
  func cancelEnterTimeout(for screen: ScreenID) { record(.cancelTimeout(screen)) }
}

private func makeCoordinator(
  canForward: @escaping @Sendable (KVMEvent) -> Bool = { _ in true }
) throws -> (ServerCoordinator, FakeEffects) {
  let effects = FakeEffects()
  let edgeDetection = try #require(
    EdgeDetector.Configuration(activationDelay: .milliseconds(50), cornerDeadZone: 20))
  let configuration = try #require(
    ServerCoordinatorConfiguration(
      localScreen: mac, localSize: localSize,
      links: [ScreenLink(from: mac, edge: .right, to: linux)], edgeDetection: edgeDetection,
      entryInset: 1, reentryInset: 2))
  let coordinator = try #require(
    ServerCoordinator(configuration: configuration, effects: effects, canForward: canForward))
  return (coordinator, effects)
}

private let rightEdge = KVMEvent.mouseMove(position: NormalizedPoint(x: 1, y: 0.5))
private let entry = NormalizedPoint(x: 1.0 / 1920, y: 0.5)

private func key(_ key: VirtualKey, _ phase: KeyPhase) -> KVMEvent {
  .key(key: key, phase: phase, modifiers: noModifiers)
}

/// Dwells on the linked edge until the enter is requested.
private func requestEnter(_ coordinator: ServerCoordinator) {
  coordinator.clientReady(linux, width: 1921, height: 1081)
  coordinator.observeLocal(rightEdge, at: .zero)
  coordinator.observeLocal(rightEdge, at: .milliseconds(50))
}

/// Requests the enter and commits it.
private func enterRemote(_ coordinator: ServerCoordinator, _ effects: FakeEffects) {
  requestEnter(coordinator)
  coordinator.enterCompleted(linux, success: true)
  effects.reset()
}

/// The local point the cursor returns to after leaving the client at `y`.
private func returnPoint(remoteY: Int) throws -> NormalizedPoint {
  let mapper = try #require(
    ReturnCoordinateMapper(
      localSize: ReturnCoordinateMapper.LogicalSize(width: 1001, height: 501), reentryInset: 2,
      cornerDeadZone: 20))
  return mapper.normalized(
    mapper.reentryPoint(leftThrough: .right, offset: Double(remoteY) / 1080))
}

@Suite("M2 ServerCoordinator")
struct ServerCoordinatorTests {
  @Test("a dwell on the linked edge sends the enter, and the delivered enter commits remote")
  func enter() throws {
    let (coordinator, effects) = try makeCoordinator()
    coordinator.clientReady(linux, width: 1921, height: 1081)
    coordinator.observeLocal(rightEdge, at: .zero)
    #expect(coordinator.state == .local)
    #expect(effects.calls.isEmpty)

    coordinator.observeLocal(rightEdge, at: .milliseconds(50))
    #expect(coordinator.state == .enteringRemote(linux))
    #expect(
      effects.calls == [
        .saveCursor, .deliver(.enterScreen(screen: linux, position: entry), linux),
        .startTimeout(linux),
      ])

    effects.reset()
    coordinator.enterCompleted(linux, success: true)
    #expect(coordinator.state == .remote(linux))
    #expect(effects.calls == [.cancelTimeout(linux), .enableSuppression])
  }

  @Test("a tick completes a dwell when the pointer rests on the edge")
  func tickCompletesDwell() throws {
    let (coordinator, effects) = try makeCoordinator()
    coordinator.clientReady(linux, width: 1921, height: 1081)
    coordinator.observeLocal(rightEdge, at: .zero)
    coordinator.tick(at: .milliseconds(20))
    #expect(coordinator.state == .local)
    coordinator.tick(at: .milliseconds(50))
    #expect(coordinator.state == .enteringRemote(linux))
    #expect(effects.calls.first == .saveCursor)
  }

  @Test("no client, a held key or a held button keeps input local; Caps Lock does not")
  func enterPreconditions() throws {
    let (alone, aloneEffects) = try makeCoordinator()
    alone.observeLocal(rightEdge, at: .zero)
    alone.observeLocal(rightEdge, at: .milliseconds(80))
    #expect(alone.state == .local)
    #expect(aloneEffects.calls.isEmpty)

    let (holding, holdingEffects) = try makeCoordinator()
    holding.observeLocal(key(.letter(0), .down), at: .zero)
    requestEnter(holding)
    #expect(holding.state == .local)
    #expect(holdingEffects.calls.isEmpty)

    let (clicking, _) = try makeCoordinator()
    clicking.observeLocal(.mouseButton(button: .left, phase: .down), at: .zero)
    requestEnter(clicking)
    #expect(clicking.state == .local)

    let (capsLocked, _) = try makeCoordinator()
    capsLocked.observeLocal(key(.capsLock, .down), at: .zero)
    requestEnter(capsLocked)
    #expect(capsLocked.state == .enteringRemote(linux))
  }

  @Test("remote motion moves the client pointer from the entry point, splitting large deltas")
  func remoteMotion() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)

    #expect(coordinator.moveRemote(deltaX: 10, deltaY: 5))
    #expect(
      effects.calls == [
        .deliver(.mouseMove(position: NormalizedPoint(x: 11.0 / 1920, y: 545.0 / 1080)), linux)
      ])

    effects.reset()
    #expect(coordinator.moveRemote(deltaX: 900, deltaY: 0))
    #expect(
      effects.deliveries == [
        .mouseMove(position: NormalizedPoint(x: 911.0 / 1920, y: 545.0 / 1080))
      ])
  }

  @Test("pushing back past the arrival edge releases held input, leaves and restores the cursor")
  func returnEdge() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)
    #expect(coordinator.handleSuppressed(key(.letter(0), .down)) == .swallow)
    #expect(coordinator.handleSuppressed(.mouseButton(button: .right, phase: .down)) == .swallow)
    #expect(coordinator.handleSuppressed(key(.capsLock, .down)) == .swallow)
    effects.reset()

    #expect(coordinator.moveRemote(deltaX: -20, deltaY: 0))
    #expect(coordinator.state == .leavingRemote(linux))
    #expect(
      effects.calls == [
        .disableSuppression,
        .deliver(key(.letter(0), .up), linux),
        .deliver(.mouseButton(button: .right, phase: .up), linux),
        .deliver(.leaveScreen(screen: linux), linux),
        .restoreCursor(try returnPoint(remoteY: 540)),
      ])

    effects.reset()
    coordinator.leaveCompleted(linux)
    #expect(coordinator.state == .local)
    #expect(effects.calls.isEmpty)
    #expect(!coordinator.moveRemote(deltaX: 5, deltaY: 0))
  }

  @Test("the emergency escape recovers locally at once and leaves on a best-effort basis")
  func emergencyEscape() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)
    _ = coordinator.handleSuppressed(key(.control, .down))
    effects.reset()

    coordinator.dispatch(.emergencyEscape)
    #expect(coordinator.state == .local)
    #expect(
      effects.calls == [
        .disableSuppression,
        .deliver(key(.control, .up), linux),
        .deliver(.leaveScreen(screen: linux), linux),
        .recoverLocal(cursorWasParked: true),
      ])

    effects.reset()
    coordinator.dispatch(.emergencyEscape)
    #expect(effects.calls == [.recoverLocal(cursorWasParked: false)])
  }

  @Test("losing the client while remote recovers locally without sending")
  func clientGone() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)

    coordinator.clientGone(linux)
    #expect(coordinator.state == .local)
    #expect(effects.calls == [.disableSuppression, .recoverLocal(cursorWasParked: true)])

    effects.reset()
    #expect(coordinator.handleSuppressed(key(.letter(2), .down)) == .passLocally)
    coordinator.observeLocal(rightEdge, at: .seconds(1))
    coordinator.observeLocal(rightEdge, at: .seconds(2))
    #expect(effects.calls.isEmpty)
  }

  @Test("an enter that times out or cannot be queued rolls back to local")
  func enterRollback() throws {
    let (timedOut, timedOutEffects) = try makeCoordinator()
    requestEnter(timedOut)
    timedOutEffects.reset()
    timedOut.enterTimedOut(linux)
    #expect(timedOut.state == .local)
    #expect(
      timedOutEffects.calls == [
        .cancelTimeout(linux), .deliver(.leaveScreen(screen: linux), linux),
        .recoverLocal(cursorWasParked: false),
      ])
    timedOut.enterCompleted(linux, success: true)
    #expect(timedOut.state == .local)

    let (unqueued, unqueuedEffects) = try makeCoordinator()
    unqueuedEffects.acceptDeliveries(false)
    requestEnter(unqueued)
    #expect(unqueued.state == .local)
    #expect(unqueuedEffects.calls.last == .recoverLocal(cursorWasParked: false))
  }

  @Test("a forward that cannot be queued fails open to local")
  func forwardOverflowFailsOpen() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)
    effects.acceptDeliveries(false)

    #expect(coordinator.handleSuppressed(key(.letter(3), .down)) == .swallow)
    #expect(coordinator.state == .local)
    #expect(effects.calls.first == .deliver(key(.letter(3), .down), linux))
    #expect(effects.calls.contains(.disableSuppression))
    #expect(effects.calls.last == .recoverLocal(cursorWasParked: true))
  }

  @Test("a leave that cannot be queued still completes locally")
  func unqueuedLeaveCompletes() throws {
    let (coordinator, effects) = try makeCoordinator()
    enterRemote(coordinator, effects)
    effects.acceptDeliveries(false)

    #expect(coordinator.moveRemote(deltaX: -20, deltaY: 0))
    #expect(coordinator.state == .local)
  }

  @Test("input the client cannot receive is swallowed while remote and never delivered")
  func unsupportedInputIsDropped() throws {
    let (coordinator, effects) = try makeCoordinator(canForward: { event in
      if case .key(.unknown, _, _) = event { return false }
      return true
    })
    enterRemote(coordinator, effects)

    #expect(coordinator.handleSuppressed(key(.unknown(42), .down)) == .swallow)
    #expect(effects.calls.isEmpty)
  }

  @Test("an up or repeat whose down went to the local system goes back to it")
  func upFollowsDown() throws {
    let (coordinator, effects) = try makeCoordinator()
    requestEnter(coordinator)
    coordinator.observeLocal(key(.letter(1), .down), at: .milliseconds(60))
    coordinator.observeLocal(.mouseButton(button: .left, phase: .down), at: .milliseconds(61))
    coordinator.enterCompleted(linux, success: true)
    effects.reset()

    #expect(coordinator.handleSuppressed(key(.letter(1), .repeatKey)) == .passLocally)
    #expect(coordinator.handleSuppressed(key(.letter(1), .up)) == .passLocally)
    #expect(coordinator.handleSuppressed(.mouseButton(button: .left, phase: .up)) == .passLocally)
    #expect(coordinator.handleSuppressed(key(.letter(1), .down)) == .swallow)
    #expect(effects.deliveries == [key(.letter(1), .down)])
  }
}

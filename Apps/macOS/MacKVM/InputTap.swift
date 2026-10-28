import CoreGraphics
import KVMContracts
import KVMCore
import MacPlatform

/// The event tap handler (M2-001: classify, hand off, never wait).
///
/// The suppressor decides first, so the emergency chord and a disabled tap are
/// handled before anything else. Swallowed pointer motion becomes a relative
/// delta for the coordinator and the cursor is parked again; other swallowed
/// input is routed by the coordinator, which may give it back to the local
/// system.
final class InputTap: @unchecked Sendable {
  private let coordinator: ServerCoordinator
  private let effects: MacServerEffects
  private let suppressor: LocalEventSuppressor
  private let mouse: MacMouseCapture
  private var lifecycle: EventTapLifecycle?
  private var onFailure: (@Sendable (String) -> Void)?

  init(
    coordinator: ServerCoordinator, effects: MacServerEffects, suppressor: LocalEventSuppressor,
    mouse: MacMouseCapture
  ) {
    self.coordinator = coordinator
    self.effects = effects
    self.suppressor = suppressor
    self.mouse = mouse
  }

  /// Set once before the tap is installed; only the tap callback reads them.
  func attach(
    _ lifecycle: EventTapLifecycle, onFailure: @escaping @Sendable (String) -> Void
  ) {
    self.lifecycle = lifecycle
    self.onFailure = onFailure
  }

  func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
    switch suppressor.decide(type: type, event: event) {
    case .failOpen:
      coordinator.dispatch(.captureFailure)
      if lifecycle?.handleSystemDisable() == .gaveUp {
        onFailure?("the event tap kept being disabled")
      } else {
        report("the system disabled the event tap; input is local, tap re-enabled")
      }
      return event
    case .emergencyEscape:
      // The suppressor has already stopped suppressing for any phase of the
      // chord key, so every phase must return input to local, or a chord
      // completed by a release or a repeat would leave the state remote.
      let wasLocal = coordinator.state == .local
      coordinator.dispatch(LeaveRemoteFlow.escapeAction)
      if !wasLocal { report("emergency escape: input is local") }
      return event
    case .passThrough:
      observeLocal(type, event)
      return event
    case .suppress:
      if Self.isPointerMotion(type) {
        let moved = coordinator.moveRemote(
          deltaX: event.getDoubleValueField(.mouseEventDeltaX),
          deltaY: event.getDoubleValueField(.mouseEventDeltaY))
        if moved {
          effects.repark()
          return nil
        }
        observeLocal(type, event)
        return event
      }
      guard let captured = map(type, event) else { return event }
      switch coordinator.handleSuppressed(captured) {
      case .swallow:
        return nil
      case .passLocally:
        coordinator.observeLocal(captured, at: uptime())
        return event
      }
    }
  }

  private func observeLocal(_ type: CGEventType, _ event: CGEvent) {
    if let captured = map(type, event) { coordinator.observeLocal(captured, at: uptime()) }
  }

  private func map(_ type: CGEventType, _ event: CGEvent) -> KVMEvent? {
    switch type {
    case .keyDown, .keyUp, .flagsChanged: MacKeyboardCapture.map(event)?.event
    default: mouse.map(event)?.event
    }
  }

  private static func isPointerMotion(_ type: CGEventType) -> Bool {
    switch type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: true
    default: false
    }
  }
}

/// The event tap as the M2-007 lifecycle sees it.
struct MacEventTapControl: EventTapControl {
  let tap: MacEventTap

  func install() throws(CoreError) { try tap.install() }
  func reenable() { tap.reenable() }
  func remove() { tap.remove() }
}

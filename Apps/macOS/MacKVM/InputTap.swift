import AppKit
import CoreGraphics
import KVMContracts
import KVMCore
import MacPlatform

/// The event tap handler (M2-001: classify, hand off, never wait).
///
/// The suppressor decides first, so the emergency chord and a disabled tap are
/// handled before anything else. Swallowed pointer motion becomes a relative
/// delta for the coordinator; other swallowed input is routed by the
/// coordinator, which may give it back to the local system.
final class InputTap: @unchecked Sendable {
  private let coordinator: ServerCoordinator
  private let suppressor: LocalEventSuppressor
  private let mouse: MacMouseCapture
  private var lifecycle: EventTapLifecycle?
  private var onFailure: (@Sendable (String) -> Void)?

  init(coordinator: ServerCoordinator, suppressor: LocalEventSuppressor, mouse: MacMouseCapture) {
    self.coordinator = coordinator
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
      // completed by a release or a repeat would leave the state remote. On
      // the owner's Mac only the release of Delete reaches the tap.
      let wasLocal = coordinator.state == .local
      coordinator.dispatch(LeaveRemoteFlow.escapeAction)
      if !wasLocal { report("emergency escape: input is local") }
      return event
    case .discard:
      return nil
    case .passThrough:
      if anchor != nil { resetDiagnostics() }
      observeLocal(type, event)
      return event
    case .suppress:
      if Self.isPointerMotion(type) {
        let moved = coordinator.moveRemote(
          deltaX: event.getDoubleValueField(.mouseEventDeltaX),
          deltaY: event.getDoubleValueField(.mouseEventDeltaY))
        if moved {
          checkCursorVisibility()
          return nil
        }
        // DIAG(remote-leak): suppressed motion handed back to the local system.
        leakCount &+= 1
        if leakCount <= 5 || leakCount % 100 == 0 {
          report(
            "DIAG motion passed locally while suppressing (moveRemote=false, state=\(coordinator.state), count=\(leakCount), dx=\(event.getDoubleValueField(.mouseEventDeltaX)), dy=\(event.getDoubleValueField(.mouseEventDeltaY)))"
          )
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

  // DIAG(remote-leak): counters touched only on the tap callback thread.
  private var leakCount = 0
  private var motionCount = 0
  private var anchor: CGPoint?
  private var anchorDriftLogged = false
  private var lastFront = ""

  /// Logs when the local logical cursor drifts while input is remote, and the
  /// frontmost app at that moment (an app switch can show the hidden cursor).
  private func checkCursorVisibility() {
    motionCount &+= 1
    guard motionCount % 20 == 0 else { return }
    let point = CGEvent(source: nil)?.location ?? .zero
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    if front != lastFront {
      if !lastFront.isEmpty {
        report("DIAG frontmost app changed while remote: \(lastFront) -> \(front)")
      }
      lastFront = front
    }
    guard let anchor else {
      self.anchor = point
      return
    }
    let drift = hypot(point.x - anchor.x, point.y - anchor.y)
    if drift > 3, !anchorDriftLogged {
      anchorDriftLogged = true
      report(
        "DIAG local cursor moved while remote: \(Int(anchor.x)),\(Int(anchor.y)) -> \(Int(point.x)),\(Int(point.y)) (frontmost=\(front))"
      )
    }
  }

  /// Called when input returns local so the next remote stint gets a new anchor.
  func resetDiagnostics() {
    anchor = nil
    anchorDriftLogged = false
    lastFront = ""
    motionCount = 0
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

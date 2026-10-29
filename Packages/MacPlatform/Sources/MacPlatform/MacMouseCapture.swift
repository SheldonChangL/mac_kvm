import CoreGraphics
import KVMContracts

/// One captured pointer event in platform-neutral form plus its source
/// timestamp, so the owner can preserve order and timing.
package struct MacCapturedInput: Equatable, Sendable {
  package let event: KVMEvent
  /// The `CGEvent` timestamp (nanoseconds since system start).
  package let timestamp: UInt64
}

/// Maps physical mouse `CGEvent`s from the server event tap to `KVMEvent`
/// (M2-004).
///
/// The mapper is a pure value: it performs no I/O, never awaits, never logs and
/// holds no resource, so it is safe to call inside an event-tap callback.
/// Positions are normalized over the capture bounds in global logical points
/// using `(size - 1)` denominators, so the extreme edge pixels map to exactly
/// `0` and `1`. Scroll uses macOS line deltas: positive `deltaY` is the
/// vertical wheel's positive direction and `deltaX` the horizontal wheel's.
/// Unsupported buttons and zero scrolls map to `nil` and must pass through
/// untouched.
package struct MacMouseCapture: Sendable {
  package let bounds: CGRect

  /// Returns `nil` for non-finite bounds or bounds smaller than 2×2 points.
  package init?(bounds: CGRect) {
    guard bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite,
      bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2
    else { return nil }
    self.bounds = bounds
  }

  package func map(_ event: CGEvent) -> MacCapturedInput? {
    guard let mapped = mapEvent(event) else { return nil }
    return MacCapturedInput(event: mapped, timestamp: event.timestamp)
  }

  /// Whether `map` produces an event for `event`, whatever the bounds.
  ///
  /// The local suppressor swallows a pointer event only when this is true
  /// (M2-013), so input that cannot be forwarded always reaches the Mac.
  package static func canMap(_ event: CGEvent) -> Bool {
    switch event.type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
      return true
    case .otherMouseDown, .otherMouseUp:
      return otherButton(event) != nil
    case .scrollWheel:
      return scrollDeltas(event) != nil
    default:
      return false
    }
  }

  private func mapEvent(_ event: CGEvent) -> KVMEvent? {
    switch event.type {
    case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
      return .mouseMove(position: normalized(event.location))
    case .leftMouseDown:
      return .mouseButton(button: .left, phase: .down)
    case .leftMouseUp:
      return .mouseButton(button: .left, phase: .up)
    case .rightMouseDown:
      return .mouseButton(button: .right, phase: .down)
    case .rightMouseUp:
      return .mouseButton(button: .right, phase: .up)
    case .otherMouseDown, .otherMouseUp:
      guard let button = Self.otherButton(event) else { return nil }
      return .mouseButton(button: button, phase: event.type == .otherMouseDown ? .down : .up)
    case .scrollWheel:
      guard let deltas = Self.scrollDeltas(event) else { return nil }
      return .scroll(deltaX: deltas.horizontal, deltaY: deltas.vertical)
    default:
      return nil
    }
  }

  /// Line deltas of a scroll, or `nil` when both are zero.
  private static func scrollDeltas(_ event: CGEvent) -> (horizontal: Int32, vertical: Int32)? {
    let vertical = int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
    let horizontal = int32(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
    guard vertical != 0 || horizontal != 0 else { return nil }
    return (horizontal, vertical)
  }

  private func normalized(_ location: CGPoint) -> NormalizedPoint {
    NormalizedPoint(
      x: (location.x - bounds.minX) / (bounds.width - 1),
      y: (location.y - bounds.minY) / (bounds.height - 1))
  }

  /// macOS button numbers: 2 is the center button; 3 is the first auxiliary.
  private static func otherButton(_ event: CGEvent) -> MouseButton? {
    switch event.getIntegerValueField(.mouseEventButtonNumber) {
    case 2: .middle
    case 3: .auxiliary
    default: nil
    }
  }

  private static func int32(_ value: Int64) -> Int32 {
    Int32(clamping: value)
  }
}

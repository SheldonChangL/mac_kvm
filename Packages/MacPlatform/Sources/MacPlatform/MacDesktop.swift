// Local desktop geometry and cursor parking for the server role. The desktop is
// the union of the active displays in global display coordinates (points, origin
// at the top-left of the main display), which is the space CGEvent locations use.
// While input is remote the cursor is parked: every swallowed motion warps it back
// so its position never drifts and motion arrives as per-event deltas (M2-019
// expects a re-anchored cursor). A warp makes the system hold back hardware
// motion briefly; re-associating mouse and cursor right after it lifts that hold.

import CoreGraphics

package enum MacDesktop {
  /// Upper bound on displays considered.
  static let maximumDisplayCount: UInt32 = 16

  /// The union of all active displays, or `nil` when none is reported.
  package static func bounds() -> CGRect? {
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(maximumDisplayCount))
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(maximumDisplayCount, &displays, &count) == .success, count > 0
    else { return nil }
    let union = displays.prefix(Int(count)).map(CGDisplayBounds).reduce(CGRect.null) {
      $0.union($1)
    }
    return union.isNull || union.isEmpty ? nil : union
  }

  /// The cursor location in global display coordinates.
  package static func cursorLocation() -> CGPoint? {
    CGEvent(source: nil)?.location
  }

  /// Moves the cursor without generating an event and re-associates mouse and
  /// cursor so following hardware motion is not held back.
  @discardableResult
  package static func warpCursor(to point: CGPoint) -> Bool {
    guard CGWarpMouseCursorPosition(point) == .success else { return false }
    return CGAssociateMouseAndMouseCursorPosition(1) == .success
  }
}

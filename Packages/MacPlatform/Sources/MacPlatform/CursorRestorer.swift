import CoreGraphics
import Foundation

/// Injectable cursor and display calls.
struct CursorEnvironment: Sendable {
  var currentLocation: @Sendable () -> CGPoint?
  var displayBounds: @Sendable () -> [CGRect]
  var warp: @Sendable (CGPoint) -> Bool
  var associateMouseAndCursor: @Sendable (Bool) -> Bool

  /// Production default using documented CoreGraphics calls.
  static let live = CursorEnvironment(
    currentLocation: { CGEvent(source: nil)?.location },
    displayBounds: {
      var count: UInt32 = 0
      guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
      var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
      guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
      return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    },
    warp: { CGWarpMouseCursorPosition($0) == .success },
    associateMouseAndCursor: { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) == .success }
  )
}

/// Where a restored cursor was placed.
package enum CursorRestoreOutcome: Equatable, Sendable {
  case restored(Source)
  case failed

  package enum Source: Equatable, Sendable {
    case preferred
    case saved
    case displayCenter
  }
}

/// Saves a safe local cursor point before switching away and restores the
/// cursor when input returns to local (M2-021).
///
/// `restore(preferred:)` always re-associates the mouse with the cursor
/// first, so a cursor frozen for remote routing can never stay frozen, then
/// warps to the first candidate that lies on a currently active display and
/// whose warp succeeds, falling through to the next candidate on failure:
/// the preferred re-entry point (M2-020), the saved point, then the center of
/// the first active display. Display hot-plug is handled by re-reading the
/// active displays on every restore. A warp alone never claims restoration:
/// if re-associating the mouse with the cursor fails, the outcome is `.failed`
/// even when a warp succeeded, so cleanup is never reported as complete while
/// the cursor may stay frozen. Every call is synchronous, idempotent and never
/// logs positions.
package final class CursorRestorer: @unchecked Sendable {
  private let environment: CursorEnvironment
  private let lock = NSLock()
  private var savedPoint: CGPoint?

  package convenience init() {
    self.init(environment: .live)
  }

  init(environment: CursorEnvironment) {
    self.environment = environment
  }

  /// Saves the current cursor location. Returns `false` and keeps the
  /// previous point when the location is unavailable or not finite.
  @discardableResult
  package func saveCurrent() -> Bool {
    guard let point = environment.currentLocation(), point.x.isFinite, point.y.isFinite else {
      return false
    }
    lock.withLock { savedPoint = point }
    return true
  }

  /// Forgets the saved point. Idempotent.
  package func clear() {
    lock.withLock { savedPoint = nil }
  }

  package func restore(preferred: CGPoint?) -> CursorRestoreOutcome {
    let associated = environment.associateMouseAndCursor(true)
    let displays = environment.displayBounds()
    let saved = lock.withLock { savedPoint }
    let candidates: [(CGPoint?, CursorRestoreOutcome.Source)] = [
      (preferred, .preferred), (saved, .saved), (displays.first.map(Self.center), .displayCenter),
    ]
    for case (let point?, let source) in candidates
    where displays.contains(where: { $0.contains(point) }) && environment.warp(point) {
      return associated ? .restored(source) : .failed
    }
    return .failed
  }

  private static func center(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
  }
}

// Local desktop geometry and cursor visibility for the server role. The desktop is
// the union of the active displays in global display coordinates (points, origin
// at the top-left of the main display), which is the space CGEvent locations use.
// While input is remote the server hides the cursor and leaves it alone: with the
// event tap at the HID level, swallowed motion never reaches the window server, so
// motion arrives only as per-event deltas and no warp (which would hold back
// hardware motion for a moment) is needed.

import CoreGraphics
import Darwin

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

  /// Lets this process hide the cursor while another app is frontmost.
  ///
  /// The window server honours `CGDisplayHideCursor` only for the frontmost
  /// app unless the connection property `SetsCursorInBackground` is set. That
  /// property is private CoreGraphics SPI; macOS KVM servers (Barrier,
  /// Synergy, Input Leap) rely on it for the same reason. It is resolved at
  /// run time, so a system without it only leaves the cursor visible.
  /// Returns whether the property was set.
  @discardableResult
  package static func allowCursorHidingInBackground() -> Bool {
    typealias DefaultConnection = @convention(c) () -> UInt32
    typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
    let handle = dlopen(nil, RTLD_NOW)
    guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
      let setSymbol = dlsym(handle, "CGSSetConnectionProperty")
    else { return false }
    let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
    let setProperty = unsafeBitCast(setSymbol, to: SetProperty.self)
    return setProperty(
      connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
  }

  /// Hides or shows the cursor. The window server keeps a hide count per
  /// process and drops it when the process exits, so a crash cannot leave the
  /// cursor hidden; callers keep their own calls balanced.
  @discardableResult
  package static func hideCursor(_ hidden: Bool) -> Bool {
    let display = CGMainDisplayID()
    return (hidden ? CGDisplayHideCursor(display) : CGDisplayShowCursor(display)) == .success
  }

}

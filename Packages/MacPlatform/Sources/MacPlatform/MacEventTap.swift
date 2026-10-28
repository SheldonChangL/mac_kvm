// The concrete CGEventTap for the server role (platform half of M2-007). It is an
// active session tap at the head of the event stream, so its handler can swallow
// input, and it runs on the main run loop. Lifecycle policy (restart budget, fail
// open) belongs to the caller; this type only creates, re-enables and removes the
// tap. The handler must classify and return promptly: the system disables a tap
// whose callback is slow and then reports `tapDisabledByTimeout` to the handler.

import CoreGraphics
import Foundation
import KVMContracts

/// One active event tap on the main run loop.
///
/// State lives behind one `NSLock`, hence `@unchecked Sendable`. The handler
/// is never called while the lock is held.
package final class MacEventTap: @unchecked Sendable {
  /// Returns the event to let through, or `nil` to swallow it. Called on the
  /// main thread, also for `tapDisabledByTimeout` and `tapDisabledByUserInput`.
  package typealias Handler = (CGEventType, CGEvent) -> CGEvent?

  /// Keyboard, pointer, button and wheel events.
  static let eventMask: CGEventMask = {
    let types: [CGEventType] = [
      .keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
      .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown,
      .otherMouseUp, .otherMouseDragged, .scrollWheel,
    ]
    return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
  }()

  private let handler: Handler
  private let lock = NSLock()
  private var port: CFMachPort?
  private var source: CFRunLoopSource?

  package init(handler: @escaping Handler) {
    self.handler = handler
  }

  /// Creates and enables the tap. Throws `permission.accessibilityDenied`
  /// when the system refuses it; idempotent while installed.
  package func install() throws(CoreError) {
    let installed = lock.withLock { port != nil }
    if installed { return }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: Self.eventMask, callback: macEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
    else {
      throw CoreError(
        code: .permission(.accessibilityDenied), severity: .error,
        retryDisposition: .userActionRequired, cleanupDisposition: .notRequired)
    }
    lock.withLock {
      self.port = port
      self.source = source
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
  }

  /// Re-enables a tap the system disabled.
  package func reenable() {
    if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
  }

  /// Disables and removes the tap. Idempotent.
  package func remove() {
    let removed: (CFMachPort, CFRunLoopSource)? = lock.withLock {
      guard let port, let source else { return nil }
      self.port = nil
      self.source = nil
      return (port, source)
    }
    guard let (port, source) = removed else { return }
    CGEvent.tapEnable(tap: port, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFMachPortInvalidate(port)
  }

  fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
    handler(type, event)
  }
}

private func macEventTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let tap = Unmanaged<MacEventTap>.fromOpaque(userInfo).takeUnretainedValue()
  guard let result = tap.handle(type, event) else { return nil }
  return Unmanaged.passUnretained(result)
}

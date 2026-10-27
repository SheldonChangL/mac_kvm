import CoreGraphics
import Foundation
import KVMContracts

/// Decides, inside the server event-tap callback, whether a local event is
/// swallowed while input is routed to a remote screen (M2-013).
///
/// Rules, checked in order:
/// 1. A tap-disabled notification (timeout or user input) stops suppression
///    immediately and returns `failOpen`; the owner reports `captureFailure`.
/// 2. Synthetic first-party events (M2-006) always pass through.
/// 3. The emergency escape chord (injected predicate from Core, M2-014)
///    stops suppression synchronously and returns `emergencyEscape`; it is
///    never swallowed.
/// 4. The system Force Quit chord (Command + Option + Escape) passes through.
/// 5. Otherwise the event is suppressed only while suppression is enabled,
///    which the owner does solely for the committed `remote` state (M2-008).
///
/// The flag lives behind one `NSLock`; `decide` never awaits, allocates only
/// the mapped event, and never logs. Disabling is idempotent and always wins:
/// any failure path can call `disableSuppression()` or `tapFailed()`.
package final class LocalEventSuppressor: @unchecked Sendable {
  package enum Decision: Equatable, Sendable {
    case passThrough
    case suppress
    case failOpen
    case emergencyEscape
  }

  private let filter: SyntheticEventFilter
  private let isEmergencyEscape: @Sendable (KVMEvent) -> Bool
  private let lock = NSLock()
  private var suppressing = false

  package init(
    filter: SyntheticEventFilter, isEmergencyEscape: @escaping @Sendable (KVMEvent) -> Bool
  ) {
    self.filter = filter
    self.isEmergencyEscape = isEmergencyEscape
  }

  package var isSuppressing: Bool {
    lock.withLock { suppressing }
  }

  /// Called only for the reducer's `enableSuppression` effect.
  package func enableSuppression() {
    lock.withLock { suppressing = true }
  }

  /// Stops suppression. Idempotent and immediate.
  package func disableSuppression() {
    lock.withLock { suppressing = false }
  }

  /// Fails open after a tap or permission error.
  package func tapFailed() {
    disableSuppression()
  }

  package func decide(type: CGEventType, event: CGEvent) -> Decision {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      disableSuppression()
      return .failOpen
    }
    if case .synthetic = filter.classify(event) {
      return .passThrough
    }
    if type == .keyDown || type == .keyUp || type == .flagsChanged,
      let mapped = MacKeyboardCapture.map(event)?.event
    {
      if isEmergencyEscape(mapped) {
        disableSuppression()
        return .emergencyEscape
      }
      if Self.isForceQuit(mapped) {
        return .passThrough
      }
    }
    return isSuppressing ? .suppress : .passThrough
  }

  private static func isForceQuit(_ event: KVMEvent) -> Bool {
    guard case .key(.escape, _, let modifiers) = event else { return false }
    return modifiers.command && modifiers.option
  }
}

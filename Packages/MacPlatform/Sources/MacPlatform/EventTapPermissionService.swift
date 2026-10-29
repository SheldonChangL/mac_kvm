import ApplicationServices
import CoreGraphics
import KVMContracts

/// Whether the server may install its suppressing event tap.
package enum EventTapReadiness: String, CaseIterable, Hashable, Sendable {
  case ready
  /// Input Monitoring (listen-event access) is not granted.
  case listenAccessDenied
  /// Accessibility trust, needed to suppress and inject, is not granted.
  case accessibilityDenied

  /// Remote mode is allowed only when every permission is granted (M2-001).
  package var canEnterRemote: Bool { self == .ready }

  /// The frozen M1-015 failure for a caller that cannot proceed.
  package var failure: CoreError? {
    switch self {
    case .ready:
      nil
    case .listenAccessDenied:
      CoreError(
        code: .permission(.capabilityUnavailable), severity: .error,
        retryDisposition: .userActionRequired, cleanupDisposition: .notRequired)
    case .accessibilityDenied:
      CoreError(
        code: .permission(.accessibilityDenied), severity: .error,
        retryDisposition: .userActionRequired, cleanupDisposition: .notRequired)
    }
  }
}

/// Injectable macOS permission calls.
struct EventTapPermissionEnvironment: Sendable {
  var preflightListenAccess: @Sendable () -> Bool
  var requestListenAccess: @Sendable () -> Bool
  var isAccessibilityTrusted: @Sendable () -> Bool

  /// Production default using the documented public APIs.
  static let live = EventTapPermissionEnvironment(
    preflightListenAccess: { CGPreflightListenEventAccess() },
    requestListenAccess: { CGRequestListenEventAccess() },
    isAccessibilityTrusted: { AXIsProcessTrusted() }
  )
}

/// Event-tap permission preflight and disabled-tap diagnostics (M2-002).
///
/// The service is stateless: each call is one synchronous macOS query. It
/// never installs a tap itself; the owner must call `preflight()` before
/// creating one and must not enter remote mode unless it returns `ready`.
package struct EventTapPermissionService: Sendable {
  private let environment: EventTapPermissionEnvironment

  package init() {
    self.init(environment: .live)
  }

  init(environment: EventTapPermissionEnvironment) {
    self.environment = environment
  }

  /// Reads both permissions without prompting. Listen access is checked
  /// first because without it no tap can observe input at all.
  package func preflight() -> EventTapReadiness {
    guard environment.preflightListenAccess() else { return .listenAccessDenied }
    guard environment.isAccessibilityTrusted() else { return .accessibilityDenied }
    return .ready
  }

  /// Requests listen access only when it is missing, then re-reads state.
  ///
  /// The SDK request may prompt asynchronously; the result reports the state
  /// at return only. Accessibility is requested through M1-035.
  package func requestMissingAccess() -> EventTapReadiness {
    if !environment.preflightListenAccess() {
      guard environment.requestListenAccess() else { return .listenAccessDenied }
    }
    guard environment.isAccessibilityTrusted() else { return .accessibilityDenied }
    return .ready
  }

  /// Typed diagnostic for a tap the system disabled, or `nil` for any other
  /// event type. The owner must fail open (M2-001) when this is non-nil.
  /// Diagnostic code 1 is a timeout, 2 is user input.
  package static func diagnoseDisabledTap(_ type: CGEventType) -> CoreError? {
    let code: Int32
    switch type {
    case .tapDisabledByTimeout: code = 1
    case .tapDisabledByUserInput: code = 2
    default: return nil
    }
    return CoreError(
      code: .inputSafety(.cleanupRequired), severity: .error,
      retryDisposition: .immediateAfterStateChange, cleanupDisposition: .notRequired,
      underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: code))
  }
}

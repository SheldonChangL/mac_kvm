import AppKit

// The macOS SDK declares `kAXTrustedCheckOptionPrompt` as a mutable C global,
// which Swift 6 refuses to read from a nonisolated context. `@preconcurrency`
// is the narrowest available way to read the SDK-declared constant instead of
// hard-coding its string value.
@preconcurrency import ApplicationServices
import Foundation
import KVMContracts

/// The immediate Accessibility trust state of this process.
///
/// `notTrusted` is a valid, expected state. It is not a crash condition and is
/// not automatically a failure: only a caller that cannot proceed without trust
/// converts it into the frozen `permission.accessibilityDenied` failure.
package enum AccessibilityTrustState: String, CaseIterable, Hashable, Sendable {
  case trusted
  case notTrusted

  /// The frozen M1-015 failure for a caller that cannot proceed without trust,
  /// or `nil` while trusted.
  ///
  /// The value carries no platform error object, message, path, or status, and
  /// automatic retry is refused: only explicit user action can change trust.
  package var actionableFailure: CoreError? {
    switch self {
    case .trusted:
      nil
    case .notTrusted:
      CoreError(
        code: .permission(.accessibilityDenied),
        severity: .error,
        retryDisposition: .userActionRequired,
        cleanupDisposition: .notRequired
      )
    }
  }
}

/// The outcome of one Accessibility trust request.
package struct AccessibilityTrustRequestResult: Hashable, Sendable {
  /// Whether the request submitted the SDK prompt option.
  ///
  /// Always `true` for `AccessibilityPermissionService.requestTrust()`.
  package let promptRequested: Bool

  /// The trust state observed at the moment the SDK call returned.
  ///
  /// The installed macOS SDK documents that prompting occurs asynchronously and
  /// does not affect the return value. `notTrusted` therefore means "not
  /// trusted at return"; it never means the user saw or refused a prompt. A
  /// caller that needs the post-grant state reads `currentTrustState()` again
  /// after observing its own state change.
  package let trustStateAtReturn: AccessibilityTrustState
}

/// What `AccessibilityPermissionService.openSystemSettings()` opened.
package enum AccessibilitySettingsDestination: String, CaseIterable, Hashable, Sendable {
  /// The System Settings application, not a specific pane.
  ///
  /// No installed SDK header or other verified public source declares a URI
  /// that is guaranteed to open the Accessibility pane, so no pane-level URI
  /// contract is invented here. The application is opened instead, and the
  /// limitation is documented rather than hidden.
  case systemSettingsApplication
}

/// Deterministic seam for the four macOS calls this service makes.
///
/// Tests substitute closures so no Accessibility prompt and no System Settings
/// window is ever displayed by an automated run. `live` is the production
/// default and calls the real macOS APIs.
///
/// No seam signature can carry a platform `Error`, localized message, or status
/// code, so arbitrary platform error text cannot reach the typed boundary.
struct AccessibilityPermissionEnvironment: Sendable {
  /// Reads trust without prompting.
  var isProcessTrusted: @Sendable () -> Bool

  /// Reads trust while submitting the SDK prompt option.
  var isProcessTrustedRequestingPrompt: @Sendable (_ prompt: Bool) -> Bool

  /// Resolves the System Settings application, or `nil` when none resolves.
  var settingsApplicationURL: @Sendable () -> URL?

  /// Opens the resolved application, reporting only success or failure.
  var openApplication: @Sendable (URL) -> Bool
}

extension AccessibilityPermissionEnvironment {
  /// Bundle identifier of the macOS System Settings application.
  ///
  /// Read from the `CFBundleIdentifier` of the installed
  /// `/System/Applications/System Settings.app` on macOS 26.2. No SDK header
  /// declares it, so an identifier that does not resolve is reported as a typed
  /// capability failure rather than assumed to be present.
  static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

  /// Production default. Calls the documented public macOS APIs.
  static let live = AccessibilityPermissionEnvironment(
    isProcessTrusted: { AXIsProcessTrusted() },
    isProcessTrustedRequestingPrompt: { prompt in
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    },
    settingsApplicationURL: {
      NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: Self.systemSettingsBundleIdentifier
      )
    },
    openApplication: { applicationURL in NSWorkspace.shared.open(applicationURL) }
  )
}

/// macOS Accessibility permission check, request, and settings-open behavior.
///
/// The service adds no public contract: every declaration is `package` or
/// narrower, so nothing crosses the frozen `CONTRACT_CATALOG` public surface.
///
/// It owns no task, timer, queue, observer, notification registration, or file
/// handle, and holds no mutable state. Each operation is one synchronous macOS
/// call whose result is derived only from that call. There is therefore no
/// cancellation or teardown entry point to expose, and repeating any operation
/// is safe.
package struct AccessibilityPermissionService: Sendable {
  private let environment: AccessibilityPermissionEnvironment

  /// Production initializer. Calls the real macOS APIs.
  package init() {
    self.init(environment: .live)
  }

  init(environment: AccessibilityPermissionEnvironment) {
    self.environment = environment
  }

  /// Reads the current Accessibility trust state without prompting.
  ///
  /// Untrusted is reported as a state. Nothing is thrown and no failure value
  /// is produced, because "not granted yet" is not a failure of this read. A
  /// caller that must refuse to proceed uses `actionableFailure`.
  package func currentTrustState() -> AccessibilityTrustState {
    environment.isProcessTrusted() ? .trusted : .notTrusted
  }

  /// Asks macOS to prompt for Accessibility trust and reports only the trust
  /// state observed when the SDK call returned.
  ///
  /// The prompt option is always submitted. Per the installed SDK the prompt is
  /// asynchronous and does not change the return value, so the reported state
  /// is never evidence of a user answer. The service does not sleep, poll,
  /// retry, or otherwise wait for the prompt to be answered.
  package func requestTrust() -> AccessibilityTrustRequestResult {
    let trustedAtReturn = environment.isProcessTrustedRequestingPrompt(true)
    return AccessibilityTrustRequestResult(
      promptRequested: true,
      trustStateAtReturn: trustedAtReturn ? .trusted : .notTrusted
    )
  }

  /// Opens the System Settings application through documented public API.
  ///
  /// Only the application is opened; see `AccessibilitySettingsDestination`.
  /// Both failure paths map to the frozen `permission.capabilityUnavailable`
  /// code and carry no platform error object, message, path, or status. The
  /// resolved application URL never crosses the boundary.
  package func openSystemSettings() -> CoreResult<AccessibilitySettingsDestination> {
    guard let applicationURL = environment.settingsApplicationURL() else {
      // Nothing resolved, so no user action can complete the request here.
      return .failure(
        CoreError(
          code: .permission(.capabilityUnavailable),
          severity: .error,
          retryDisposition: .never,
          cleanupDisposition: .notRequired
        )
      )
    }

    guard environment.openApplication(applicationURL) else {
      // The system refused the open request. Retry is possible, but only after
      // explicit user action; this service never retries automatically.
      return .failure(
        CoreError(
          code: .permission(.capabilityUnavailable),
          severity: .error,
          retryDisposition: .userActionRequired,
          cleanupDisposition: .notRequired
        )
      )
    }

    return .success(.systemSettingsApplication)
  }
}

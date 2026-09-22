import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

/// Records every seam invocation so a test can assert exactly which macOS call
/// the service made, with which argument, and how many times.
///
/// The seam closures are `@Sendable`, so the recorder is lock-guarded and
/// declared `@unchecked Sendable`. macOS 14 is the platform floor, so `NSLock`
/// is used rather than `Synchronization.Mutex`.
private final class SeamRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var trustCheckCount = 0
  private var promptArguments: [Bool] = []
  private var settingsLookupCount = 0
  private var openCount = 0

  var trustChecks: Int { lock.withLock { trustCheckCount } }
  var prompts: [Bool] { lock.withLock { promptArguments } }
  var settingsLookups: Int { lock.withLock { settingsLookupCount } }
  var opens: Int { lock.withLock { openCount } }

  func recordTrustCheck() {
    lock.withLock { trustCheckCount += 1 }
  }

  func recordPrompt(_ prompt: Bool) {
    lock.withLock { promptArguments.append(prompt) }
  }

  func recordSettingsLookup() {
    lock.withLock { settingsLookupCount += 1 }
  }

  func recordOpen() {
    lock.withLock { openCount += 1 }
  }
}

/// A path-shaped value used only to prove the service never lets a filesystem
/// path reach a caller or a typed failure.
private let injectedSettingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")

private func makeService(
  recorder: SeamRecorder,
  trusted: Bool = false,
  trustedWhenPrompted: Bool = false,
  settingsURL: URL? = injectedSettingsURL,
  openSucceeds: Bool = true
) -> AccessibilityPermissionService {
  AccessibilityPermissionService(
    environment: AccessibilityPermissionEnvironment(
      isProcessTrusted: {
        recorder.recordTrustCheck()
        return trusted
      },
      isProcessTrustedRequestingPrompt: { prompt in
        recorder.recordPrompt(prompt)
        return trustedWhenPrompted
      },
      settingsApplicationURL: {
        recorder.recordSettingsLookup()
        return settingsURL
      },
      openApplication: { _ in
        recorder.recordOpen()
        return openSucceeds
      }
    )
  )
}

@Test func trustedProcessReportsTrustedStateWithoutPrompting() {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, trusted: true)

  #expect(service.currentTrustState() == .trusted)
  #expect(service.currentTrustState().actionableFailure == nil)
  #expect(recorder.trustChecks == 2)
  #expect(recorder.prompts.isEmpty)
  #expect(recorder.settingsLookups == 0)
  #expect(recorder.opens == 0)
}

@Test func untrustedProcessIsAValidStateMappedToTheFrozenPermissionFailure() {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, trusted: false)

  let state = service.currentTrustState()
  #expect(state == .notTrusted)
  #expect(recorder.trustChecks == 1)
  #expect(recorder.prompts.isEmpty)

  let failure = state.actionableFailure
  #expect(failure?.code == .permission(.accessibilityDenied))
  #expect(failure?.domain == .permission)
  #expect(failure?.severity == .error)
  #expect(failure?.retryDisposition == .userActionRequired)
  #expect(failure?.retryDisposition.allowsAutomaticRetry == false)
  #expect(failure?.cleanupDisposition == .notRequired)
  #expect(failure?.underlyingDiagnosticCode == nil)
}

@Test func requestSubmitsThePromptOptionAndReportsOnlyTheImmediateState() {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, trustedWhenPrompted: false)

  let result = service.requestTrust()

  #expect(recorder.prompts == [true])
  #expect(result.promptRequested)
  #expect(result.trustStateAtReturn == .notTrusted)

  // The installed SDK documents that prompting is asynchronous and does not
  // affect the return value. The service therefore reports the immediate state
  // only: it must not re-read trust, poll, sleep, or wait for an answer.
  #expect(recorder.trustChecks == 0)
  #expect(recorder.settingsLookups == 0)
  #expect(recorder.opens == 0)
}

@Test(arguments: [true, false])
func requestAlwaysSubmitsThePromptOptionRegardlessOfTrustState(trustedWhenPrompted: Bool) {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, trustedWhenPrompted: trustedWhenPrompted)

  let result = service.requestTrust()

  #expect(recorder.prompts == [true])
  #expect(result.promptRequested)
  #expect(result.trustStateAtReturn == (trustedWhenPrompted ? .trusted : .notTrusted))
}

@Test func openSettingsReportsTheApplicationDestinationOnSuccess() throws {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder)

  let destination = try service.openSystemSettings().get()

  #expect(destination == .systemSettingsApplication)
  #expect(recorder.settingsLookups == 1)
  #expect(recorder.opens == 1)
  #expect(recorder.prompts.isEmpty)
}

@Test func unresolvableSettingsApplicationFailsClosedWithoutOpeningAnything() {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, settingsURL: nil)

  guard case .failure(let error) = service.openSystemSettings() else {
    Issue.record("expected a typed capability failure when no application resolves")
    return
  }

  #expect(error.code == .permission(.capabilityUnavailable))
  #expect(error.domain == .permission)
  #expect(error.retryDisposition == .never)
  #expect(error.retryDisposition.allowsRetry == false)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)
  #expect(recorder.settingsLookups == 1)
  #expect(recorder.opens == 0)
}

@Test func rejectedOpenRequestMapsToATypedUserActionFailure() {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, openSucceeds: false)

  guard case .failure(let error) = service.openSystemSettings() else {
    Issue.record("expected a typed capability failure when the open request is refused")
    return
  }

  #expect(error.code == .permission(.capabilityUnavailable))
  #expect(error.retryDisposition == .userActionRequired)
  #expect(error.retryDisposition.allowsAutomaticRetry == false)
  #expect(error.cleanupDisposition == .notRequired)
  #expect(error.underlyingDiagnosticCode == nil)
  #expect(recorder.settingsLookups == 1)
  #expect(recorder.opens == 1)
}

@Test func settingsFailuresRetainNoPlatformErrorContentOrPath() throws {
  let recorder = SeamRecorder()
  let failures = [
    makeService(recorder: recorder, settingsURL: nil).openSystemSettings(),
    makeService(recorder: recorder, openSucceeds: false).openSystemSettings(),
  ]

  for failure in failures {
    guard case .failure(let error) = failure else {
      Issue.record("expected a typed capability failure")
      continue
    }

    let encoded = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(
      Set(object.keys) == ["code", "severity", "retryDisposition", "cleanupDisposition"]
    )

    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("System Settings"))
    #expect(!text.contains("/System/Applications"))
    #expect(!text.contains("file://"))
  }
}

@Test func repeatedOperationsAreIdempotentAndOwnNoResourceToClean() throws {
  let recorder = SeamRecorder()
  let service = makeService(recorder: recorder, trusted: true, trustedWhenPrompted: true)

  // Every operation delegates to the seam on every call and derives its result
  // only from that call, so repetition is safe and no state accumulates.
  #expect(service.currentTrustState() == service.currentTrustState())
  #expect(service.requestTrust() == service.requestTrust())
  let first = try service.openSystemSettings().get()
  let second = try service.openSystemSettings().get()
  #expect(first == second)

  #expect(recorder.trustChecks == 2)
  #expect(recorder.prompts == [true, true])
  #expect(recorder.settingsLookups == 2)
  #expect(recorder.opens == 2)

  // The service owns no task, timer, queue, observer, or handle, so there is no
  // cancellation or teardown entry point to exercise. Cancellation is not
  // applicable to this Issue; idempotent repetition is the equivalent proof.
}

@Test func productionDefaultReadsTrustThroughTheRealSDKWithoutDisplayingUI() {
  // The production default calls the real AXIsProcessTrusted, which the
  // installed SDK documents as a plain query with no prompt. requestTrust and
  // openSystemSettings are deliberately not exercised here: they would display
  // OS UI. Their real-machine behavior is reviewer-verified manual evidence.
  let state = AccessibilityPermissionService().currentTrustState()

  #expect(AccessibilityTrustState.allCases.contains(state))
}

// MARK: - Tier-H manual probe

/// Environment variable that selects exactly one real-API action for the manual
/// probe below.
///
/// Unset — which is the case for every ordinary CI run and every ordinary local
/// run — leaves the probe skipped, so no automated run can display OS UI.
private let manualProbeActionKey = "MACKVM_M1_035_MANUAL_PROBE"

/// The exact action names the manual probe accepts. Anything else is rejected.
private enum ManualProbeAction: String {
  case check
  case request
  case openSettings = "open-settings"
}

/// The selected action name, or `nil` when the probe was not selected.
private func selectedManualProbeActionName() -> String? {
  guard let raw = ProcessInfo.processInfo.environment[manualProbeActionKey] else {
    return nil
  }
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

/// Emits one sanitized line for the reviewer to transcribe into `manual.md`.
///
/// Only closed enum case names are ever emitted. No filesystem path, URL,
/// platform error string, typed text, clipboard payload, or other private data
/// can reach this output, because no such value is passed to it.
private func reportManualProbe(action: String, outcome: String) {
  print("M1-035 manual probe: action=\(action) outcome=\(outcome)")
}

/// Maps a failure to a closed taxonomy name, never to platform text.
private func sanitizedFailureName(_ error: CoreError) -> String {
  switch error.code {
  case .permission(let permissionCode):
    "permission.\(permissionCode.rawValue)"
  default:
    "unexpectedDomain.\(error.domain.rawValue)"
  }
}

/// Reviewer-driven Tier-H manual harness. **Not an automated acceptance test.**
///
/// This exists only so the reviewer can drive `AccessibilityPermissionService()`
/// production defaults — the real macOS APIs, with no mocked seam — inside the
/// real SwiftPM test process, and then inspect the actual Accessibility prompt
/// and the actual System Settings window with their own eyes. The probe asserts
/// nothing about that UI, because a test process cannot observe it; the UI
/// observation is the reviewer's, recorded in `evidence/issues/M1-035/manual.md`.
///
/// It is not a shortcut around the automated suite and carries no acceptance
/// credit of its own: every behavior test above still runs and must still pass
/// independently. Being skipped by default is the safety property, not a
/// relaxed assertion or a skipped acceptance case.
///
/// One run performs exactly one action. There is no sleep, poll, retry, or app
/// wiring, and an unrecognized action fails instead of passing silently.
@Test(
  .enabled(
    if: selectedManualProbeActionName() != nil,
    "manual Tier-H probe: set MACKVM_M1_035_MANUAL_PROBE to check, request or open-settings"
  )
)
func manualRealAPIProbeRunsOneReviewerSelectedAction() {
  guard let actionName = selectedManualProbeActionName() else {
    Issue.record("the manual probe ran with no action selected")
    return
  }

  guard let action = ManualProbeAction(rawValue: actionName) else {
    // The unrecognized value is deliberately not echoed: this output is
    // reviewer-facing evidence and must stay free of arbitrary input.
    Issue.record("unknown manual probe action; expected check, request or open-settings")
    return
  }

  let service = AccessibilityPermissionService()

  switch action {
  case .check:
    let state = service.currentTrustState()
    reportManualProbe(action: action.rawValue, outcome: state.rawValue)
    #expect(AccessibilityTrustState.allCases.contains(state))

  case .request:
    let result = service.requestTrust()
    reportManualProbe(action: action.rawValue, outcome: result.trustStateAtReturn.rawValue)
    #expect(result.promptRequested)
    #expect(AccessibilityTrustState.allCases.contains(result.trustStateAtReturn))

  case .openSettings:
    switch service.openSystemSettings() {
    case .success(let destination):
      reportManualProbe(action: action.rawValue, outcome: destination.rawValue)
      #expect(destination == .systemSettingsApplication)
    case .failure(let error):
      reportManualProbe(action: action.rawValue, outcome: sanitizedFailureName(error))
      Issue.record("openSystemSettings reported a typed failure on the real machine")
    }
  }
}

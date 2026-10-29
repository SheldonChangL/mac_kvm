import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private var requests = 0
  var requestCount: Int { lock.withLock { requests } }
  func request() { lock.withLock { requests += 1 } }
}

private func service(
  listen: Bool, accessibility: Bool, requestGrants: Bool = false, calls: Calls = Calls()
)
  -> EventTapPermissionService
{
  EventTapPermissionService(
    environment: EventTapPermissionEnvironment(
      preflightListenAccess: { listen },
      requestListenAccess: {
        calls.request()
        return requestGrants
      },
      isAccessibilityTrusted: { accessibility }
    ))
}

@Suite("M2-002 EventTapPermissionService")
struct EventTapPermissionServiceTests {
  @Test("both permissions granted: ready, remote mode allowed")
  func ready() {
    let s = service(listen: true, accessibility: true)
    #expect(s.preflight() == .ready)
    #expect(s.preflight().canEnterRemote)
    #expect(s.preflight().failure == nil)
  }

  @Test("denials block remote mode with typed failures")
  func denied() {
    let listen = service(listen: false, accessibility: true).preflight()
    #expect(listen == .listenAccessDenied)
    #expect(!listen.canEnterRemote)
    #expect(listen.failure?.code == .permission(.capabilityUnavailable))
    #expect(listen.failure?.retryDisposition == .userActionRequired)

    let accessibility = service(listen: true, accessibility: false).preflight()
    #expect(accessibility == .accessibilityDenied)
    #expect(!accessibility.canEnterRemote)
    #expect(accessibility.failure?.code == .permission(.accessibilityDenied))

    #expect(service(listen: false, accessibility: false).preflight() == .listenAccessDenied)
  }

  @Test("request asks for listen access only when it is missing")
  func request() {
    let calls = Calls()
    #expect(
      service(listen: true, accessibility: true, calls: calls).requestMissingAccess() == .ready)
    #expect(calls.requestCount == 0)
    let granting = service(listen: false, accessibility: true, requestGrants: true, calls: calls)
    #expect(granting.requestMissingAccess() == .ready)
    #expect(calls.requestCount == 1)
    let refusing = service(listen: false, accessibility: true, requestGrants: false, calls: calls)
    #expect(refusing.requestMissingAccess() == .listenAccessDenied)
  }

  @Test("tap-disabled notifications map to typed fail-open diagnostics")
  func disabledDiagnostics() {
    let timeout = EventTapPermissionService.diagnoseDisabledTap(.tapDisabledByTimeout)
    #expect(timeout?.code == .inputSafety(.cleanupRequired))
    #expect(timeout?.underlyingDiagnosticCode == UnderlyingDiagnosticCode(rawValue: 1))
    #expect(timeout?.retryDisposition == .immediateAfterStateChange)
    let userInput = EventTapPermissionService.diagnoseDisabledTap(.tapDisabledByUserInput)
    #expect(userInput?.underlyingDiagnosticCode == UnderlyingDiagnosticCode(rawValue: 2))
    #expect(EventTapPermissionService.diagnoseDisabledTap(.keyDown) == nil)
  }

  @Test("the live environment can be constructed without prompting")
  func live() {
    _ = EventTapPermissionService().preflight()
  }
}

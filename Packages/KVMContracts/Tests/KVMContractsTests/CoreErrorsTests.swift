import Foundation
import Testing

@testable import KVMContracts

private func requireCoreErrorContract<Value: Error & Codable & Equatable & Sendable>(
  _: Value
) {}

@Test func errorCodesMapToTheFrozenDomains() {
  let mappings: [(CoreErrorCode, CoreErrorDomain)] = [
    (.cancellation(.requested), .cancellation),
    (.timeout(.handshake), .timeout),
    (.transport(.disconnected), .transport),
    (.protocolViolation(.malformed), .protocolViolation),
    (.security(.identityChanged), .security),
    (.permission(.accessibilityDenied), .permission),
    (.inputSafety(.cleanupFailed), .inputSafety),
    (.clipboard(.invalidUTF8), .clipboard),
    (.lifecycle(.termination), .lifecycle),
    (.internalFailure(.unclassified), .internalFailure),
  ]

  #expect(mappings.map(\.0.domain) == mappings.map(\.1))
  #expect(Set(mappings.map(\.1)) == Set(CoreErrorDomain.allCases))
}

@Test func frozenErrorCodeAllowlistsAreComplete() {
  #expect(CancellationReason.allCases == [.requested, .superseded, .shutdown])
  #expect(TimeoutErrorCode.allCases == [.connect, .handshake, .read, .write, .keepalive, .cleanup])
  #expect(
    TransportErrorCode.allCases
      == [.unavailable, .disconnected, .refused, .reset, .resourceExhausted]
  )
  #expect(
    ProtocolErrorCode.allCases
      == [.malformed, .oversized, .unsupportedVersion, .unsupportedMessage, .invariantViolation]
  )
  #expect(
    SecurityErrorCode.allCases
      == [
        .identityUnknown, .identityChanged, .identityRevoked, .trustRejected,
        .secureStorageUnavailable,
      ]
  )
  #expect(PermissionErrorCode.allCases == [.accessibilityDenied, .capabilityUnavailable])
  #expect(
    InputSafetyErrorCode.allCases
      == [.cleanupRequired, .cleanupPartial, .cleanupFailed, .localStateRestoreFailed]
  )
  #expect(
    ClipboardErrorCode.allCases == [.unsupportedType, .invalidUTF8, .oversized, .loopRejected])
  #expect(LifecycleErrorCode.allCases == [.sleep, .wake, .termination, .subsystemUnavailable])
  #expect(
    InternalErrorCode.allCases == [.unclassified, .preconditionFailed, .stateInvariantViolation])
  #expect(CoreErrorSeverity.allCases == [.debug, .info, .notice, .warning, .error])
  #expect(CleanupDisposition.allCases == [.notRequired, .completed, .partial, .failed])
}

@Test func typedFailureRoundTripsWithoutArbitraryErrorContent() throws {
  let error = CoreError(
    code: .security(.identityChanged),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .notRequired,
    underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: -9_999)
  )
  requireCoreErrorContract(error)

  let encoded = try JSONEncoder().encode(error)
  let decoded = try JSONDecoder().decode(CoreError.self, from: encoded)

  #expect(decoded == error)
  #expect(decoded.domain == .security)
  #expect(decoded.underlyingDiagnosticCode?.rawValue == -9_999)
  #expect(!String(decoding: encoded, as: UTF8.self).contains("message"))
  #expect(!String(decoding: encoded, as: UTF8.self).contains("description"))
}

@Test func retryDispositionSeparatesAutomaticAndUserMediatedRetry() {
  #expect(!RetryDisposition.never.allowsRetry)
  #expect(!RetryDisposition.never.allowsAutomaticRetry)
  #expect(RetryDisposition.userActionRequired.allowsRetry)
  #expect(!RetryDisposition.userActionRequired.allowsAutomaticRetry)
  #expect(RetryDisposition.backoff.allowsRetry)
  #expect(RetryDisposition.backoff.allowsAutomaticRetry)
  #expect(RetryDisposition.immediateAfterStateChange.allowsRetry)
  #expect(RetryDisposition.immediateAfterStateChange.allowsAutomaticRetry)
}

@Test func underlyingDiagnosticCodePreservesInt32Boundaries() throws {
  for rawValue in [Int32.min, Int32.max] {
    let code = UnderlyingDiagnosticCode(rawValue: rawValue)
    let encoded = try JSONEncoder().encode(code)

    #expect(code.rawValue == rawValue)
    #expect(try JSONDecoder().decode(UnderlyingDiagnosticCode.self, from: encoded) == code)
  }
}

@Test func unknownTaxonomyValuesFailClosed() {
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      CoreErrorDomain.self,
      from: Data(#""not-a-domain""#.utf8)
    )
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(
      RetryDisposition.self,
      from: Data(#""retry-forever""#.utf8)
    )
  }
}

@Test func cancellationFailureRemainsTypedAndTerminal() {
  let cancelled = CoreError(
    code: .cancellation(.shutdown),
    severity: .notice,
    retryDisposition: .never,
    cleanupDisposition: .completed
  )
  let result: CoreResult<Int> = .failure(cancelled)

  switch result {
  case .success:
    Issue.record("cancellation must remain a failure")
  case .failure(let error):
    #expect(error.code == .cancellation(.shutdown))
    #expect(error.domain == .cancellation)
    #expect(error.cleanupDisposition == .completed)
  }
}

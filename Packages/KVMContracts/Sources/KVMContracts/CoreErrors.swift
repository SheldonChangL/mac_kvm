public enum CoreErrorDomain: String, Codable, CaseIterable, Hashable, Sendable {
  case cancellation
  case timeout
  case transport
  case protocolViolation = "protocol"
  case security
  case permission
  case inputSafety
  case clipboard
  case lifecycle
  case internalFailure = "internal"
}

public enum CancellationReason: String, Codable, CaseIterable, Hashable, Sendable {
  case requested
  case superseded
  case shutdown
}

public enum TimeoutErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case connect
  case handshake
  case read
  case write
  case keepalive
  case cleanup
}

public enum TransportErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case unavailable
  case disconnected
  case refused
  case reset
  case resourceExhausted
}

public enum ProtocolErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case malformed
  case oversized
  case unsupportedVersion
  case unsupportedMessage
  case invariantViolation
}

public enum SecurityErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case identityUnknown
  case identityChanged
  case identityRevoked
  case trustRejected
  case secureStorageUnavailable
}

public enum PermissionErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case accessibilityDenied
  case capabilityUnavailable
}

public enum InputSafetyErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case cleanupRequired
  case cleanupPartial
  case cleanupFailed
  case localStateRestoreFailed
}

public enum ClipboardErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case unsupportedType
  case invalidUTF8
  case oversized
  case loopRejected
}

public enum LifecycleErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case sleep
  case wake
  case termination
  case subsystemUnavailable
}

public enum InternalErrorCode: String, Codable, CaseIterable, Hashable, Sendable {
  case unclassified
  case preconditionFailed
  case stateInvariantViolation
}

public enum CoreErrorCode: Codable, Hashable, Sendable {
  case cancellation(CancellationReason)
  case timeout(TimeoutErrorCode)
  case transport(TransportErrorCode)
  case protocolViolation(ProtocolErrorCode)
  case security(SecurityErrorCode)
  case permission(PermissionErrorCode)
  case inputSafety(InputSafetyErrorCode)
  case clipboard(ClipboardErrorCode)
  case lifecycle(LifecycleErrorCode)
  case internalFailure(InternalErrorCode)

  public var domain: CoreErrorDomain {
    switch self {
    case .cancellation:
      .cancellation
    case .timeout:
      .timeout
    case .transport:
      .transport
    case .protocolViolation:
      .protocolViolation
    case .security:
      .security
    case .permission:
      .permission
    case .inputSafety:
      .inputSafety
    case .clipboard:
      .clipboard
    case .lifecycle:
      .lifecycle
    case .internalFailure:
      .internalFailure
    }
  }
}

public enum CoreErrorSeverity: String, Codable, CaseIterable, Hashable, Sendable {
  case debug
  case info
  case notice
  case warning
  case error
}

public enum RetryDisposition: String, Codable, CaseIterable, Hashable, Sendable {
  case never
  case userActionRequired
  case backoff
  case immediateAfterStateChange

  public var allowsRetry: Bool {
    self != .never
  }

  public var allowsAutomaticRetry: Bool {
    switch self {
    case .backoff, .immediateAfterStateChange:
      true
    case .never, .userActionRequired:
      false
    }
  }
}

public enum CleanupDisposition: String, Codable, CaseIterable, Hashable, Sendable {
  case notRequired
  case completed
  case partial
  case failed
}

public struct UnderlyingDiagnosticCode: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: Int32

  public init(rawValue: Int32) {
    self.rawValue = rawValue
  }
}

public struct CoreError: Error, Codable, Hashable, Sendable {
  public let code: CoreErrorCode
  public let severity: CoreErrorSeverity
  public let retryDisposition: RetryDisposition
  public let cleanupDisposition: CleanupDisposition
  public let underlyingDiagnosticCode: UnderlyingDiagnosticCode?

  public var domain: CoreErrorDomain {
    code.domain
  }

  public init(
    code: CoreErrorCode,
    severity: CoreErrorSeverity,
    retryDisposition: RetryDisposition,
    cleanupDisposition: CleanupDisposition,
    underlyingDiagnosticCode: UnderlyingDiagnosticCode? = nil
  ) {
    self.code = code
    self.severity = severity
    self.retryDisposition = retryDisposition
    self.cleanupDisposition = cleanupDisposition
    self.underlyingDiagnosticCode = underlyingDiagnosticCode
  }
}

public typealias CoreResult<Success> = Result<Success, CoreError>

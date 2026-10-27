import KVMContracts

/// Typed registration failures. Carry no identifiers.
package enum SessionManagerError: Error, Equatable, Sendable {
  case duplicateSession
  case duplicateScreen
  case capacityExceeded
  case unknownScreen
}

/// Result of removing a session.
package enum SessionRemoval: Equatable, Sendable {
  case notFound
  case removed
  /// The removed session was the active target; the owner must report
  /// `sessionLost` for this screen to the input reducer.
  case removedActive(ScreenID)
}

/// Owns every server session and the single active target (M2-030).
///
/// Sessions are keyed by `SessionID`, with at most one session per remote
/// screen. At most one screen is the active target. Every mutation completes
/// before any await, so concurrent register/remove calls cannot leave the
/// dictionaries inconsistent; sessions are closed after they were removed.
/// A rejected registration closes the rejected session so no connection leaks.
package actor SessionManager {
  /// Upper bound accepted by `init(maximumSessions:)`.
  package static let largestSessionLimit = 8

  package let maximumSessions: Int
  package private(set) var activeTarget: ScreenID?

  private var sessions: [SessionID: ServerSession] = [:]
  private var sessionByScreen: [ScreenID: SessionID] = [:]

  /// Returns `nil` outside `1...largestSessionLimit`.
  package init?(maximumSessions: Int) {
    guard (1...Self.largestSessionLimit).contains(maximumSessions) else { return nil }
    self.maximumSessions = maximumSessions
  }

  package var count: Int { sessions.count }

  /// Takes ownership of `session` or closes it and throws.
  package func register(_ session: ServerSession) async throws(SessionManagerError) {
    let rejection: SessionManagerError? =
      if sessions[session.id] != nil {
        .duplicateSession
      } else if sessionByScreen[session.screen] != nil {
        .duplicateScreen
      } else if sessions.count >= maximumSessions {
        .capacityExceeded
      } else {
        nil
      }
    guard let rejection else {
      sessions[session.id] = session
      sessionByScreen[session.screen] = session.id
      return
    }
    await session.close(reason: .failure(Self.rejectedError))
    throw rejection
  }

  /// The session serving `screen`, if any.
  package func session(for screen: ScreenID) -> ServerSession? {
    sessionByScreen[screen].flatMap { sessions[$0] }
  }

  /// Makes `screen` the only active target.
  package func activate(_ screen: ScreenID) throws(SessionManagerError) {
    guard sessionByScreen[screen] != nil else { throw .unknownScreen }
    activeTarget = screen
  }

  /// Clears the active target. Idempotent.
  package func deactivate() {
    activeTarget = nil
  }

  /// Removes and closes one session.
  package func remove(_ id: SessionID, reason: DisconnectReason) async -> SessionRemoval {
    guard let session = sessions.removeValue(forKey: id) else { return .notFound }
    sessionByScreen[session.screen] = nil
    let wasActive = activeTarget == session.screen
    if wasActive { activeTarget = nil }
    await session.close(reason: reason)
    return wasActive ? .removedActive(session.screen) : .removed
  }

  /// Removes and closes every session. Returns the active target that was
  /// cleared, if any. Idempotent.
  package func closeAll(reason: DisconnectReason) async -> ScreenID? {
    let closing = Array(sessions.values)
    let previousActive = activeTarget
    sessions = [:]
    sessionByScreen = [:]
    activeTarget = nil
    for session in closing {
      await session.close(reason: reason)
    }
    return previousActive
  }

  private static let rejectedError = CoreError(
    code: .protocolViolation(.invariantViolation), severity: .warning, retryDisposition: .never,
    cleanupDisposition: .completed)
}

import KVMContracts

/// Lifecycle states of one server-to-client session (M2-029).
package enum ServerSessionState: Equatable, Sendable {
  case idle
  case connecting
  case ready
  /// The enter is being written; the session is not yet active.
  case entering
  case active
  case closed
}

/// Owns one protocol-neutral client session for the server role.
///
/// Lifecycle: `idle` → `connecting` → `ready` → `entering` → `active` →
/// `ready` (leave) …, and any state → `closed`. A leave requested while the
/// enter is still being written closes the session, so the peer can never be
/// left entered with no leave.
/// The session is single-use. Every send goes through one FIFO writer, so
/// events reach the protocol session in call order even when a send suspends.
/// Any connect or send failure is terminal: the session disconnects once with
/// the failure as reason and rethrows it, so the owner can report
/// `sessionLost` to the input reducer. `close(reason:)` is idempotent and does
/// not wait for any peer response beyond the protocol session's own bounded
/// cleanup. The session never inspects event content and never logs.
package actor ServerSession {
  package nonisolated let id: SessionID
  package nonisolated let screen: ScreenID
  package private(set) var state = ServerSessionState.idle

  private let protocolSession: any KVMProtocolSession
  private var writerBusy = false
  private var queuedWriters: [CheckedContinuation<Void, Never>] = []
  private var queueObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  package init(id: SessionID, screen: ScreenID, protocolSession: any KVMProtocolSession) {
    self.id = id
    self.screen = screen
    self.protocolSession = protocolSession
  }

  /// Connects the protocol session; `ready` on success, `closed` on failure.
  package func start() async throws(CoreError) {
    try require(.idle)
    state = .connecting
    do throws(CoreError) {
      try await protocolSession.connect()
    } catch {
      await close(reason: .failure(error))
      throw error
    }
    guard state == .connecting else { throw Self.closedError }
    state = .ready
  }

  /// Sends the enter for this session's screen; `active` on success.
  package func enter(at position: NormalizedPoint) async throws(CoreError) {
    try require(.ready)
    state = .entering
    try await write(.enterScreen(screen: screen, position: position))
    guard state == .entering else { throw Self.closedError }
    state = .active
  }

  /// Forwards one input event while `active`, in call order.
  package func forward(_ event: KVMEvent) async throws(CoreError) {
    try require(.active)
    try await write(event)
  }

  /// Sends the leave for this session's screen; back to `ready` on success.
  ///
  /// During an in-flight enter the session is closed instead (superseded),
  /// because the enter may still reach the peer after the leave decision.
  package func leave() async throws(CoreError) {
    if state == .entering {
      await close(reason: .cancellation(.superseded))
      return
    }
    try require(.active)
    state = .ready
    try await write(.leaveScreen(screen: screen))
  }

  /// Ends the session once. Later calls are no-ops.
  package func close(reason: DisconnectReason) async {
    guard state != .closed else { return }
    state = .closed
    await protocolSession.disconnect(reason: reason)
  }

  /// Consumes the peer event stream until it ends, then closes the session.
  ///
  /// Inbound client events are not routed by the server MVP and are dropped
  /// without inspection. Returns the disconnect reason that was applied.
  package func monitorPeer() async -> DisconnectReason {
    let reason: DisconnectReason
    do {
      for try await _ in protocolSession.events {}
      reason = .transportClosed
    } catch let error as CoreError {
      reason = .failure(error)
    } catch {
      reason = .failure(Self.unclassifiedError)
    }
    await close(reason: reason)
    return reason
  }

  /// Test scheduling barrier: completes once `count` writers are queued.
  package func waitForQueuedWriters(count: Int) async {
    guard queuedWriters.count < count else { return }
    await withCheckedContinuation { continuation in
      queueObservers.append((count, continuation))
    }
  }

  private func write(_ event: KVMEvent) async throws(CoreError) {
    await acquireWriter()
    defer { releaseWriter() }
    guard state != .closed else { throw Self.closedError }
    do throws(CoreError) {
      try await protocolSession.send(event)
    } catch {
      await close(reason: .failure(error))
      throw error
    }
  }

  private func acquireWriter() async {
    guard writerBusy else {
      writerBusy = true
      return
    }
    await withCheckedContinuation { continuation in
      queuedWriters.append(continuation)
      let satisfied = queueObservers.filter { queuedWriters.count >= $0.count }
      queueObservers.removeAll { queuedWriters.count >= $0.count }
      for observer in satisfied { observer.continuation.resume() }
    }
  }

  private func releaseWriter() {
    if queuedWriters.isEmpty {
      writerBusy = false
    } else {
      queuedWriters.removeFirst().resume()
    }
  }

  private func require(_ expected: ServerSessionState) throws(CoreError) {
    if state == .closed { throw Self.closedError }
    guard state == expected else { throw Self.preconditionError }
  }

  private static let preconditionError = CoreError(
    code: .internalFailure(.preconditionFailed), severity: .warning, retryDisposition: .never,
    cleanupDisposition: .notRequired)

  private static let closedError = CoreError(
    code: .lifecycle(.subsystemUnavailable), severity: .warning, retryDisposition: .never,
    cleanupDisposition: .notRequired)

  private static let unclassifiedError = CoreError(
    code: .internalFailure(.unclassified), severity: .error, retryDisposition: .never,
    cleanupDisposition: .notRequired)
}

import Foundation
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
/// A forward or enter whose task is cancelled before it is written is never
/// sent: it leaves the writer queue at once and throws `cancellation.requested`
/// without closing the session, and later writers keep their order. A leave is
/// cleanup and is always sent.
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
  private let writerGate = WriterGate()

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
    do throws(CoreError) {
      try await write(.enterScreen(screen: screen, position: position), cancellable: true)
    } catch {
      // A cancelled enter was never written, so the peer was never entered.
      if error == Self.cancellationError, state == .entering { state = .ready }
      throw error
    }
    guard state == .entering else { throw Self.closedError }
    state = .active
  }

  /// Forwards one input event while `active`, in call order.
  package func forward(_ event: KVMEvent) async throws(CoreError) {
    try require(.active)
    try await write(event, cancellable: true)
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
    try await write(.leaveScreen(screen: screen), cancellable: false)
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
    await writerGate.waitForQueued(count: count)
  }

  /// Sends `event` through the FIFO writer.
  ///
  /// A cancellable write whose task is cancelled before the event is sent
  /// throws `cancellation.requested`, sends nothing and leaves the session
  /// open. A non-cancellable write (the leave) is always sent.
  private func write(_ event: KVMEvent, cancellable: Bool) async throws(CoreError) {
    guard await writerGate.acquire(cancellable: cancellable) else {
      throw Self.cancellationError
    }
    defer { writerGate.release() }
    if cancellable, Task.isCancelled { throw Self.cancellationError }
    guard state != .closed else { throw Self.closedError }
    do throws(CoreError) {
      try await protocolSession.send(event)
    } catch {
      await close(reason: .failure(error))
      throw error
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

  private static let cancellationError = CoreError(
    code: .cancellation(.requested), severity: .info, retryDisposition: .never,
    cleanupDisposition: .notRequired)
}

/// One-at-a-time FIFO writer gate whose queued waiters can be cancelled.
///
/// It is lock-guarded rather than actor state because a task's cancellation
/// handler runs synchronously outside the actor; it removes exactly its own
/// waiter, so a cancelled writer neither keeps its place nor wakes another.
private final class WriterGate: @unchecked Sendable {
  private let lock = NSLock()
  private var busy = false
  private var lastToken: UInt64 = 0
  private var waiters: [(token: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
  private var observers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  /// Returns `true` once the caller owns the gate, or `false` when a
  /// cancellable caller's task was cancelled while it waited; such a caller
  /// never owns the gate.
  func acquire(cancellable: Bool) async -> Bool {
    let token = lock.withLock {
      lastToken &+= 1
      return lastToken
    }
    guard cancellable else { return await wait(token: token, cancellable: false) }
    return await withTaskCancellationHandler {
      await wait(token: token, cancellable: true)
    } onCancel: {
      let cancelled = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return nil }
        return waiters.remove(at: index).continuation
      }
      cancelled?.resume(returning: false)
    }
  }

  /// Hands the gate to the oldest waiter, or frees it.
  func release() {
    let next = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard !waiters.isEmpty else {
        busy = false
        return nil
      }
      return waiters.removeFirst().continuation
    }
    next?.resume(returning: true)
  }

  /// Completes once at least `count` writers are queued.
  func waitForQueued(count: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        guard waiters.count < count else { return true }
        observers.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  private func wait(token: UInt64, cancellable: Bool) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      lock.lock()
      if !busy {
        busy = true
        lock.unlock()
        continuation.resume(returning: true)
        return
      }
      if cancellable, Task.isCancelled {
        lock.unlock()
        continuation.resume(returning: false)
        return
      }
      waiters.append((token, continuation))
      let satisfied = observers.filter { waiters.count >= $0.count }
      observers.removeAll { waiters.count >= $0.count }
      lock.unlock()
      for observer in satisfied { observer.continuation.resume() }
    }
  }
}

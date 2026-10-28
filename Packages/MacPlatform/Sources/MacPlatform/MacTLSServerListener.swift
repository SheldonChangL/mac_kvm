// TLS listener for the Barrier server role (M2-024). The protocol module only sees
// abstract transports (M1-ARCH-001), so the socket lives here: each accepted
// connection becomes a not yet connected `MacTLSTransport` whose `connect()` runs
// the server side of the handshake with the Keychain identity. Client
// certificates are not requested; which client may stay is decided by the
// Barrier screen-name allowlist after the handshake. The backlog of unclaimed
// connections is bounded, and a connection beyond it is cancelled at once.

import Foundation
import KVMContracts
import Network
import Security

/// Which interfaces the listener binds.
package enum MacTLSServerListenerScope: Equatable, Sendable {
  /// Loopback only, for local relays and tests.
  case loopback
  /// Every interface, for clients on the network.
  case anyInterface
}

/// Accepts TLS connections on one TCP port.
///
/// State lives behind one `NSLock`, hence `@unchecked Sendable`. No closure or
/// continuation runs while the lock is held. Nothing logs, and no failure
/// carries an address, port or platform diagnostic.
package final class MacTLSServerListener: @unchecked Sendable {
  /// Accepted connections not yet taken by the consumer.
  static let backlogLimit = 4

  /// Accepted, not yet connected transports. Finishes when the listener stops
  /// or fails.
  package let connections: AsyncStream<MacTLSTransport>

  private enum Phase {
    case idle
    case starting(NWListener, CheckedContinuation<Result<Void, CoreError>, Never>?)
    case ready(NWListener)
    case stopped
  }

  private let port: UInt16
  private let scope: MacTLSServerListenerScope
  private let identity: MacServerIdentity
  private let continuation: AsyncStream<MacTLSTransport>.Continuation
  private let queue = DispatchQueue(label: "MacPlatform.MacTLSServerListener")
  private let lock = NSLock()
  private var phase = Phase.idle

  package init(port: UInt16, scope: MacTLSServerListenerScope, identity: MacServerIdentity) {
    self.port = port
    self.scope = scope
    self.identity = identity
    (connections, continuation) = AsyncStream.makeStream(
      of: MacTLSTransport.self, bufferingPolicy: .bufferingOldest(Self.backlogLimit))
  }

  /// Binds and starts listening. Fails if the port is unusable or already
  /// bound, or if called twice.
  package func start() async throws(CoreError) {
    guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port),
      let localIdentity = sec_identity_create(identity.secIdentity)
    else { throw Self.unavailableFailure }

    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
    sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, false)
    let tcp = NWProtocolTCP.Options()
    // Input frames are a few bytes each; Nagle would hold them back.
    tcp.noDelay = true
    let parameters = NWParameters(tls: tls, tcp: tcp)
    if scope == .loopback { parameters.requiredInterfaceType = .loopback }

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters, on: endpointPort)
    } catch {
      throw Self.unavailableFailure
    }
    let claimed: Bool = lock.withLock {
      guard case .idle = phase else { return false }
      phase = .starting(listener, nil)
      return true
    }
    guard claimed else { throw Self.misuseFailure }

    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      self.accept(connection)
    }
    listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }

    let outcome: Result<Void, CoreError> = await withTaskCancellationHandler {
      await withCheckedContinuation { waiter in
        let installed: Bool = lock.withLock {
          guard case .starting(let current, nil) = phase else { return false }
          phase = .starting(current, waiter)
          return true
        }
        guard installed else {
          waiter.resume(returning: .failure(Self.cancellationFailure))
          return
        }
        listener.start(queue: queue)
      }
    } onCancel: { [weak self] in
      self?.stop()
    }
    try outcome.get()
  }

  /// Stops listening and finishes `connections`. Transports already handed
  /// out stay with their owners. Idempotent.
  package func stop() {
    end(with: Self.cancellationFailure)
  }

  /// Moves to the terminal state once: a pending `start()` gets `failure`.
  private func end(with failure: CoreError) {
    let ended: (NWListener?, CheckedContinuation<Result<Void, CoreError>, Never>?)? =
      lock.withLock {
        switch phase {
        case .stopped:
          return nil
        case .idle:
          phase = .stopped
          return (nil, nil)
        case .starting(let listener, let waiter):
          phase = .stopped
          return (listener, waiter)
        case .ready(let listener):
          phase = .stopped
          return (listener, nil)
        }
      }
    guard let ended else { return }
    ended.1?.resume(returning: .failure(failure))
    ended.0?.cancel()
    continuation.finish()
  }

  private func accept(_ connection: NWConnection) {
    let open: Bool = lock.withLock {
      if case .ready = phase { return true }
      return false
    }
    guard open else {
      connection.cancel()
      return
    }
    switch continuation.yield(MacTLSTransport.acceptedServer(connection)) {
    case .enqueued:
      break
    case .dropped, .terminated:
      connection.cancel()
    @unknown default:
      connection.cancel()
    }
  }

  private func handle(_ state: NWListener.State) {
    switch state {
    case .ready:
      let waiter: CheckedContinuation<Result<Void, CoreError>, Never>? = lock.withLock {
        guard case .starting(let listener, let waiter) = phase else { return nil }
        phase = .ready(listener)
        return waiter
      }
      waiter?.resume(returning: .success(()))
    case .failed, .waiting:
      // A port in use, a lost interface or a dead listener: nothing to retry.
      end(with: Self.unavailableFailure)
    case .cancelled:
      stop()
    case .setup:
      break
    @unknown default:
      break
    }
  }

  // MARK: Failures

  private static let unavailableFailure = CoreError(
    code: .transport(.unavailable),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .completed
  )

  private static let misuseFailure = CoreError(
    code: .internalFailure(.preconditionFailed),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private static let cancellationFailure = CoreError(
    code: .cancellation(.requested),
    severity: .info,
    retryDisposition: .never,
    cleanupDisposition: .completed
  )
}

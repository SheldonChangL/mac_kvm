import Foundation
import KVMContracts
import Network
import Security

// MARK: - Internal seam

/// Which channel security a connection request asks the backend for.
///
/// Release builds can only express `.tls`. The debug-only plaintext case exists
/// for local development against a peer without TLS and is compiled out of
/// every release build.
enum MacTLSTransportSecurity: Equatable, Sendable {
  case tls
  /// Server role over a connection `MacTLSServerListener` accepted with the
  /// local identity. Client certificates are not requested, so the handshake
  /// presents no peer chain and none is required; a chain presented anyway is
  /// rejected.
  case acceptedServer
  #if DEBUG
    case debugInsecurePlaintext
  #endif
}

/// What a backend is asked to connect to. Created only when `connect()` runs.
struct MacTLSTransportConnectionRequest: Equatable, Sendable {
  let host: String
  let port: UInt16
  let security: MacTLSTransportSecurity
}

/// The injected trust evaluator's answer for a presented peer chain.
package enum MacTLSTrustDecision: Equatable, Sendable {
  case accept
  case reject(SecurityErrorCode)
}

/// Backend failures, already stripped of platform errors, codes, and text.
enum MacTLSTransportBackendFailure: Error, Equatable, Sendable {
  case unavailable
  case refused
  case reset
  case disconnected
  case timedOut
  case tlsFailure
  case cancelled
}

/// One completed backend read.
enum MacTLSTransportBackendRead: Equatable, Sendable {
  case bytes(Data)
  case endOfStream
}

/// The byte-stream operations `MacTLSTransport` drives.
///
/// `start` hands the peer's DER certificates, in platform callback order, to
/// `verifyPeer` during the handshake, before the connection is ready, and fails
/// with `.tlsFailure` when it answers `false`. `cancel` is idempotent and wakes every pending
/// operation.
protocol MacTLSTransportBackend: Sendable {
  func start(verifyPeer: @escaping @Sendable ([Data]) -> Bool)
    async throws(MacTLSTransportBackendFailure)
  func send(_ data: Data) async throws(MacTLSTransportBackendFailure)
  func receive(maximumLength: Int)
    async throws(MacTLSTransportBackendFailure) -> MacTLSTransportBackendRead
  func cancel()
}

// MARK: - Transport

/// A single-use, TLS-by-default `Transport` over an injected backend.
///
/// The production backend is `MacTLSNetworkBackend` (Network.framework). The
/// transport knows nothing about any wire protocol: it moves opaque bytes and
/// asks the injected trust evaluator about the peer chain during the handshake,
/// once per verify callback (the platform may invoke it more than once). An
/// empty or oversized chain, a handshake that becomes ready without presenting
/// a chain, or any rejection from any callback fails closed.
///
/// State lives behind one `NSLock`, which is why the class is
/// `@unchecked Sendable`. No closure, continuation, backend call, stream yield,
/// stream finish, or task cancellation ever runs while the lock is held.
///
/// No path logs, and no failure carries host, bytes, certificate material, or a
/// platform diagnostic.
package final class MacTLSTransport: Transport, @unchecked Sendable {
  /// Fixed upper bound for one backend read.
  static let maximumReceiveLength = 65_536

  /// Maximum number of chunks buffered for a slow consumer: at most 1 MiB.
  static let incomingChunkBufferLimit = 16

  /// Maximum number of certificates accepted in a presented peer chain.
  static let maximumPeerCertificateCount = 10

  /// Maximum total DER size of a presented peer chain: 256 KiB.
  static let maximumPeerCertificateBytes = 262_144

  package let incomingBytes: AsyncThrowingStream<Data, any Error>

  private enum Phase {
    case idle
    /// `nil` while the backend is being created outside the lock.
    case connecting((any MacTLSTransportBackend)?)
    case connected(any MacTLSTransportBackend, receiveTask: Task<Void, Never>?)
    case terminated
  }

  private struct State {
    var phase: Phase = .idle
    var peerVerified = false
    var trustRejection: SecurityErrorCode?
    var sendInFlight = false
    var sendWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private enum Ending {
    case finished
    case failed(CoreError)
    /// The single consumer already ended the stream.
    case consumerGone
  }

  private let request: MacTLSTransportConnectionRequest
  private let trustEvaluator: @Sendable ([Data]) -> MacTLSTrustDecision
  private let backendFactory:
    @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var state = State()

  /// Production entry point: TLS to `host:port`, trusting only what
  /// `trustEvaluator` accepts. Always uses the Network.framework backend.
  package convenience init(
    host: String,
    port: UInt16,
    trustEvaluator: @escaping @Sendable ([Data]) -> MacTLSTrustDecision
  ) {
    self.init(
      host: host,
      port: port,
      trustEvaluator: trustEvaluator,
      backendFactory: { MacTLSNetworkBackend(request: $0) }
    )
  }

  /// Test seam: TLS to `host:port` over an injected backend.
  convenience init(
    host: String,
    port: UInt16,
    trustEvaluator: @escaping @Sendable ([Data]) -> MacTLSTrustDecision,
    backendFactory:
      @escaping @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend
  ) {
    self.init(
      request: MacTLSTransportConnectionRequest(host: host, port: port, security: .tls),
      trustEvaluator: trustEvaluator,
      backendFactory: backendFactory
    )
  }

  /// Server role: wraps one connection the TLS listener accepted. `connect()`
  /// starts it and completes the server side of the handshake.
  static func acceptedServer(_ connection: NWConnection) -> MacTLSTransport {
    acceptedServer(backendFactory: { _ in MacTLSNetworkBackend(acceptedConnection: connection) })
  }

  /// Test seam: the server role over an injected backend. The evaluator rejects
  /// every chain, so only a handshake that presents none can succeed.
  static func acceptedServer(
    backendFactory:
      @escaping @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend
  ) -> MacTLSTransport {
    MacTLSTransport(
      request: MacTLSTransportConnectionRequest(host: "", port: 0, security: .acceptedServer),
      trustEvaluator: { _ in .reject(.trustRejected) },
      backendFactory: backendFactory
    )
  }

  #if DEBUG
    /// Debug-only plaintext transport over the Network.framework backend.
    /// Never consults or accepts a trust decision; it does not exist in release
    /// builds.
    package static func debugInsecurePlaintext(
      host: String,
      port: UInt16
    ) -> MacTLSTransport {
      debugInsecurePlaintext(
        host: host,
        port: port,
        backendFactory: { MacTLSNetworkBackend(request: $0) }
      )
    }

    /// Test seam: debug-only plaintext transport over an injected backend.
    static func debugInsecurePlaintext(
      host: String,
      port: UInt16,
      backendFactory:
        @escaping @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend
    ) -> MacTLSTransport {
      MacTLSTransport(
        request: MacTLSTransportConnectionRequest(
          host: host,
          port: port,
          security: .debugInsecurePlaintext
        ),
        trustEvaluator: { _ in .reject(.trustRejected) },
        backendFactory: backendFactory
      )
    }
  #endif

  private init(
    request: MacTLSTransportConnectionRequest,
    trustEvaluator: @escaping @Sendable ([Data]) -> MacTLSTrustDecision,
    backendFactory:
      @escaping @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend
  ) {
    self.request = request
    self.trustEvaluator = trustEvaluator
    self.backendFactory = backendFactory
    let (stream, continuation) = AsyncThrowingStream.makeStream(
      of: Data.self,
      throwing: (any Error).self,
      bufferingPolicy: .bufferingOldest(Self.incomingChunkBufferLimit)
    )
    incomingBytes = stream
    self.continuation = continuation
    continuation.onTermination = { [weak self] termination in
      if case .cancelled = termination { self?.terminate(.consumerGone) }
    }
  }

  // MARK: Transport

  package func connect() async throws(CoreError) {
    let claimed: Bool = lock.withLock {
      guard case .idle = state.phase else { return false }
      state.phase = .connecting(nil)
      return true
    }
    guard claimed else { throw Self.misuseFailure }

    let backend = backendFactory(request)
    let installed: Bool = lock.withLock {
      guard case .connecting(.none) = state.phase else { return false }
      state.phase = .connecting(backend)
      return true
    }
    guard installed else {
      // Disconnected while the backend was being created.
      backend.cancel()
      throw Self.cancellationFailure
    }

    let outcome: Result<Void, MacTLSTransportBackendFailure> = await withTaskCancellationHandler {
      () async -> Result<Void, MacTLSTransportBackendFailure> in
      do throws(MacTLSTransportBackendFailure) {
        try await backend.start(verifyPeer: { [weak self] chain in
          self?.verifyPeer(chain) ?? false
        })
        return .success(())
      } catch {
        return .failure(error)
      }
    } onCancel: { [weak self] in
      self?.terminate(.failed(MacTLSTransport.cancellationFailure))
    }

    let verdict: Result<Void, CoreError>? = lock.withLock {
      // Already terminated by disconnect, task cancellation, or the consumer.
      guard case .connecting = state.phase else { return nil }
      switch outcome {
      case .failure(let failure):
        return .failure(
          state.trustRejection.map(Self.securityFailure) ?? Self.mapped(failure, phase: .connect)
        )
      case .success:
        if let rejection = state.trustRejection {
          return .failure(Self.securityFailure(rejection))
        }
        guard state.peerVerified || !requiresPeerVerification else {
          return .failure(Self.securityFailure(.trustRejected))
        }
        state.phase = .connected(backend, receiveTask: nil)
        return .success(())
      }
    }

    switch verdict {
    case nil:
      throw Self.cancellationFailure
    case .failure(let error)?:
      guard terminate(.failed(error)) else { throw Self.cancellationFailure }
      throw error
    case .success?:
      break
    }

    let receiveTask = Task<Void, Never> { [weak self] in
      guard let self else { return }
      await self.receiveLoop(from: backend)
    }
    let owned: Bool = lock.withLock {
      guard case .connected(let current, .none) = state.phase else { return false }
      state.phase = .connected(current, receiveTask: receiveTask)
      return true
    }
    if !owned { receiveTask.cancel() }
  }

  package func send(_ data: Data) async throws(CoreError) {
    let rejection: CoreError? = lock.withLock {
      switch state.phase {
      case .idle, .connecting: return Self.misuseFailure
      case .terminated: return Self.closedFailure
      case .connected: return nil
      }
    }
    if let rejection { throw rejection }
    guard !data.isEmpty else { return }

    await acquireSendSlot()
    defer { releaseSendSlot() }

    let backend: (any MacTLSTransportBackend)? = lock.withLock {
      guard case .connected(let backend, _) = state.phase else { return nil }
      return backend
    }
    guard let backend else { throw Self.closedFailure }

    do throws(MacTLSTransportBackendFailure) {
      try await backend.send(data)
    } catch {
      let failure = Self.mapped(error, phase: .write)
      guard terminate(.failed(failure)) else { throw Self.closedFailure }
      throw failure
    }
  }

  /// Synchronous and bounded: never waits for the peer, so an already
  /// cancelled caller still completes cleanup.
  package func disconnect() async {
    terminate(.finished)
  }

  // MARK: Lifecycle

  private var requiresPeerVerification: Bool {
    switch request.security {
    case .tls:
      return true
    case .acceptedServer:
      return false
    #if DEBUG
      case .debugInsecurePlaintext:
        return false
    #endif
    }
  }

  /// Moves to the terminal state exactly once: cancels the receive task and
  /// backend, wakes queued senders, and ends the stream. Returns `false` when
  /// the lifecycle had already ended.
  @discardableResult
  private func terminate(_ ending: Ending) -> Bool {
    let released:
      (
        backend: (any MacTLSTransportBackend)?,
        task: Task<Void, Never>?,
        waiters: [CheckedContinuation<Void, Never>]
      )? =
        lock.withLock {
          let phase = state.phase
          if case .terminated = phase { return nil }
          state.phase = .terminated
          let waiters = state.sendWaiters
          state.sendWaiters = []
          switch phase {
          case .idle, .terminated:
            return (nil, nil, waiters)
          case .connecting(let pending):
            return (pending, nil, waiters)
          case .connected(let connected, let receiveTask):
            return (connected, receiveTask, waiters)
          }
        }
    guard let released else { return false }

    released.task?.cancel()
    released.backend?.cancel()
    for waiter in released.waiters { waiter.resume() }
    switch ending {
    case .finished:
      continuation.finish()
    case .failed(let error):
      continuation.finish(throwing: error)
    case .consumerGone:
      break
    }
    return true
  }

  /// The handshake verify callback. The platform may invoke it more than once;
  /// each valid callback while connecting consults the evaluator once. Never
  /// evaluates an empty or oversized chain. Any rejection is sticky and wins
  /// over an earlier acceptance.
  private func verifyPeer(_ chain: [Data]) -> Bool {
    let shouldEvaluate: Bool = lock.withLock {
      guard case .connecting = state.phase, state.trustRejection == nil else {
        return false
      }
      guard Self.isAcceptableChainShape(chain) else {
        state.peerVerified = false
        state.trustRejection = .trustRejected
        return false
      }
      return true
    }
    guard shouldEvaluate else { return false }

    let decision = trustEvaluator(chain)
    return lock.withLock {
      guard case .connecting = state.phase, state.trustRejection == nil else { return false }
      switch decision {
      case .accept:
        state.peerVerified = true
        return true
      case .reject(let code):
        state.peerVerified = false
        state.trustRejection = code
        return false
      }
    }
  }

  /// Non-empty, at most `maximumPeerCertificateCount` certificates, and at
  /// most `maximumPeerCertificateBytes` of DER in total. Summed against a
  /// remaining budget so it cannot overflow.
  private static func isAcceptableChainShape(_ chain: [Data]) -> Bool {
    guard !chain.isEmpty, chain.count <= maximumPeerCertificateCount else { return false }
    var remaining = maximumPeerCertificateBytes
    for certificate in chain {
      guard certificate.count <= remaining else { return false }
      remaining -= certificate.count
    }
    return true
  }

  /// Keeps exactly one backend receive outstanding until the lifecycle ends.
  private func receiveLoop(from backend: any MacTLSTransportBackend) async {
    while isConnected {
      let read: Result<MacTLSTransportBackendRead, MacTLSTransportBackendFailure>
      do throws(MacTLSTransportBackendFailure) {
        read = .success(try await backend.receive(maximumLength: Self.maximumReceiveLength))
      } catch {
        read = .failure(error)
      }

      switch read {
      case .success(.bytes(let data)):
        guard data.count <= Self.maximumReceiveLength else {
          terminate(.failed(Self.resourceExhaustedFailure))
          return
        }
        if data.isEmpty { continue }
        let result = continuation.yield(data)
        if case .enqueued = result { continue }
        if case .terminated = result {
          terminate(.consumerGone)
          return
        }
        // `.dropped`: the finite buffer is full. Buffered chunks stay ordered.
        terminate(.failed(Self.resourceExhaustedFailure))
        return
      case .success(.endOfStream):
        terminate(.failed(Self.networkFailure(.transport(.disconnected))))
        return
      case .failure(let failure):
        // After a normal disconnect this is a no-op, so the stream stays
        // finished rather than failed.
        terminate(.failed(Self.mapped(failure, phase: .read)))
        return
      }
    }
  }

  private var isConnected: Bool {
    lock.withLock {
      if case .connected = state.phase { return true }
      return false
    }
  }

  /// FIFO send serialization: callers proceed in the order they took the lock.
  private func acquireSendSlot() async {
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      let acquired: Bool = lock.withLock {
        if case .terminated = state.phase { return true }
        guard state.sendInFlight else {
          state.sendInFlight = true
          return true
        }
        state.sendWaiters.append(waiter)
        return false
      }
      if acquired { waiter.resume() }
    }
  }

  private func releaseSendSlot() {
    let next: CheckedContinuation<Void, Never>? = lock.withLock {
      guard !state.sendWaiters.isEmpty else {
        state.sendInFlight = false
        return nil
      }
      return state.sendWaiters.removeFirst()
    }
    next?.resume()
  }

  // MARK: Failures

  /// Misuse: connect twice, or send before connecting.
  private static let misuseFailure = CoreError(
    code: .internalFailure(.preconditionFailed),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// Send after the lifecycle ended. A new transport is required.
  private static let closedFailure = CoreError(
    code: .transport(.disconnected),
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

  private static let resourceExhaustedFailure = networkFailure(.transport(.resourceExhausted))

  private static func securityFailure(_ code: SecurityErrorCode) -> CoreError {
    CoreError(
      code: .security(code),
      severity: .error,
      retryDisposition: .userActionRequired,
      cleanupDisposition: .completed
    )
  }

  private static func networkFailure(_ code: CoreErrorCode) -> CoreError {
    CoreError(
      code: code,
      severity: .error,
      retryDisposition: .backoff,
      cleanupDisposition: .completed
    )
  }

  private static func mapped(
    _ failure: MacTLSTransportBackendFailure,
    phase: TimeoutErrorCode
  ) -> CoreError {
    switch failure {
    case .unavailable: networkFailure(.transport(.unavailable))
    case .refused: networkFailure(.transport(.refused))
    case .reset: networkFailure(.transport(.reset))
    case .disconnected: networkFailure(.transport(.disconnected))
    case .timedOut: networkFailure(.timeout(phase))
    case .tlsFailure: securityFailure(.trustRejected)
    case .cancelled: cancellationFailure
    }
  }
}

// MARK: - Network.framework backend

/// Production backend over `NWConnection`.
///
/// TLS uses a verify block that extracts the peer's DER certificates in
/// platform callback order (no leaf or anchor meaning is assigned to indices) and
/// answers synchronously with the transport's decision. System trust is not
/// consulted and nothing is ever auto-accepted: an empty, unavailable, or
/// oversized chain fails the handshake. Certificate bytes are passed on and never retained.
///
/// `start` and `cancel` of the underlying connection both run on the private
/// serial queue, so a cancelled connection is never started. State lives behind
/// an `NSLock`, hence `@unchecked Sendable`. No retry and no logging.
final class MacTLSNetworkBackend: MacTLSTransportBackend, @unchecked Sendable {
  private let request: MacTLSTransportConnectionRequest
  /// A not yet started connection a TLS listener accepted; `nil` for outbound.
  private let acceptedConnection: NWConnection?
  private let queue = DispatchQueue(label: "MacPlatform.MacTLSNetworkBackend")
  private let lock = NSLock()
  private var connection: NWConnection?
  private var startContinuation:
    CheckedContinuation<Result<Void, MacTLSTransportBackendFailure>, Never>?
  private var isCancelled = false
  private var peerFinished = false

  init(request: MacTLSTransportConnectionRequest) {
    self.request = request
    acceptedConnection = nil
  }

  /// Server role: `start` starts `connection`, whose TLS parameters (local
  /// identity, no client authentication) the listener already set.
  init(acceptedConnection: NWConnection) {
    request = MacTLSTransportConnectionRequest(host: "", port: 0, security: .acceptedServer)
    self.acceptedConnection = acceptedConnection
  }

  func start(
    verifyPeer: @escaping @Sendable ([Data]) -> Bool
  ) async throws(MacTLSTransportBackendFailure) {
    let connection: NWConnection
    if request.security == .acceptedServer {
      guard let acceptedConnection else { throw .unavailable }
      connection = acceptedConnection
    } else {
      guard acceptedConnection == nil, request.port != 0,
        let port = NWEndpoint.Port(rawValue: request.port),
        Self.isUsableHost(request.host),
        let parameters = Self.parameters(
          for: request.security, verifyPeer: verifyPeer, queue: queue)
      else { throw .unavailable }
      connection = NWConnection(host: NWEndpoint.Host(request.host), port: port, using: parameters)
    }
    connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }

    let outcome: Result<Void, MacTLSTransportBackendFailure> = await withCheckedContinuation {
      continuation in
      let installed: Bool = lock.withLock {
        guard !isCancelled, self.connection == nil else { return false }
        self.connection = connection
        startContinuation = continuation
        return true
      }
      guard installed else {
        continuation.resume(returning: .failure(.cancelled))
        return
      }
      queue.async { self.startInstalledConnection() }
    }
    try outcome.get()
  }

  func send(_ data: Data) async throws(MacTLSTransportBackendFailure) {
    let connection = try activeConnection()
    let failure: MacTLSTransportBackendFailure? = await withCheckedContinuation { continuation in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          continuation.resume(returning: error.map { self.failure(for: $0) })
        }
      )
    }
    if let failure { throw failure }
  }

  func receive(
    maximumLength: Int
  ) async throws(MacTLSTransportBackendFailure) -> MacTLSTransportBackendRead {
    if lock.withLock({ peerFinished }) { return .endOfStream }
    guard maximumLength > 0 else { throw .unavailable }
    let connection = try activeConnection()

    let outcome: Result<MacTLSTransportBackendRead, MacTLSTransportBackendFailure> =
      await withCheckedContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
          content, _, isComplete, error in
          continuation.resume(
            returning: self.readOutcome(content: content, isComplete: isComplete, error: error)
          )
        }
      }
    return try outcome.get()
  }

  func cancel() {
    let (isFirstCancel, pending):
      (Bool, CheckedContinuation<Result<Void, MacTLSTransportBackendFailure>, Never>?) =
        lock.withLock {
          guard !isCancelled else { return (false, nil) }
          isCancelled = true
          defer { startContinuation = nil }
          return (true, startContinuation)
        }
    guard isFirstCancel else { return }
    pending?.resume(returning: .failure(.cancelled))
    queue.async { self.cancelInstalledConnection() }
  }

  // MARK: Connection lifecycle

  private func startInstalledConnection() {
    let connection: NWConnection? = lock.withLock { isCancelled ? nil : self.connection }
    connection?.start(queue: queue)
  }

  private func cancelInstalledConnection() {
    let connection: NWConnection? = lock.withLock { self.connection }
    connection?.cancel()
  }

  private func activeConnection() throws(MacTLSTransportBackendFailure) -> NWConnection {
    let (connection, cancelled): (NWConnection?, Bool) = lock.withLock {
      (self.connection, isCancelled)
    }
    if cancelled { throw .cancelled }
    guard let connection else { throw .unavailable }
    return connection
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      resumeStart(.success(()))
    case .waiting:
      // No retry: a connection that cannot proceed now is unavailable.
      resumeStart(.failure(.unavailable))
    case .failed(let error):
      resumeStart(.failure(failure(for: error)))
    case .cancelled:
      resumeStart(.failure(.cancelled))
    case .setup, .preparing:
      break
    @unknown default:
      break
    }
  }

  private func resumeStart(_ result: Result<Void, MacTLSTransportBackendFailure>) {
    let pending = lock.withLock {
      defer { startContinuation = nil }
      return startContinuation
    }
    pending?.resume(returning: result)
  }

  private func readOutcome(
    content: Data?,
    isComplete: Bool,
    error: NWError?
  ) -> Result<MacTLSTransportBackendRead, MacTLSTransportBackendFailure> {
    if let error { return .failure(failure(for: error)) }
    if let content, !content.isEmpty {
      if isComplete { lock.withLock { peerFinished = true } }
      return .success(.bytes(content))
    }
    return .success(isComplete ? .endOfStream : .bytes(Data()))
  }

  /// A failure after this backend was cancelled is reported as cancellation.
  private func failure(for error: NWError) -> MacTLSTransportBackendFailure {
    lock.withLock { isCancelled } ? .cancelled : Self.mapped(error)
  }

  private static func mapped(_ error: NWError) -> MacTLSTransportBackendFailure {
    switch error {
    case .posix(let code):
      switch code {
      case .ECONNREFUSED: return .refused
      case .ECONNRESET, .EPIPE: return .reset
      default: return .unavailable
      }
    case .dns, .wifiAware:
      return .unavailable
    case .tls:
      return .tlsFailure
    @unknown default:
      return .unavailable
    }
  }

  // MARK: Configuration

  private static func isUsableHost(_ host: String) -> Bool {
    !host.isEmpty
      && host.unicodeScalars.allSatisfy {
        !CharacterSet.whitespacesAndNewlines.contains($0)
          && !CharacterSet.controlCharacters.contains($0)
      }
  }

  /// Outbound parameters; `nil` for the server role, whose parameters only the
  /// listener creates.
  private static func parameters(
    for security: MacTLSTransportSecurity,
    verifyPeer: @escaping @Sendable ([Data]) -> Bool,
    queue: DispatchQueue
  ) -> NWParameters? {
    switch security {
    case .acceptedServer:
      return nil
    case .tls:
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_verify_block(
        tls.securityProtocolOptions,
        { metadata, _, complete in
          let chain = peerCertificateChain(metadata)
          let accepted = verifyPeer(chain)
          complete(accepted && !chain.isEmpty)
        },
        queue
      )
      return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    #if DEBUG
      case .debugInsecurePlaintext:
        return .tcp
    #endif
    }
  }

  /// Collects certificates in callback order inside the access call, bounded
  /// by the transport's chain limits. Once either limit is exceeded it drops
  /// everything collected and ignores further certificates, so an oversized
  /// chain is never accumulated or retained. State lives behind its own
  /// `NSLock`, hence `@unchecked Sendable`.
  private final class ChainCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var certificates: [Data] = []
    private var remainingBytes = MacTLSTransport.maximumPeerCertificateBytes
    private var exceeded = false

    var isCollecting: Bool { lock.withLock { !exceeded } }

    func append(_ certificate: Data) {
      lock.withLock {
        guard !exceeded else { return }
        guard certificates.count < MacTLSTransport.maximumPeerCertificateCount,
          certificate.count <= remainingBytes
        else {
          exceeded = true
          certificates = []
          return
        }
        remainingBytes -= certificate.count
        certificates.append(certificate)
      }
    }

    /// The collected chain, or empty when a limit was exceeded.
    var result: [Data] { lock.withLock { exceeded ? [] : certificates } }
  }

  /// The peer's DER certificates in the order the platform callback delivered
  /// them, or empty when unavailable or over the transport's chain limits. The
  /// platform documents no leaf-first ordering, so no index is treated as leaf.
  private static func peerCertificateChain(_ metadata: sec_protocol_metadata_t) -> [Data] {
    let collector = ChainCollector()
    let accessed = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
      guard collector.isCollecting else { return }
      let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
      collector.append(SecCertificateCopyData(reference) as Data)
    }
    return accessed ? collector.result : []
  }
}

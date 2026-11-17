import Crypto
import Foundation
import Glibc
import KVMContracts
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

// MARK: - Public surface

/// The injected trust evaluator's answer for a presented leaf fingerprint (C-009).
package enum LinuxTLSTrustDecision: Equatable, Sendable {
  case accept
  case reject(SecurityErrorCode)
}

/// Where a `LinuxTLSTransport` connects, and how long connect may take in total.
package struct LinuxTLSConnectionRequest: Equatable, Sendable {
  package let host: String
  package let port: UInt16
  /// Bounds the TCP connect and the TLS handshake together.
  package let connectTimeout: Duration

  package init(host: String, port: UInt16, connectTimeout: Duration) {
    self.host = host
    self.port = port
    self.connectTimeout = connectTimeout
  }
}

// MARK: - Transport

/// A single-use, TLS-only `Transport` (C-002) over swift-nio-ssl that pins the
/// server's leaf certificate (C-009).
///
/// The handshake's custom verification callback replaces chain validation: it
/// hashes the DER of the leaf certificate (the first presented certificate)
/// with SHA-256 and asks the injected evaluator once per connect. Only
/// `.accept` lets the handshake finish; every other outcome fails it, so no
/// application byte is ever sent to an unaccepted peer. The minimum protocol
/// version is TLS 1.2 and `TCP_NODELAY` is set.
///
/// State lives behind one `NSLock`, which is why the class is
/// `@unchecked Sendable`. No closure, continuation, channel call, stream yield
/// or finish runs while the lock is held. The event loop group is borrowed and
/// never shut down here.
///
/// Nothing logs. No failure carries a host, bytes, certificate material or a
/// TLS diagnostic. The presented fingerprint is kept only after a rejection,
/// for the command line to display.
package final class LinuxTLSTransport: Transport, @unchecked Sendable {
  /// Maximum number of chunks buffered for a slow consumer. A chunk is at most
  /// one TLS record (16 KiB of plaintext), so the buffer holds at most 256 KiB.
  package static let incomingChunkBufferLimit = 16

  /// Maximum number of certificates accepted in a presented chain.
  static let maximumPeerCertificateCount = 10

  package let incomingBytes: AsyncThrowingStream<Data, any Error>

  private enum Phase {
    case idle
    case connecting
    /// The handshake completed; `connect()` has not returned yet or has.
    case connected
    case terminated
  }

  private enum ConnectOutcome: Sendable {
    case ready
    case failed(CoreError)
  }

  private enum Ending {
    case finished
    case failed(CoreError)
    /// The single consumer already ended the stream.
    case consumerGone
  }

  private enum Verification {
    case notAsked
    case accepted
    case rejected(SecurityErrorCode)
  }

  private struct State {
    var phase: Phase = .idle
    var channel: (any Channel)?
    var connectWaiter: CheckedContinuation<ConnectOutcome, Never>?
    /// An outcome that arrived before the waiter was installed.
    var earlyOutcome: ConnectOutcome?
    var timeout: Scheduled<Void>?
    var verification: Verification = .notAsked
    var presentedFingerprint: Data?
  }

  private let request: LinuxTLSConnectionRequest
  private let group: any EventLoopGroup
  private let trustEvaluator: @Sendable (Data) -> LinuxTLSTrustDecision
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var state = State()

  /// `trustEvaluator` receives the 32-byte SHA-256 of the leaf DER; it must not block.
  package init(
    request: LinuxTLSConnectionRequest,
    group: any EventLoopGroup,
    trustEvaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision
  ) {
    self.request = request
    self.group = group
    self.trustEvaluator = trustEvaluator
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

  /// The leaf fingerprint the server presented, set only when the evaluator
  /// rejected it. Read by the command line to display; never logged.
  package var presentedFingerprint: Data? {
    lock.withLock { state.presentedFingerprint }
  }

  /// Whether the connected socket has `TCP_NODELAY` set; `false` when not
  /// connected. Read by tests; never needed by callers.
  package func isNoDelayEnabled() async -> Bool {
    let channel: (any Channel)? = lock.withLock {
      guard case .connected = state.phase else { return nil }
      return state.channel
    }
    guard let channel,
      let value = try? await channel.getOption(.tcpOption(.tcp_nodelay)).get()
    else { return false }
    return value != 0
  }

  // MARK: Transport

  package func connect() async throws(CoreError) {
    let claimed: Bool = lock.withLock {
      guard case .idle = state.phase else { return false }
      state.phase = .connecting
      return true
    }
    guard claimed else { throw Self.misuseFailure }

    let context: NIOSSLContext
    do {
      context = try NIOSSLContext(configuration: Self.clientConfiguration())
    } catch {
      let failure = Self.securityFailure(.trustRejected)
      terminate(.failed(failure))
      throw failure
    }

    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { (waiter: CheckedContinuation<ConnectOutcome, Never>) in
        let early: ConnectOutcome? = lock.withLock {
          if let early = state.earlyOutcome { return early }
          guard case .connecting = state.phase else { return .failed(Self.cancellationFailure) }
          state.connectWaiter = waiter
          return nil
        }
        if let early {
          waiter.resume(returning: early)
          return
        }
        start(context: context)
      }
    } onCancel: { [weak self] in
      self?.terminate(.failed(Self.cancellationFailure))
    }

    switch outcome {
    case .ready:
      return
    case .failed(let error):
      terminate(.failed(error))
      throw error
    }
  }

  package func send(_ data: Data) async throws(CoreError) {
    let current: Result<(any Channel)?, CoreError> = lock.withLock {
      switch state.phase {
      case .idle, .connecting: return .failure(Self.misuseFailure)
      case .terminated: return .failure(Self.closedFailure)
      case .connected: return .success(state.channel)
      }
    }
    let channel = try current.get()
    guard !data.isEmpty else { return }
    guard let channel else { throw Self.closedFailure }
    // `writeAndFlush` enqueues in call order on the channel's event loop; NIO
    // handles partial writes.
    do {
      try await channel.writeAndFlush(ByteBuffer(bytes: data)).get()
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

  // MARK: Connect

  private static func clientConfiguration() -> TLSConfiguration {
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.minimumTLSVersion = .tlsv12
    // The pin replaces chain and name validation (C-009): the Mac identity is
    // self-signed and names no host. The custom callback still runs for this
    // mode; only `.none` would skip it.
    configuration.certificateVerification = .noHostnameVerification
    return configuration
  }

  private func start(context: NIOSSLContext) {
    let eventLoop = group.next()
    let timeoutAmount = Self.timeAmount(request.connectTimeout)
    let scheduled = eventLoop.scheduleTask(in: timeoutAmount) { [weak self] () -> Void in
      self?.resolveConnect(.failed(Self.networkFailure(.timeout(.connect))))
    }
    let keep: Bool = lock.withLock {
      guard case .connecting = state.phase else { return false }
      state.timeout = scheduled
      return true
    }
    guard keep else {
      scheduled.cancel()
      return
    }

    let bootstrap = ClientBootstrap(group: eventLoop)
      .connectTimeout(timeoutAmount)
      .channelOption(.tcpOption(.tcp_nodelay), value: 1)
      .channelInitializer { [weak self] channel in
        channel.eventLoop.makeCompletedFuture {
          guard let self else { throw ChannelError.ioOnClosedChannel }
          let handler = try NIOSSLClientHandler(
            context: context,
            serverHostname: nil,
            customVerificationCallback: { [weak self] certificates, promise in
              guard let self else {
                promise.succeed(.failed)
                return
              }
              promise.succeed(self.verifyPeer(certificates) ? .certificateVerified : .failed)
            })
          try channel.pipeline.syncOperations.addHandler(handler)
          try channel.pipeline.syncOperations.addHandler(InboundHandler(transport: self))
        }
      }

    bootstrap.connect(host: request.host, port: Int(request.port)).whenComplete {
      [weak self] result in
      switch result {
      case .success(let channel):
        guard let self else {
          channel.close(promise: nil)
          return
        }
        let owned: Bool = self.lock.withLock {
          switch self.state.phase {
          case .connecting, .connected:
            self.state.channel = channel
            return true
          case .idle, .terminated:
            return false
          }
        }
        if !owned { channel.close(promise: nil) }
      case .failure(let error):
        self?.resolveConnect(.failed(Self.mapped(error, phase: .connect)))
      }
    }
  }

  /// Settles the pending `connect()` once. A rejection recorded by the verify
  /// callback wins over whatever failure the handshake reported.
  private func resolveConnect(_ outcome: ConnectOutcome) {
    let resolution:
      (CheckedContinuation<ConnectOutcome, Never>?, ConnectOutcome, Scheduled<Void>?)? =
        lock.withLock {
          guard case .connecting = state.phase, state.earlyOutcome == nil else { return nil }
          var settled = outcome
          if case .failed = outcome, case .rejected(let code) = state.verification {
            settled = .failed(Self.securityFailure(code))
          }
          if case .ready = settled {
            guard case .accepted = state.verification else {
              settled = .failed(Self.securityFailure(.trustRejected))
              return Self.settle(&state, settled)
            }
            state.phase = .connected
          }
          return Self.settle(&state, settled)
        }
    guard let resolution else { return }
    resolution.2?.cancel()
    resolution.0?.resume(returning: resolution.1)
  }

  private static func settle(
    _ state: inout State,
    _ outcome: ConnectOutcome
  ) -> (CheckedContinuation<ConnectOutcome, Never>?, ConnectOutcome, Scheduled<Void>?) {
    let waiter = state.connectWaiter
    state.connectWaiter = nil
    if waiter == nil { state.earlyOutcome = outcome }
    let timeout = state.timeout
    state.timeout = nil
    return (waiter, outcome, timeout)
  }

  /// The handshake verify callback. The evaluator is asked at most once per
  /// connect; a repeated callback returns the latched answer. An empty or
  /// oversized chain is rejected without asking.
  private func verifyPeer(_ certificates: [NIOSSLCertificate]) -> Bool {
    enum Step {
      case answer(Bool)
      case evaluate
    }
    let step: Step = lock.withLock {
      guard case .connecting = state.phase else { return .answer(false) }
      switch state.verification {
      case .accepted: return .answer(true)
      case .rejected: return .answer(false)
      case .notAsked: break
      }
      guard !certificates.isEmpty, certificates.count <= Self.maximumPeerCertificateCount else {
        state.verification = .rejected(.trustRejected)
        return .answer(false)
      }
      return .evaluate
    }
    if case .answer(let answer) = step { return answer }

    guard let leafDER = try? certificates[0].toDERBytes() else {
      lock.withLock {
        if case .notAsked = state.verification { state.verification = .rejected(.trustRejected) }
      }
      return false
    }
    let fingerprint = Data(SHA256.hash(data: leafDER))
    let decision = trustEvaluator(fingerprint)
    return lock.withLock {
      guard case .connecting = state.phase, case .notAsked = state.verification else {
        return false
      }
      switch decision {
      case .accept:
        state.verification = .accepted
        return true
      case .reject(let code):
        state.verification = .rejected(code)
        state.presentedFingerprint = fingerprint
        return false
      }
    }
  }

  // MARK: Channel events

  fileprivate func handshakeCompleted() {
    resolveConnect(.ready)
  }

  fileprivate func received(_ data: Data) {
    let open: Bool = lock.withLock {
      if case .connected = state.phase { return true }
      return false
    }
    guard open, !data.isEmpty else { return }
    let result = continuation.yield(data)
    if case .enqueued = result { return }
    if case .terminated = result {
      terminate(.consumerGone)
      return
    }
    // `.dropped`: the finite buffer is full. Buffered chunks stay in order.
    terminate(.failed(Self.resourceExhaustedFailure))
  }

  fileprivate func failed(_ error: any Error) {
    let connecting: Bool = lock.withLock {
      if case .connecting = state.phase { return true }
      return false
    }
    if connecting {
      resolveConnect(.failed(Self.mapped(error, phase: .connect)))
    } else {
      // After the handshake a TLS error (an unclean shutdown, a bad record) is
      // a broken connection, not a trust decision.
      let failure = Self.mapped(error, phase: .read)
      if case .security = failure.code {
        terminate(.failed(Self.networkFailure(.transport(.reset))))
      } else {
        terminate(.failed(failure))
      }
    }
  }

  /// The peer closed: before the handshake this is a failed connect; after
  /// it, a normal end of stream that finishes `incomingBytes` once.
  fileprivate func closed() {
    let connecting: Bool = lock.withLock {
      if case .connecting = state.phase { return true }
      return false
    }
    if connecting {
      resolveConnect(.failed(Self.networkFailure(.transport(.disconnected))))
    } else {
      terminate(.finished)
    }
  }

  // MARK: Lifecycle

  /// Moves to the terminal state exactly once: settles a pending connect with
  /// cancellation, cancels the timeout, closes the channel and ends the
  /// stream. Returns `false` when the lifecycle had already ended.
  @discardableResult
  private func terminate(_ ending: Ending) -> Bool {
    let released:
      (
        channel: (any Channel)?,
        waiter: CheckedContinuation<ConnectOutcome, Never>?,
        timeout: Scheduled<Void>?
      )? = lock.withLock {
        if case .terminated = state.phase { return nil }
        state.phase = .terminated
        let released = (state.channel, state.connectWaiter, state.timeout)
        state.channel = nil
        state.connectWaiter = nil
        state.timeout = nil
        if released.1 == nil, state.earlyOutcome == nil {
          state.earlyOutcome = .failed(Self.cancellationFailure)
        }
        return released
      }
    guard let released else { return false }

    released.timeout?.cancel()
    released.channel?.close(promise: nil)
    released.waiter?.resume(returning: .failed(Self.cancellationFailure))
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

  /// Strips NIO and TLS errors to a typed code. TLS failures are security
  /// failures: the connection is never downgraded or retried without trust.
  private static func mapped(_ error: any Error, phase: TimeoutErrorCode) -> CoreError {
    if let error = error as? CoreError { return error }
    if error is NIOSSLError || error is BoringSSLError || error is NIOSSLExtraError {
      return securityFailure(.trustRejected)
    }
    if let error = error as? ChannelError {
      switch error {
      case .connectTimeout: return networkFailure(.timeout(phase))
      default: return networkFailure(.transport(.disconnected))
      }
    }
    if let error = error as? NIOConnectionError {
      let errnos = error.connectionErrors.compactMap { ($0.error as? IOError)?.errnoCode }
      if errnos.contains(ECONNREFUSED) { return networkFailure(.transport(.refused)) }
      return networkFailure(.transport(.unavailable))
    }
    if let error = error as? IOError {
      switch error.errnoCode {
      case ECONNREFUSED: return networkFailure(.transport(.refused))
      case ECONNRESET, EPIPE: return networkFailure(.transport(.reset))
      case ETIMEDOUT: return networkFailure(.timeout(phase))
      default: return networkFailure(.transport(.unavailable))
      }
    }
    return networkFailure(.transport(.unavailable))
  }

  private static func timeAmount(_ duration: Duration) -> TimeAmount {
    let (seconds, attoseconds) = duration.components
    guard seconds >= 0 else { return .nanoseconds(0) }
    let capped = min(seconds, 86_400)
    return .nanoseconds(capped * 1_000_000_000 + attoseconds / 1_000_000_000)
  }
}

// MARK: - Channel handler

/// Forwards handshake completion, plaintext reads, errors and closure to the
/// transport. Holds the transport weakly so a dropped transport closes cleanly.
private final class InboundHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer

  private weak var transport: LinuxTLSTransport?

  init(transport: LinuxTLSTransport) {
    self.transport = transport
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case .handshakeCompleted = event as? TLSUserEvent {
      transport?.handshakeCompleted()
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let buffer = unwrapInboundIn(data)
    transport?.received(Data(buffer.readableBytesView))
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    transport?.failed(error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    transport?.closed()
    context.fireChannelInactive()
  }
}

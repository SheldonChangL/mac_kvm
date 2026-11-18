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
/// Inbound flow control (M1-055-FOLLOWUP-002): `incomingBytes` is pull-driven.
/// Decrypted bytes wait in a byte-counted queue; once it holds
/// `inboundHighWaterBytes` the channel stops issuing socket reads (the read
/// event is held, so TCP flow control pushes back on the peer), and reading
/// resumes when the consumer drains it below `inboundLowWaterBytes`. The gate
/// cannot stop a read event already under way (NIO's `maxMessagesPerRead`, 4 by
/// default, of up to 64 KiB each) nor reads NIOSSL issues itself, so the queue
/// can pass the high-water mark by a few hundred KiB (tests pin it under
/// high water + 512 KiB); `maximumBufferedBytes` is a hard ceiling that ends
/// the stream with `resourceExhausted` rather than grow without bound. The
/// ceiling counts payload bytes only, not per-chunk overhead.
///
/// Leaving the `for try await` loop over `incomingBytes` without cancelling
/// does not end the lifecycle: the connection stays open with reads paused
/// once the queue fills, until `disconnect()`. Only cancelling the consuming
/// task ends it. The transport has no read timeout; a silent peer is bounded
/// by the client protocol session's keepalive timeout.
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
  /// Queued bytes at which socket reads pause until the consumer catches up.
  package static let inboundHighWaterBytes = 256 * 1024

  /// Queued bytes below which paused socket reads resume.
  package static let inboundLowWaterBytes = 64 * 1024

  /// Hard ceiling on queued bytes. Reaching it ends the stream with
  /// `resourceExhausted`; with reads paused at the high-water mark, an honest
  /// peer cannot reach it (one socket read is far smaller than the margin).
  package static let maximumBufferedBytes = 1024 * 1024

  /// Maximum size of one yielded chunk. A NIOSSL read can carry several TLS
  /// records, so larger reads are split.
  package static let maximumChunkLength = 16_384

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

  private enum Ending: Sendable {
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
    /// Decrypted chunks the consumer has not taken yet, and their total size.
    var queue = CircularBuffer<Data>()
    var queuedBytes = 0
    var peakQueuedBytes = 0
    /// Set while socket reads are held back for the consumer.
    var readsPaused = false
    var inbound: InboundHandler?
    /// The single consumer, waiting for a chunk or the end.
    var consumerWaiter: CheckedContinuation<Data?, any Error>?
    /// How the stream ends once the queue is drained; delivered once.
    var ending: Ending?
    var endingDelivered = false
  }

  private let request: LinuxTLSConnectionRequest
  private let group: any EventLoopGroup
  private let trustEvaluator: @Sendable (Data) -> LinuxTLSTrustDecision
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
    let source = PullSource()
    incomingBytes = AsyncThrowingStream(unfolding: { try await source.transport?.nextChunk() })
    source.transport = self
  }

  /// Bytes queued for the consumer now. Read by tests; never needed by callers.
  package var bufferedByteCount: Int { lock.withLock { state.queuedBytes } }

  /// The most bytes ever queued at once. Read by tests; never needed by callers.
  package var peakBufferedByteCount: Int { lock.withLock { state.peakQueuedBytes } }

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
          let inbound = InboundHandler(transport: self)
          self.lock.withLock { self.state.inbound = inbound }
          try channel.pipeline.syncOperations.addHandler(inbound)
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
        // Ordering: the connect promise completes on the channel's own event
        // loop when the TCP connect finishes, and this callback runs there and
        // then. The handshake needs further round trips on that same loop, so
        // the channel is always stored before `.connected` can be reached and
        // before `send` can look for it.
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

  /// Queues decrypted bytes for the consumer, split into chunks of at most
  /// `maximumChunkLength`, and hands the first one to a waiting consumer.
  /// Runs on the channel's event loop.
  fileprivate func received(_ data: Data) {
    guard !data.isEmpty else { return }
    enum Outcome {
      case ignored
      case queued(CheckedContinuation<Data?, any Error>?, Data?)
      case exhausted
    }
    let outcome: Outcome = lock.withLock {
      guard case .connected = state.phase else { return .ignored }
      guard state.queuedBytes + data.count <= Self.maximumBufferedBytes else { return .exhausted }
      var offset = data.startIndex
      while offset < data.endIndex {
        let end =
          data.index(offset, offsetBy: Self.maximumChunkLength, limitedBy: data.endIndex)
          ?? data.endIndex
        state.queue.append(data.subdata(in: offset..<end))
        offset = end
      }
      state.queuedBytes += data.count
      state.peakQueuedBytes = max(state.peakQueuedBytes, state.queuedBytes)
      var handed: Data?
      let waiter = state.consumerWaiter
      if waiter != nil {
        state.consumerWaiter = nil
        handed = Self.dequeue(&state)
      }
      if state.queuedBytes >= Self.inboundHighWaterBytes { state.readsPaused = true }
      return .queued(waiter, handed)
    }
    switch outcome {
    case .ignored:
      return
    case .exhausted:
      terminate(.failed(Self.resourceExhaustedFailure))
    case .queued(let waiter, let chunk):
      waiter?.resume(returning: chunk)
    }
  }

  /// Whether the channel should hold back its next socket read.
  fileprivate var readsPaused: Bool {
    lock.withLock { state.readsPaused }
  }

  /// Takes the oldest chunk off the queue. Called with the lock held.
  private static func dequeue(_ state: inout State) -> Data? {
    guard let chunk = state.queue.popFirst() else { return nil }
    state.queuedBytes -= chunk.count
    return chunk
  }

  /// Resumes held reads once the queue is below the low-water mark. Called
  /// with the lock held; returns the handler and channel to resume, if any.
  private static func resumption(
    _ state: inout State
  ) -> (InboundHandler, any Channel)? {
    guard state.readsPaused, state.queuedBytes < Self.inboundLowWaterBytes,
      let inbound = state.inbound, let channel = state.channel
    else { return nil }
    state.readsPaused = false
    return (inbound, channel)
  }

  /// The pull behind `incomingBytes`: the next chunk, or the end once the
  /// queue is drained. A second concurrent consumer is refused.
  fileprivate func nextChunk() async throws -> Data? {
    enum Step {
      case chunk(Data, (InboundHandler, any Channel)?)
      case end(Ending?)
      case wait
      case misuse
    }
    let step: Step = lock.withLock {
      if let chunk = Self.dequeue(&state) { return .chunk(chunk, Self.resumption(&state)) }
      if let ending = state.ending {
        if state.endingDelivered { return .end(nil) }
        state.endingDelivered = true
        return .end(ending)
      }
      if state.consumerWaiter != nil { return .misuse }
      return .wait
    }
    switch step {
    case .chunk(let chunk, let resume):
      if let (inbound, channel) = resume {
        channel.eventLoop.execute { inbound.resumeReading() }
      }
      return chunk
    case .end(let ending):
      return try Self.deliver(ending)
    case .misuse:
      throw Self.misuseFailure
    case .wait:
      break
    }

    let next: Data? = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Data?, any Error>) in
        enum Install {
          case installed
          case chunk(Data)
          case end(Ending?)
          case cancelled
        }
        let install: Install = lock.withLock {
          if let chunk = Self.dequeue(&state) { return .chunk(chunk) }
          if let ending = state.ending {
            if state.endingDelivered { return .end(nil) }
            state.endingDelivered = true
            return .end(ending)
          }
          if Task.isCancelled { return .cancelled }
          state.consumerWaiter = waiter
          return .installed
        }
        switch install {
        case .installed:
          return
        case .chunk(let chunk):
          waiter.resume(returning: chunk)
        case .end(let ending):
          waiter.resume(with: Result { try Self.deliver(ending) })
        case .cancelled:
          terminate(.consumerGone)
          waiter.resume(returning: nil)
        }
      }
    } onCancel: { [weak self] in
      self?.consumerCancelled()
    }
    // A chunk handed straight from `received` may have left the queue low.
    let resume = lock.withLock { Self.resumption(&state) }
    if let (inbound, channel) = resume {
      channel.eventLoop.execute { inbound.resumeReading() }
    }
    return next
  }

  /// The consumer's task was cancelled: it is gone, so the lifecycle ends.
  private func consumerCancelled() {
    let waiter: CheckedContinuation<Data?, any Error>? = lock.withLock {
      defer { state.consumerWaiter = nil }
      return state.consumerWaiter
    }
    terminate(.consumerGone)
    waiter?.resume(returning: nil)
  }

  private static func deliver(_ ending: Ending?) throws -> Data? {
    switch ending {
    case .failed(let error)?: throw error
    case .finished?, .consumerGone?, nil: return nil
    }
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
  /// it, a normal end of stream that finishes `incomingBytes` once. Only a
  /// close that sent `close_notify` ends cleanly; a bare TCP FIN after the
  /// handshake is reported by NIOSSL as an unclean shutdown error first, which
  /// `failed` maps to `transport(.reset)`.
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
    var consumer: CheckedContinuation<Data?, any Error>?
    let released:
      (
        channel: (any Channel)?,
        waiter: CheckedContinuation<ConnectOutcome, Never>?,
        timeout: Scheduled<Void>?
      )? = lock.withLock {
        if case .terminated = state.phase { return nil }
        state.phase = .terminated
        let released = (state.channel, state.connectWaiter, state.timeout)
        state.ending = ending
        if case .consumerGone = ending {
          state.queue.removeAll()
          state.queuedBytes = 0
        }
        // A waiting consumer implies an empty queue: it gets the end now.
        consumer = state.consumerWaiter
        state.consumerWaiter = nil
        if consumer != nil { state.endingDelivered = true }
        state.inbound = nil
        state.readsPaused = false
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
    consumer?.resume(with: Result { try Self.deliver(ending) })
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

/// Lets the pull closure reach the transport, which does not exist yet when
/// the stream is made. Written once in `init`, before the stream is shared.
private final class PullSource: @unchecked Sendable {
  weak var transport: LinuxTLSTransport?
}

// MARK: - Channel handler

/// Forwards handshake completion, plaintext reads, errors and closure to the
/// transport. Holds the transport weakly so a dropped transport closes cleanly.
///
/// It is also the read gate: it sits after the TLS handler, so a `read` it
/// holds back never reaches the socket. While the transport's queue is above
/// the high-water mark the read is held; `resumeReading` re-issues it. Its own
/// state is touched only on the channel's event loop.
private final class InboundHandler: ChannelDuplexHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias OutboundIn = Never

  private weak var transport: LinuxTLSTransport?
  private var context: ChannelHandlerContext?
  private var heldRead = false

  init(transport: LinuxTLSTransport) {
    self.transport = transport
  }

  func handlerAdded(context: ChannelHandlerContext) { self.context = context }

  func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

  func read(context: ChannelHandlerContext) {
    if transport?.readsPaused == true {
      heldRead = true
      return
    }
    context.read()
  }

  /// Runs on the event loop once the consumer drained the queue.
  func resumeReading() {
    guard heldRead, let context, transport?.readsPaused != true else { return }
    heldRead = false
    context.read()
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

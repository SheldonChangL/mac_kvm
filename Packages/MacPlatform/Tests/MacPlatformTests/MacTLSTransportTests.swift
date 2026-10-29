import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

// MARK: - Expected internal surface
//
// These tests drive `MacTLSTransport` through a small internal seam. Nothing
// below is public; the frozen `Transport` contract is the only public shape.
//
//   struct MacTLSTransportConnectionRequest: Equatable, Sendable
//     { host: String; port: UInt16; security: MacTLSTransportSecurity }
//   enum MacTLSTransportSecurity: Equatable, Sendable
//     { case tls; DEBUG-only: case debugInsecurePlaintext }
//   enum MacTLSTrustDecision: Equatable, Sendable
//     { case accept; case reject(SecurityErrorCode) }
//   enum MacTLSTransportBackendFailure: Error, Equatable, Sendable
//     { unavailable, refused, reset, disconnected, timedOut, tlsFailure, cancelled }
//   enum MacTLSTransportBackendRead: Equatable, Sendable
//     { case bytes(Data); case endOfStream }
//   protocol MacTLSTransportBackend: Sendable {
//     func start(verifyPeer: @escaping @Sendable ([Data]) -> Bool)
//       async throws(MacTLSTransportBackendFailure)
//     func send(_ data: Data) async throws(MacTLSTransportBackendFailure)
//     func receive(maximumLength: Int)
//       async throws(MacTLSTransportBackendFailure) -> MacTLSTransportBackendRead
//     func cancel()
//   }
//   final class MacTLSTransport: Transport {
//     init(host:port:trustEvaluator:backendFactory:)
//     static let maximumReceiveLength: Int        // 64 KiB
//     static let incomingChunkBufferLimit: Int    // finite chunk buffer
//     static let maximumPeerCertificateCount: Int // 10
//     static let maximumPeerCertificateBytes: Int // 256 KiB, whole chain
//     DEBUG-only: static func debugInsecurePlaintext(host:port:backendFactory:)
//   }
//
// `verifyPeer` models the Network.framework TLS verify block: the backend hands
// the DER certificates, in platform callback order, to the transport during
// the handshake, before the connection is ready, and fails the handshake with
// `.tlsFailure` when the
// transport answers `false`. `SecProtocolOptions.h` allows the verify block to
// run one or more times per connection, so the transport must evaluate every
// presented chain, once per callback.

// MARK: - Deterministic seam recording

/// One observed call into the substituted backend or trust evaluator, in the
/// order it happened.
private enum BackendEvent: Equatable {
  case start
  case evaluate([Data])
  case ready
  case receive(maximumLength: Int)
  case send(Data)
  case cancel
}

/// How the fake backend's `start` behaves.
private enum FakeStartScript {
  /// Completes a TLS handshake that presents `chain` to the verify callback.
  case presentChain([Data])
  /// Invokes the verify callback once per chain, in order, then reports ready
  /// only if every callback answered `true`.
  case presentChains([[Data]])
  /// Reports ready without ever invoking the verify callback.
  case readyWithoutVerification
  /// Fails before any certificate is presented.
  case fail(MacTLSTransportBackendFailure)
  /// Stays pending until `cancel()` is called.
  case suspendUntilCancelled
}

private typealias ReadResult = Result<MacTLSTransportBackendRead, MacTLSTransportBackendFailure>
private typealias StartResult = Result<Void, MacTLSTransportBackendFailure>

private struct FakeBackendState {
  var startScript: FakeStartScript
  var events: [BackendEvent] = []
  var requests: [MacTLSTransportConnectionRequest] = []
  var queuedReads: [ReadResult] = []
  var pendingReceive: CheckedContinuation<ReadResult, Never>?
  var pendingStart: CheckedContinuation<StartResult, Never>?
  var sendFailures: [MacTLSTransportBackendFailure] = []
  var scriptedDecisions: [MacTLSTrustDecision] = []
  var isCancelled = false
}

/// An in-memory backend that every test uses instead of Network.framework.
///
/// No test opens a socket, sleeps, or reads a clock. A test waits for the
/// transport's background work with `waitUntil`, which resumes as soon as the
/// recorded event log satisfies a condition.
///
/// The seam is `Sendable`, so the fake is lock-guarded and
/// `@unchecked Sendable`. macOS 14 is the platform floor, so `NSLock` is used
/// rather than `Synchronization.Mutex`. Continuations and callbacks are always
/// resumed or invoked outside the lock.
private final class FakeTLSBackend: MacTLSTransportBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var state: FakeBackendState
  private var waiters:
    [(
      condition: @Sendable ([BackendEvent]) -> Bool,
      continuation: CheckedContinuation<Void, Never>
    )] = []

  init(start: FakeStartScript = .presentChain(presentedChain)) {
    state = FakeBackendState(startScript: start)
  }

  var events: [BackendEvent] { lock.withLock { state.events } }
  var requests: [MacTLSTransportConnectionRequest] { lock.withLock { state.requests } }
  var cancelCount: Int { events.filter { $0 == .cancel }.count }
  var evaluations: [[Data]] {
    events.compactMap { if case .evaluate(let chain) = $0 { chain } else { nil } }
  }
  var sentPayloads: [Data] {
    events.compactMap { if case .send(let data) = $0 { data } else { nil } }
  }
  var receiveLengths: [Int] {
    events.compactMap { if case .receive(let length) = $0 { length } else { nil } }
  }

  /// The factory handed to the transport. It records each request and returns
  /// this fake.
  var factory: @Sendable (MacTLSTransportConnectionRequest) -> any MacTLSTransportBackend {
    { request in
      self.mutate { $0.requests.append(request) }
      return self
    }
  }

  /// A trust evaluator that records the chain it sees, then answers `decision`.
  func evaluator(
    returning decision: MacTLSTrustDecision
  ) -> @Sendable ([Data]) -> MacTLSTrustDecision {
    { chain in
      self.mutate { $0.events.append(.evaluate(chain)) }
      return decision
    }
  }

  /// A trust evaluator that records each chain it sees and answers the next
  /// scripted decision, one per callback. A callback beyond the script is
  /// rejected.
  func evaluator(
    answering decisions: [MacTLSTrustDecision]
  ) -> @Sendable ([Data]) -> MacTLSTrustDecision {
    mutate { $0.scriptedDecisions = decisions }
    return { chain in
      self.mutate { state in
        state.events.append(.evaluate(chain))
        guard !state.scriptedDecisions.isEmpty else { return .reject(.trustRejected) }
        return state.scriptedDecisions.removeFirst()
      }
    }
  }

  /// Completes the pending receive, or queues the result for the next one.
  func deliver(_ result: ReadResult) {
    let pending: CheckedContinuation<ReadResult, Never>? = mutate { state in
      if let pending = state.pendingReceive {
        state.pendingReceive = nil
        return pending
      }
      state.queuedReads.append(result)
      return nil
    }
    pending?.resume(returning: result)
  }

  func failNextSend(_ failure: MacTLSTransportBackendFailure) {
    mutate { $0.sendFailures.append(failure) }
  }

  /// Suspends until the event log satisfies `condition`.
  func waitUntil(_ condition: @escaping @Sendable ([BackendEvent]) -> Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let satisfied: Bool = lock.withLock {
        if condition(state.events) { return true }
        waiters.append((condition, continuation))
        return false
      }
      if satisfied { continuation.resume() }
    }
  }

  func waitForCancel() async {
    await waitUntil { $0.contains(.cancel) }
  }

  func waitForReceive(count: Int = 1) async {
    await waitUntil { events in
      events.filter { if case .receive = $0 { true } else { false } }.count >= count
    }
  }

  // MARK: MacTLSTransportBackend

  func start(
    verifyPeer: @escaping @Sendable ([Data]) -> Bool
  ) async throws(MacTLSTransportBackendFailure) {
    let script: FakeStartScript = mutate { state in
      state.events.append(.start)
      return state.startScript
    }
    switch script {
    case .presentChain(let chain):
      // Invoked outside the lock: the evaluator records into this same fake.
      guard verifyPeer(chain) else { throw MacTLSTransportBackendFailure.tlsFailure }
      mutate { $0.events.append(.ready) }
    case .presentChains(let chains):
      // Each callback runs outside the lock and must answer before the next.
      for chain in chains {
        guard verifyPeer(chain) else { throw MacTLSTransportBackendFailure.tlsFailure }
      }
      mutate { $0.events.append(.ready) }
    case .readyWithoutVerification:
      mutate { $0.events.append(.ready) }
    case .fail(let failure):
      throw failure
    case .suspendUntilCancelled:
      let outcome: StartResult = await withCheckedContinuation { continuation in
        let immediate: StartResult? = mutate { state in
          if state.isCancelled { return .failure(.cancelled) }
          state.pendingStart = continuation
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
      try outcome.get()
    }
  }

  func send(_ data: Data) async throws(MacTLSTransportBackendFailure) {
    let outcome: StartResult = mutate { state in
      state.events.append(.send(data))
      if state.isCancelled { return .failure(.cancelled) }
      if !state.sendFailures.isEmpty { return .failure(state.sendFailures.removeFirst()) }
      return .success(())
    }
    try outcome.get()
  }

  func receive(
    maximumLength: Int
  ) async throws(MacTLSTransportBackendFailure) -> MacTLSTransportBackendRead {
    let outcome: ReadResult = await withCheckedContinuation { continuation in
      let immediate: ReadResult? = mutate { state in
        state.events.append(.receive(maximumLength: maximumLength))
        if state.isCancelled { return .failure(.cancelled) }
        if !state.queuedReads.isEmpty { return state.queuedReads.removeFirst() }
        state.pendingReceive = continuation
        return nil
      }
      if let immediate { continuation.resume(returning: immediate) }
    }
    return try outcome.get()
  }

  func cancel() {
    let pending:
      (
        start: CheckedContinuation<StartResult, Never>?,
        receive: CheckedContinuation<ReadResult, Never>?
      ) =
        mutate { state in
          state.events.append(.cancel)
          state.isCancelled = true
          defer {
            state.pendingStart = nil
            state.pendingReceive = nil
          }
          return (state.pendingStart, state.pendingReceive)
        }
    pending.start?.resume(returning: .failure(.cancelled))
    pending.receive?.resume(returning: .failure(.cancelled))
  }

  // MARK: Locking

  /// Mutates state under the lock, then resumes every waiter whose condition
  /// now holds, outside the lock.
  @discardableResult
  private func mutate<T>(_ body: (inout FakeBackendState) -> T) -> T {
    let (value, satisfied): (T, [CheckedContinuation<Void, Never>]) = lock.withLock {
      let value = body(&state)
      var satisfied: [CheckedContinuation<Void, Never>] = []
      waiters.removeAll { waiter in
        guard waiter.condition(state.events) else { return false }
        satisfied.append(waiter.continuation)
        return true
      }
      return (value, satisfied)
    }
    for continuation in satisfied { continuation.resume() }
    return value
  }
}

// MARK: - Fixtures and helpers

private let peerHost = "kvm-peer.invalid"
private let peerPort: UInt16 = 24_800

/// Synthetic DER-shaped certificates as one verify callback presents them. They
/// are never parsed and no index carries leaf or anchor meaning; the tests only
/// prove the transport forwards them unchanged and in the presented order.
private let presentedChain = [
  Data([0x30, 0x03, 0x02, 0x01, 0x01]),
  Data([0x30, 0x03, 0x02, 0x01, 0x02]),
  Data([0x30, 0x03, 0x02, 0x01, 0x03]),
]

/// A second, distinct chain presented by a later verify callback.
private let secondPresentedChain = [
  Data([0x30, 0x03, 0x02, 0x01, 0x04]),
  Data([0x30, 0x03, 0x02, 0x01, 0x05]),
]

/// A deterministic chain of `count` distinct certificates whose sizes sum to
/// exactly `totalBytes`. Any remainder goes to element zero.
private func chain(count: Int, totalBytes: Int) -> [Data] {
  precondition(count > 0 && totalBytes >= count)
  let base = totalBytes / count
  let remainder = totalBytes % count
  return (0..<count).map { index in
    Data(
      repeating: UInt8(truncatingIfNeeded: index + 1),
      count: base + (index == 0 ? remainder : 0)
    )
  }
}

/// Private-looking payload that must never reach an error rendering.
private let secretPayload = Data("OPAL-WALRUS-7731".utf8)

private func makeTransport(
  _ backend: FakeTLSBackend,
  decision: MacTLSTrustDecision = .accept
) -> MacTLSTransport {
  MacTLSTransport(
    host: peerHost,
    port: peerPort,
    trustEvaluator: backend.evaluator(returning: decision),
    backendFactory: backend.factory
  )
}

private func connectFailure(_ transport: MacTLSTransport) async -> CoreError? {
  do {
    try await transport.connect()
    return nil
  } catch {
    return error
  }
}

private func sendFailure(_ transport: MacTLSTransport, _ data: Data) async -> CoreError? {
  do {
    try await transport.send(data)
    return nil
  } catch {
    return error
  }
}

/// A connected transport. No iterator is created here: discarding a stream
/// iterator ends the stream, so each test that reads keeps its own iterator in
/// use until its final assertion.
private func connected(_ backend: FakeTLSBackend) async throws -> MacTLSTransport {
  let transport = makeTransport(backend)
  try await transport.connect()
  return transport
}

private enum StreamEnd: Equatable {
  case finished
  case failed(CoreError)
  case failedWithNonCoreError
}

/// Reads until the stream terminates.
private func drain(
  _ iterator: inout AsyncThrowingStream<Data, any Error>.Iterator
) async -> (chunks: [Data], end: StreamEnd) {
  var chunks: [Data] = []
  do {
    while let chunk = try await iterator.next() {
      chunks.append(chunk)
    }
    return (chunks, .finished)
  } catch let error as CoreError {
    return (chunks, .failed(error))
  } catch {
    return (chunks, .failedWithNonCoreError)
  }
}

/// A terminated stream stays terminated: no further element and no second
/// terminal error.
private func expectStaysTerminated(
  _ iterator: inout AsyncThrowingStream<Data, any Error>.Iterator
) async {
  do {
    let next = try await iterator.next()
    #expect(next == nil, "the stream yielded after terminating")
  } catch {
    Issue.record("the stream delivered a second terminal error")
  }
}

private func chunk(_ index: Int) -> Data {
  Data([UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)])
}

// MARK: - Expected failure shapes

private func securityFailure(_ code: SecurityErrorCode) -> CoreError {
  CoreError(
    code: .security(code),
    severity: .error,
    retryDisposition: .userActionRequired,
    cleanupDisposition: .completed
  )
}

private let misuseFailure = CoreError(
  code: .internalFailure(.preconditionFailed),
  severity: .error,
  retryDisposition: .never,
  cleanupDisposition: .notRequired
)

private func expectCode(
  _ error: CoreError?,
  _ code: CoreErrorCode,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(error?.code == code, sourceLocation: sourceLocation)
  #expect(error?.underlyingDiagnosticCode == nil, sourceLocation: sourceLocation)
}

private func expectStreamFailed(
  _ end: StreamEnd,
  _ code: CoreErrorCode,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard case .failed(let error) = end else {
    Issue.record("expected the stream to fail with \(code)", sourceLocation: sourceLocation)
    return
  }
  expectCode(error, code, sourceLocation: sourceLocation)
}

/// Internal rather than private only because parameterized test functions
/// cannot take a private parameter type.
struct MacTLSTransportFailureMapping: Sendable, CustomTestStringConvertible {
  let failure: MacTLSTransportBackendFailure
  let code: CoreErrorCode
  var testDescription: String { "\(failure) -> \(code)" }
}

private let connectMacTLSTransportFailureMappings = [
  MacTLSTransportFailureMapping(failure: .unavailable, code: .transport(.unavailable)),
  MacTLSTransportFailureMapping(failure: .refused, code: .transport(.refused)),
  MacTLSTransportFailureMapping(failure: .reset, code: .transport(.reset)),
  MacTLSTransportFailureMapping(failure: .disconnected, code: .transport(.disconnected)),
  MacTLSTransportFailureMapping(failure: .timedOut, code: .timeout(.connect)),
  MacTLSTransportFailureMapping(failure: .tlsFailure, code: .security(.trustRejected)),
  MacTLSTransportFailureMapping(failure: .cancelled, code: .cancellation(.requested)),
]

private let sendMacTLSTransportFailureMappings = [
  MacTLSTransportFailureMapping(failure: .unavailable, code: .transport(.unavailable)),
  MacTLSTransportFailureMapping(failure: .reset, code: .transport(.reset)),
  MacTLSTransportFailureMapping(failure: .disconnected, code: .transport(.disconnected)),
  MacTLSTransportFailureMapping(failure: .timedOut, code: .timeout(.write)),
]

private let receiveMacTLSTransportFailureMappings = [
  MacTLSTransportFailureMapping(failure: .unavailable, code: .transport(.unavailable)),
  MacTLSTransportFailureMapping(failure: .reset, code: .transport(.reset)),
  MacTLSTransportFailureMapping(failure: .disconnected, code: .transport(.disconnected)),
  MacTLSTransportFailureMapping(failure: .timedOut, code: .timeout(.read)),
]

// MARK: - TLS by default

@Test func tlsTransportConformsToTheFrozenTransportContract() {
  let transport: any Transport = makeTransport(FakeTLSBackend())
  #expect(transport is MacTLSTransport)
}

@Test func tlsTransportRequestsTLSForTheConfiguredPeerOnlyWhenConnecting() async throws {
  let backend = FakeTLSBackend()
  let transport = makeTransport(backend)
  #expect(backend.requests.isEmpty, "no backend may exist before connect")

  try await transport.connect()

  #expect(
    backend.requests == [
      MacTLSTransportConnectionRequest(host: peerHost, port: peerPort, security: .tls)
    ]
  )
  await transport.disconnect()
}

/// Static source audit of the production file. **It proves what the source
/// names, not what runs.** Every non-comment line naming plaintext or insecure
/// transport must sit inside an active `#if DEBUG` branch, so a release build
/// cannot even express a plaintext request.
@Test func tlsTransportPlaintextSelectionExistsOnlyInsideDebugBuilds() throws {
  let productionFile = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/MacPlatform/MacTLSTransport.swift")
  let source = try String(contentsOf: productionFile, encoding: .utf8)
  #expect(source.contains("#if DEBUG"))

  // One entry per open `#if`: `true` while inside the `#if DEBUG` branch.
  var conditions: [Bool] = []
  for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("#if ") {
      conditions.append(line == "#if DEBUG")
    } else if line.hasPrefix("#elseif") || line == "#else" {
      if !conditions.isEmpty { conditions[conditions.count - 1] = false }
    } else if line.hasPrefix("#endif") {
      _ = conditions.popLast()
    } else if !line.hasPrefix("//") {
      let lowered = line.lowercased()
      if lowered.contains("plaintext") || lowered.contains("insecure") {
        #expect(conditions.contains(true), "release code names plaintext: \(line)")
      }
    }
  }
  #expect(conditions.isEmpty, "unbalanced conditional compilation")
}

#if DEBUG
  @Test func debugPlaintextSelectionIsExplicitAndRequestsPlaintext() async throws {
    let backend = FakeTLSBackend(start: .readyWithoutVerification)
    let transport = MacTLSTransport.debugInsecurePlaintext(
      host: peerHost,
      port: peerPort,
      backendFactory: backend.factory
    )

    try await transport.connect()

    #expect(
      backend.requests == [
        MacTLSTransportConnectionRequest(
          host: peerHost,
          port: peerPort,
          security: .debugInsecurePlaintext
        )
      ]
    )
    #expect(backend.evaluations.isEmpty)
    await transport.disconnect()
  }
#endif

// MARK: - Trust evaluation

@Test func tlsTransportPassesThePresentedChainToTheEvaluatorExactlyOnceBeforeReady() async throws {
  let backend = FakeTLSBackend(start: .presentChain(presentedChain))
  let transport = try await connected(backend)
  await backend.waitForReceive()

  #expect(backend.evaluations == [presentedChain])
  #expect(
    backend.events == [
      .start,
      .evaluate(presentedChain),
      .ready,
      .receive(maximumLength: 65_536),
    ]
  )
  await transport.disconnect()
}

@Test(arguments: SecurityErrorCode.allCases)
func tlsTransportEvaluatorRejectionFailsClosedWithTheExactSecurityError(
  code: SecurityErrorCode
) async {
  let backend = FakeTLSBackend(start: .presentChain(presentedChain))
  let transport = makeTransport(backend, decision: .reject(code))
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  #expect(error == securityFailure(code))
  #expect(backend.evaluations == [presentedChain])
  #expect(!backend.events.contains(.ready))
  #expect(backend.receiveLengths.isEmpty)
  #expect(backend.cancelCount == 1)

  let outcome = await drain(&iterator)
  #expect(outcome.chunks.isEmpty)
  #expect(outcome.end == .failed(securityFailure(code)))
  await expectStaysTerminated(&iterator)
}

/// A changed identity is reported as exactly that, never folded into a generic
/// rejection, so the caller can require re-pairing instead of retrying.
@Test func tlsTransportIdentityChangeIsDistinctFromTrustRejection() async {
  let changed = await connectFailure(
    makeTransport(FakeTLSBackend(), decision: .reject(.identityChanged))
  )
  let rejected = await connectFailure(
    makeTransport(FakeTLSBackend(), decision: .reject(.trustRejected))
  )

  #expect(changed == securityFailure(.identityChanged))
  #expect(rejected == securityFailure(.trustRejected))
  #expect(changed != rejected)
}

@Test func tlsTransportEmptyCertificateChainFailsClosedWithoutConsultingTheEvaluator() async {
  let backend = FakeTLSBackend(start: .presentChain([]))
  let transport = makeTransport(backend, decision: .accept)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  #expect(error == securityFailure(.trustRejected))
  #expect(backend.evaluations.isEmpty, "an accepting evaluator must not see an empty chain")
  #expect(!backend.events.contains(.ready))
  #expect(backend.cancelCount == 1)
  #expect(await drain(&iterator).end == .failed(securityFailure(.trustRejected)))
}

// MARK: - Repeated verify callbacks

/// The verify block may run more than once per connection. Every presented
/// chain reaches the evaluator once per callback, in callback order (this is
/// the order of callbacks, not of certificates within a chain).
@Test func tlsTransportEvaluatesEveryVerifyCallbackOnceInOrder() async throws {
  let backend = FakeTLSBackend(start: .presentChains([presentedChain, secondPresentedChain]))
  let transport = MacTLSTransport(
    host: peerHost,
    port: peerPort,
    trustEvaluator: backend.evaluator(answering: [.accept, .accept]),
    backendFactory: backend.factory
  )

  try await transport.connect()
  await backend.waitForReceive()

  #expect(backend.evaluations == [presentedChain, secondPresentedChain])
  #expect(
    backend.events == [
      .start,
      .evaluate(presentedChain),
      .evaluate(secondPresentedChain),
      .ready,
      .receive(maximumLength: 65_536),
    ]
  )
  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

/// A later callback that reports a changed identity is never masked by an
/// earlier acceptance.
@Test func tlsTransportIdentityChangeOnALaterVerifyCallbackFailsClosed() async {
  let backend = FakeTLSBackend(start: .presentChains([presentedChain, secondPresentedChain]))
  let transport = MacTLSTransport(
    host: peerHost,
    port: peerPort,
    trustEvaluator: backend.evaluator(answering: [.accept, .reject(.identityChanged)]),
    backendFactory: backend.factory
  )
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  #expect(error == securityFailure(.identityChanged))
  #expect(backend.evaluations == [presentedChain, secondPresentedChain])
  #expect(!backend.events.contains(.ready))
  #expect(backend.receiveLengths.isEmpty)
  #expect(backend.cancelCount == 1)
  #expect(await drain(&iterator).end == .failed(securityFailure(.identityChanged)))
  await expectStaysTerminated(&iterator)

  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

// MARK: - Peer chain bounds

@Test func tlsTransportPeerChainBoundsAreFixed() {
  #expect(MacTLSTransport.maximumPeerCertificateCount == 10)
  #expect(MacTLSTransport.maximumPeerCertificateBytes == 262_144)
}

@Test func tlsTransportPeerChainAtBothBoundsReachesTheEvaluator() async throws {
  let atBounds = chain(count: 10, totalBytes: 262_144)
  try #require(atBounds.count == 10)
  try #require(atBounds.reduce(0) { $0 + $1.count } == 262_144)

  let backend = FakeTLSBackend(start: .presentChain(atBounds))
  let transport = try await connected(backend)

  #expect(backend.evaluations == [atBounds])
  #expect(backend.events.contains(.ready))
  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

/// One certificate too many, or one byte too many, fails closed before the
/// evaluator ever sees the chain.
@Test func tlsTransportPeerChainAboveEitherBoundFailsClosedWithoutConsultingTheEvaluator() async {
  let oversized = [
    chain(count: 11, totalBytes: 11 * 5),
    chain(count: 10, totalBytes: 262_145),
    chain(count: 1, totalBytes: 262_145),
  ]

  for presented in oversized {
    let backend = FakeTLSBackend(start: .presentChain(presented))
    let transport = makeTransport(backend, decision: .accept)
    var iterator = transport.incomingBytes.makeAsyncIterator()

    let error = await connectFailure(transport)

    #expect(error == securityFailure(.trustRejected))
    #expect(backend.evaluations.isEmpty, "an accepting evaluator must not see an oversized chain")
    #expect(!backend.events.contains(.ready))
    #expect(backend.receiveLengths.isEmpty)
    #expect(backend.cancelCount == 1)
    #expect(await drain(&iterator).end == .failed(securityFailure(.trustRejected)))
  }
}

/// A TLS backend that becomes ready without presenting any certificate must
/// never be trusted by default.
@Test func tlsTransportReadyWithoutPeerVerificationFailsClosed() async {
  let backend = FakeTLSBackend(start: .readyWithoutVerification)
  let transport = makeTransport(backend, decision: .accept)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  #expect(error == securityFailure(.trustRejected))
  #expect(backend.evaluations.isEmpty)
  #expect(backend.receiveLengths.isEmpty)
  #expect(backend.cancelCount == 1)
  #expect(await drain(&iterator).end == .failed(securityFailure(.trustRejected)))
}

@Test func tlsTransportRejectedPeerCannotSendOrReconnect() async {
  let backend = FakeTLSBackend()
  let transport = makeTransport(backend, decision: .reject(.identityChanged))
  _ = await connectFailure(transport)

  expectCode(await sendFailure(transport, secretPayload), .transport(.disconnected))
  #expect(await connectFailure(transport) == misuseFailure)
  #expect(backend.sentPayloads.isEmpty)
  #expect(backend.requests.count == 1)
  #expect(backend.cancelCount == 1)
}

// MARK: - Single use and misuse

@Test func tlsTransportSendBeforeConnectFailsClosedWithoutCreatingABackend() async {
  let backend = FakeTLSBackend()
  let transport = makeTransport(backend)

  #expect(await sendFailure(transport, secretPayload) == misuseFailure)
  #expect(await sendFailure(transport, Data()) == misuseFailure)
  #expect(backend.requests.isEmpty)
  #expect(backend.events.isEmpty)
}

@Test func tlsTransportConnectIsSingleUseAfterSuccess() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)

  #expect(await connectFailure(transport) == misuseFailure)
  #expect(backend.requests.count == 1)
  #expect(backend.events.filter { $0 == .start }.count == 1)

  await transport.disconnect()
  #expect(await connectFailure(transport) == misuseFailure)
  #expect(backend.requests.count == 1)
}

@Test func tlsTransportConcurrentSecondConnectFailsClosedWhileTheFirstIsPending() async {
  let backend = FakeTLSBackend(start: .suspendUntilCancelled)
  let transport = makeTransport(backend)
  let first = Task { await connectFailure(transport) }
  await backend.waitUntil { $0.contains(.start) }

  #expect(await connectFailure(transport) == misuseFailure)
  #expect(backend.requests.count == 1)

  await transport.disconnect()
  expectCode(await first.value, .cancellation(.requested))
  #expect(backend.cancelCount == 1)
}

@Test func tlsTransportDisconnectBeforeConnectFinishesTheStreamAndForbidsConnect() async {
  let backend = FakeTLSBackend()
  let transport = makeTransport(backend)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  await transport.disconnect()
  await transport.disconnect()

  #expect(await drain(&iterator).end == .finished)
  await expectStaysTerminated(&iterator)
  #expect(await connectFailure(transport) == misuseFailure)
  #expect(backend.requests.isEmpty, "a disconnected transport never creates a backend")
}

// MARK: - Connect failure mapping

@Test(arguments: connectMacTLSTransportFailureMappings)
func tlsTransportConnectFailureMapsToTheTypedError(mapping: MacTLSTransportFailureMapping) async {
  let backend = FakeTLSBackend(start: .fail(mapping.failure))
  let transport = makeTransport(backend)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  expectCode(error, mapping.code)
  #expect(backend.evaluations.isEmpty)
  #expect(backend.cancelCount == 1)
  let outcome = await drain(&iterator)
  #expect(outcome.chunks.isEmpty)
  expectStreamFailed(outcome.end, mapping.code)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))
  #expect(await connectFailure(transport) == misuseFailure)
}

/// The default Network.framework backend rejects an empty host and port zero
/// before creating any connection, so this opens no socket and needs no
/// network. A rejecting evaluator keeps a regression from ever trusting a peer.
@Test func tlsTransportDefaultBackendRejectsAnInvalidEndpointWithoutNetwork() async {
  let transport = MacTLSTransport(
    host: "",
    port: 0,
    trustEvaluator: { _ in .reject(.trustRejected) }
  )
  var iterator = transport.incomingBytes.makeAsyncIterator()

  let error = await connectFailure(transport)

  expectCode(error, .transport(.unavailable))
  let outcome = await drain(&iterator)
  #expect(outcome.chunks.isEmpty)
  expectStreamFailed(outcome.end, .transport(.unavailable))
  if let error { #expect(outcome.end == .failed(error)) }
  await expectStaysTerminated(&iterator)
}

// MARK: - Incoming bytes

@Test func tlsTransportYieldsNonEmptyChunksInOrderAndSkipsEmptyReads() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()

  backend.deliver(.success(.bytes(Data())))
  backend.deliver(.success(.bytes(Data("one".utf8))))
  backend.deliver(.success(.bytes(Data())))
  backend.deliver(.success(.bytes(Data("two".utf8))))
  backend.deliver(.success(.bytes(secretPayload)))

  #expect(try await reader.next() == Data("one".utf8))
  #expect(try await reader.next() == Data("two".utf8))
  #expect(try await reader.next() == secretPayload)

  await transport.disconnect()
  let rest = await drain(&reader)
  #expect(rest.chunks.isEmpty, "empty backend reads must never be yielded")
  #expect(rest.end == .finished)
}

@Test func tlsTransportReceivesWithAFixedSixtyFourKibibyteMaximum() async throws {
  #expect(MacTLSTransport.maximumReceiveLength == 65_536)

  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()
  let largest = Data(repeating: 0xA5, count: 65_536)

  backend.deliver(.success(.bytes(largest)))
  backend.deliver(.success(.bytes(Data([0x01]))))

  #expect(try await reader.next() == largest)
  #expect(try await reader.next() == Data([0x01]))
  await backend.waitForReceive(count: 3)
  #expect(backend.receiveLengths.allSatisfy { $0 == 65_536 })

  await transport.disconnect()
  #expect(await drain(&reader).end == .finished)
}

/// A backend that returns more than it was asked for is not trusted to have
/// bounded its allocation: the transport fails closed rather than yield it.
@Test func tlsTransportBackendReadAboveTheMaximumFailsWithResourceExhausted() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()

  backend.deliver(.success(.bytes(Data(repeating: 0x5A, count: 65_537))))

  let outcome = await drain(&reader)
  #expect(outcome.chunks.isEmpty)
  expectStreamFailed(outcome.end, .transport(.resourceExhausted))
  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))
}

/// With no consumer reading, the stream holds at most its finite buffer. The
/// first chunk that does not fit terminates the stream with resource
/// exhaustion; buffered chunks are delivered first, in order, and nothing is
/// silently dropped or reordered.
@Test func tlsTransportBufferOverflowReportsResourceExhaustedInsteadOfDropping() async throws {
  let limit = MacTLSTransport.incomingChunkBufferLimit
  try #require((1...4_096).contains(limit), "the incoming buffer must be small and finite")

  let backend = FakeTLSBackend()
  for index in 0...limit {
    backend.deliver(.success(.bytes(chunk(index))))
  }
  let transport = makeTransport(backend)
  var iterator = transport.incomingBytes.makeAsyncIterator()
  try await transport.connect()
  await backend.waitForCancel()

  let outcome = await drain(&iterator)
  #expect(outcome.chunks == (0..<limit).map(chunk))
  expectStreamFailed(outcome.end, .transport(.resourceExhausted))
  await expectStaysTerminated(&iterator)

  #expect(backend.receiveLengths.count == limit + 1, "receiving stops at the overflow")
  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))

  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

@Test func tlsTransportPeerEndOfStreamFailsTheStreamAsDisconnected() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()

  backend.deliver(.success(.bytes(Data("last".utf8))))
  backend.deliver(.success(.endOfStream))

  let outcome = await drain(&reader)
  #expect(outcome.chunks == [Data("last".utf8)])
  expectStreamFailed(outcome.end, .transport(.disconnected))
  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))
}

@Test(arguments: receiveMacTLSTransportFailureMappings)
func tlsTransportReceiveFailureMapsToTheTypedErrorAndCancelsOnce(
  mapping: MacTLSTransportFailureMapping
) async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()

  backend.deliver(.success(.bytes(secretPayload)))
  backend.deliver(.failure(mapping.failure))

  let outcome = await drain(&reader)
  #expect(outcome.chunks == [secretPayload])
  expectStreamFailed(outcome.end, mapping.code)
  await expectStaysTerminated(&reader)
  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))

  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

// MARK: - Sending

@Test func tlsTransportSendsInCallOrderAndTreatsEmptySendAsANoOp() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)

  try await transport.send(Data("first".utf8))
  try await transport.send(Data())
  try await transport.send(Data("second".utf8))
  try await transport.send(secretPayload)
  try await transport.send(Data())

  #expect(backend.sentPayloads == [Data("first".utf8), Data("second".utf8), secretPayload])
  await transport.disconnect()
}

@Test(arguments: sendMacTLSTransportFailureMappings)
func tlsTransportSendFailureMapsToTheTypedErrorAndIsTerminal(
  mapping: MacTLSTransportFailureMapping
) async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()
  backend.failNextSend(mapping.failure)

  expectCode(await sendFailure(transport, secretPayload), mapping.code)
  #expect(backend.cancelCount == 1)

  let outcome = await drain(&reader)
  #expect(outcome.chunks.isEmpty)
  expectStreamFailed(outcome.end, mapping.code)

  // The failure is terminal: the next send never reaches the backend.
  expectCode(await sendFailure(transport, Data("later".utf8)), .transport(.disconnected))
  #expect(backend.sentPayloads == [secretPayload])

  await transport.disconnect()
  #expect(backend.cancelCount == 1)
}

// MARK: - Disconnect and cancellation

@Test func tlsTransportDisconnectCancelsOnceFinishesOnceAndIsIdempotent() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()
  backend.deliver(.success(.bytes(Data("before".utf8))))
  #expect(try await reader.next() == Data("before".utf8))
  await backend.waitForReceive(count: 2)

  await transport.disconnect()
  await transport.disconnect()
  await transport.disconnect()

  // The pending receive the backend cancels must not turn a normal disconnect
  // into a failure.
  let outcome = await drain(&reader)
  #expect(outcome.chunks.isEmpty)
  #expect(outcome.end == .finished)
  await expectStaysTerminated(&reader)

  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))
  #expect(backend.sentPayloads.isEmpty)
}

@Test func tlsTransportDisconnectCompletesCleanupFromAnAlreadyCancelledTask() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  var reader = transport.incomingBytes.makeAsyncIterator()

  let cleanup = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    await transport.disconnect()
    return Task.isCancelled
  }

  #expect(await cleanup.value, "the cleanup task was cancelled before disconnecting")
  #expect(backend.cancelCount == 1)
  #expect(await drain(&reader).end == .finished)
}

@Test func tlsTransportTaskCancellationDuringConnectCancelsTheBackendOnce() async {
  let backend = FakeTLSBackend(start: .suspendUntilCancelled)
  let transport = makeTransport(backend)
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let connecting = Task { await connectFailure(transport) }
  await backend.waitUntil { $0.contains(.start) }

  connecting.cancel()

  expectCode(await connecting.value, .cancellation(.requested))
  #expect(backend.cancelCount == 1)
  expectStreamFailed(await drain(&iterator).end, .cancellation(.requested))
  await expectStaysTerminated(&iterator)

  await transport.disconnect()
  await transport.disconnect()
  #expect(backend.cancelCount == 1)
  #expect(await connectFailure(transport) == misuseFailure)
}

@Test func tlsTransportDisconnectDuringConnectCancelsTheHandshakeAndFinishesNormally() async {
  let backend = FakeTLSBackend(start: .suspendUntilCancelled)
  let transport = makeTransport(backend)
  var iterator = transport.incomingBytes.makeAsyncIterator()
  let connecting = Task { await connectFailure(transport) }
  await backend.waitUntil { $0.contains(.start) }

  await transport.disconnect()

  expectCode(await connecting.value, .cancellation(.requested))
  #expect(backend.cancelCount == 1)
  #expect(await drain(&iterator).end == .finished)
  #expect(!backend.events.contains(.ready))
}

/// The single consumer going away ends the lifecycle: the backend is
/// cancelled once and later sends fail closed.
@Test func tlsTransportConsumerCancellationCancelsTheBackendOnce() async throws {
  let backend = FakeTLSBackend()
  let transport = try await connected(backend)
  await backend.waitForReceive()

  let consumer = Task {
    var reader = transport.incomingBytes.makeAsyncIterator()
    return try? await reader.next()
  }
  consumer.cancel()
  #expect(await consumer.value == nil)
  await backend.waitForCancel()

  await transport.disconnect()
  await transport.disconnect()
  #expect(backend.cancelCount == 1)
  expectCode(await sendFailure(transport, Data("x".utf8)), .transport(.disconnected))
}

// MARK: - Privacy

@Test func tlsTransportFailuresCarryNoPeerBytesHostOrDiagnosticPayload() async throws {
  var failures: [CoreError?] = []

  failures.append(
    await connectFailure(makeTransport(FakeTLSBackend(), decision: .reject(.identityChanged)))
  )
  failures.append(await connectFailure(makeTransport(FakeTLSBackend(start: .presentChain([])))))
  failures.append(await connectFailure(makeTransport(FakeTLSBackend(start: .fail(.refused)))))

  let sending = FakeTLSBackend()
  let sender = try await connected(sending)
  sending.failNextSend(.reset)
  failures.append(await sendFailure(sender, secretPayload))

  let receiving = FakeTLSBackend()
  let receiver = try await connected(receiving)
  var reader = receiver.incomingBytes.makeAsyncIterator()
  receiving.deliver(.success(.bytes(secretPayload)))
  receiving.deliver(.failure(.timedOut))
  if case .failed(let error) = await drain(&reader).end { failures.append(error) }
  await receiver.disconnect()

  #expect(failures.count == 5)
  let forbidden = [peerHost, "OPAL", "WALRUS", "7731", "Network", "NWError", "POSIX"]
  for failure in failures {
    let error = try #require(failure)
    #expect(error.underlyingDiagnosticCode == nil)

    let encoded = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["code", "severity", "retryDisposition", "cleanupDisposition"])

    let renderings = [
      try #require(String(data: encoded, encoding: .utf8)),
      String(describing: error),
      String(reflecting: error),
    ]
    for rendering in renderings {
      for token in forbidden {
        #expect(!rendering.contains(token), "a failure rendering carries \(token)")
      }
    }
  }
}

// MARK: - Accepted server connections (M2)

/// The server role does not request a client certificate: the accepted
/// connection becomes ready without a peer chain and the evaluator is never
/// consulted.
@Test func acceptedServerConnectsWithoutAPeerChainAndMovesBytes() async throws {
  let backend = FakeTLSBackend(start: .readyWithoutVerification)
  let transport = MacTLSTransport.acceptedServer(backendFactory: backend.factory)
  var iterator = transport.incomingBytes.makeAsyncIterator()

  try await transport.connect()
  try await transport.send(chunk(1))
  backend.deliver(.success(.bytes(chunk(2))))

  #expect(try await iterator.next() == chunk(2))
  #expect(backend.sentPayloads == [chunk(1)])
  #expect(backend.evaluations.isEmpty)
  #expect(
    backend.requests == [
      MacTLSTransportConnectionRequest(host: "", port: 0, security: .acceptedServer)
    ])
  await transport.disconnect()
  #expect(await drain(&iterator).end == .finished)
}

/// A client chain presented anyway is never trusted by default.
@Test func acceptedServerRejectsAnyPresentedChain() async {
  let backend = FakeTLSBackend(start: .presentChain(presentedChain))
  let transport = MacTLSTransport.acceptedServer(backendFactory: backend.factory)

  let error = await connectFailure(transport)

  #expect(error == securityFailure(.trustRejected))
  #expect(!backend.events.contains(.ready))
  #expect(backend.cancelCount == 1)
}

/// An accepted connection is single-use like every other transport.
@Test func acceptedServerCannotConnectTwice() async throws {
  let backend = FakeTLSBackend(start: .readyWithoutVerification)
  let transport = MacTLSTransport.acceptedServer(backendFactory: backend.factory)
  try await transport.connect()

  #expect(await connectFailure(transport) == misuseFailure)
  await transport.disconnect()
}

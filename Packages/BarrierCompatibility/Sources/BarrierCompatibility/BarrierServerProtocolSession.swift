// Server-role Barrier protocol session (M2 follow-up, not an Exact File of any Issue).
// Binds the M2-025 handshake and the M2-028 control encoder to an already admitted
// `Transport` (M2-024) behind the protocol-neutral `KVMProtocolSession` contract (C-003),
// so KVMCore's `ServerSession` (M2-029) never sees Barrier tokens. Only the proposed
// M2-023 subset is spoken: setup, a single enter, leave. Every input event and clipboard
// fails closed with a typed error and emits no bytes, because their wire encodings are
// not frozen. Keepalive timing is not frozen either, so no periodic keepalive is sent.

import Foundation
import KVMContracts

/// Barrier server session over one admitted, already connected transport.
///
/// `connect()` runs the handshake and returns once the client is set up, or
/// fails within `handshakeTimeout`. After setup, client `CALV`/`CNOP` and
/// screen-info updates are accepted silently; any other client frame ends the
/// session. `send(_:)` supports only `enterScreen` (once) and `leaveScreen`.
/// `disconnect(reason:)` is idempotent and never waits for the peer.
///
/// State lives behind one `NSLock`, hence `@unchecked Sendable`. Nothing is
/// logged; errors carry only frozen `CoreError` codes.
package final class BarrierServerProtocolSession: KVMProtocolSession, @unchecked Sendable {
  private enum Phase {
    case idle
    case handshaking
    case ready
    case closed
  }

  package let events: AsyncThrowingStream<KVMEvent, any Error>
  private let eventContinuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation
  private let transport: any Transport
  private let clock: any KVMClock
  private let handshakeTimeout: Duration
  private let lock = NSLock()
  private var phase = Phase.idle
  private var handshake: BarrierServerHandshake
  private var reassembler: BarrierFrameReassembler
  private var decoder: BarrierControlDecoder
  private var encoder: BarrierClipboardControlEncoder?
  private var readyWaiter: CheckedContinuation<Result<Void, CoreError>, Never>?
  private var readyResult: Result<Void, CoreError>?
  private var reader: Task<Void, Never>?

  /// Fails with `nil` when the name set, name bound or timeout is invalid.
  package init?(
    transport: any Transport, expectedScreenNames: Set<String>, clock: any KVMClock,
    handshakeTimeout: Duration
  ) {
    guard handshakeTimeout > .zero,
      let handshake = try? BarrierServerHandshake(
        expectedScreenNames: expectedScreenNames, maximumScreenNameByteCount: 64),
      let reassembler = try? BarrierFrameReassembler(maximumPayloadLength: Self.frameLimit),
      let decoder = try? BarrierControlDecoder(maximumPayloadLength: Self.frameLimit)
    else { return nil }
    self.transport = transport
    self.clock = clock
    self.handshakeTimeout = handshakeTimeout
    self.handshake = handshake
    self.reassembler = reassembler
    self.decoder = decoder
    (events, eventContinuation) = AsyncThrowingStream.makeStream()
  }

  package func connect() async throws(CoreError) {
    let hello = try withState { () -> Result<[UInt8], CoreError> in
      guard phase == .idle else {
        return .failure(Self.error(.internalFailure(.preconditionFailed)))
      }
      phase = .handshaking
      do throws(BarrierServerHandshakeError) {
        return .success(try handshake.start())
      } catch {
        return .failure(Self.map(error))
      }
    }
    do throws(CoreError) {
      try await transport.send(Data(hello))
    } catch {
      await fail(error)
      throw error
    }
    let readTask = Task { await self.readLoop() }
    lock.withLock { reader = readTask }
    let outcome = await waitForReady()
    if case .failure(let error) = outcome {
      await fail(error)
      throw error
    }
  }

  package func send(_ event: KVMEvent) async throws(CoreError) {
    let frame = try withState { () -> Result<[UInt8], CoreError> in
      guard phase == .ready, var current = encoder else {
        return .failure(Self.error(.lifecycle(.subsystemUnavailable)))
      }
      switch event {
      case .enterScreen(_, let position):
        do throws(BarrierClipboardControlEncoderError) {
          let frame = try current.enter(position: position)
          encoder = current
          return .success(frame)
        } catch {
          return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
        }
      case .leaveScreen:
        return .success(current.leave())
      case .mouseMove, .mouseButton, .scroll, .key, .clipboard:
        // M2-023: no frozen server encoding; fail closed without bytes.
        return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
      }
    }
    try await transport.send(Data(frame))
  }

  package func disconnect(reason: DisconnectReason) async {
    let (wasOpen, task, waiter) = lock.withLock {
      let wasOpen = phase != .closed
      phase = .closed
      let waiter = readyWaiter
      readyWaiter = nil
      if readyResult == nil {
        readyResult = .failure(Self.error(.lifecycle(.subsystemUnavailable)))
      }
      return (wasOpen, reader, waiter)
    }
    guard wasOpen else { return }
    waiter?.resume(returning: .failure(Self.error(.lifecycle(.subsystemUnavailable))))
    task?.cancel()
    await transport.disconnect()
    switch reason {
    case .failure(let error): eventContinuation.finish(throwing: error)
    case .cancellation(let cancellation):
      eventContinuation.finish(
        throwing: CoreError(
          code: .cancellation(cancellation), severity: .info, retryDisposition: .never,
          cleanupDisposition: .completed))
    case .userRequested, .transportClosed, .applicationTermination:
      eventContinuation.finish()
    }
  }

  // MARK: - Handshake and reading

  private func waitForReady() async -> Result<Void, CoreError> {
    let timeout = handshakeTimeout
    let clock = clock
    return await withTaskGroup(of: Result<Void, CoreError>.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          let immediate = self.lock.withLock { () -> Result<Void, CoreError>? in
            if let result = self.readyResult { return result }
            self.readyWaiter = continuation
            return nil
          }
          if let immediate { continuation.resume(returning: immediate) }
        }
      }
      group.addTask {
        do throws(CoreError) {
          try await clock.sleep(for: timeout)
          return .failure(Self.error(.timeout(.handshake)))
        } catch {
          // A cancelled wait (for example the caller cancelled `connect()`)
          // must fail the handshake; it must never disable the timeout.
          return .failure(error)
        }
      }
      let outcome = await group.next() ?? .failure(Self.error(.timeout(.handshake)))
      let waiter = lock.withLock {
        let waiter = readyWaiter
        readyWaiter = nil
        if readyResult == nil { readyResult = outcome }
        return waiter
      }
      waiter?.resume(returning: outcome)
      group.cancelAll()
      return outcome
    }
  }

  private func readLoop() async {
    do {
      for try await chunk in transport.incomingBytes {
        let payloads = try withState { () -> Result<[[UInt8]], CoreError> in
          do throws(BarrierFrameReassemblerError) {
            try reassembler.append(Array(chunk))
            var payloads: [[UInt8]] = []
            while let payload = try reassembler.nextPayload() { payloads.append(payload) }
            return .success(payloads)
          } catch {
            return .failure(Self.error(.protocolViolation(.malformed)))
          }
        }
        for payload in payloads {
          try await handle(payload)
        }
      }
      await finishFromPeer(nil)
    } catch let error as CoreError {
      await finishFromPeer(error)
    } catch {
      await finishFromPeer(Self.error(.internalFailure(.unclassified)))
    }
  }

  private enum Step {
    case reply([UInt8], ready: Bool)
    case ignore
  }

  private func handle(_ payload: [UInt8]) async throws(CoreError) {
    let step = try withState { () -> Result<Step, CoreError> in
      switch phase {
      case .handshaking:
        do throws(BarrierServerHandshakeError) {
          let reply = try handshake.receive(payload: payload)
          guard case .ready(let screen) = handshake.state else {
            return .success(.reply(reply, ready: false))
          }
          encoder = BarrierClipboardControlEncoder(screen: screen)
          return .success(.reply(reply, ready: true))
        } catch {
          return .failure(Self.map(error))
        }
      case .ready:
        let outcome: BarrierControlOutcome
        do throws(BarrierControlMessageError) {
          outcome = try decoder.decode(payload: payload, direction: .clientToServer)
        } catch {
          return .failure(Self.error(.protocolViolation(.malformed)))
        }
        switch outcome {
        case .keepalive, .event(.screenInfo): return .success(.ignore)
        case .event, .skipped: return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
        }
      case .idle, .closed:
        return .success(.ignore)
      }
    }
    guard case .reply(let frames, let ready) = step else { return }
    if !frames.isEmpty { try await transport.send(Data(frames)) }
    if ready {
      let waiter = lock.withLock {
        phase = phase == .handshaking ? .ready : phase
        readyResult = readyResult ?? .success(())
        let waiter = readyWaiter
        readyWaiter = nil
        return waiter
      }
      waiter?.resume(returning: .success(()))
    }
  }

  /// Runs `body` under the lock and unwraps its typed result.
  private func withState<T>(_ body: () -> Result<T, CoreError>) throws(CoreError) -> T {
    try lock.withLock(body).get()
  }

  private func finishFromPeer(_ error: CoreError?) async {
    let waiter = lock.withLock {
      let waiter = readyWaiter
      readyWaiter = nil
      if readyResult == nil {
        readyResult = .failure(error ?? Self.error(.transport(.disconnected)))
      }
      return waiter
    }
    waiter?.resume(returning: .failure(error ?? Self.error(.transport(.disconnected))))
    await disconnect(reason: error.map { .failure($0) } ?? .transportClosed)
  }

  private func fail(_ error: CoreError) async {
    await disconnect(reason: .failure(error))
  }

  // MARK: - Errors

  private static let frameLimit = 4096

  private static func error(_ code: CoreErrorCode) -> CoreError {
    CoreError(
      code: code, severity: .error, retryDisposition: .never, cleanupDisposition: .notRequired)
  }

  private static func map(_ error: BarrierServerHandshakeError) -> CoreError {
    switch error {
    case .unknownClientScreen: Self.error(.security(.trustRejected))
    case .unsupportedMarker, .unsupportedVersion:
      Self.error(.protocolViolation(.unsupportedVersion))
    case .timedOut: Self.error(.timeout(.handshake))
    case .cancelled: Self.error(.cancellation(.requested))
    case .invalidConfiguration, .outOfOrderEvent, .alreadyReady:
      Self.error(.internalFailure(.preconditionFailed))
    case .malformedHelloBack, .invalidScreenName, .screenInfoRejected, .unexpectedFrame:
      Self.error(.protocolViolation(.malformed))
    }
  }
}

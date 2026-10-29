// Server-role Barrier protocol session (M2 follow-up, not an Exact File of any Issue).
// Binds the M2-025 handshake, the M2-028 control encoder and the M2-026/M2-027 input
// encoder to an already admitted `Transport` (M2-024) behind the protocol-neutral
// `KVMProtocolSession` contract (C-003), so KVMCore's `ServerSession` (M2-029) never sees
// Barrier tokens. Pointer, button, wheel, key, enter and leave frames, the keepalive
// cadence follow the M2-022 capture (evidence/e2e/M2-022/README.md); the clipboard
// transfer follows the M2-022 punctuation and clipboard addendum.

import Foundation
import KVMContracts

/// The client screen size the client reported in its latest `DINF`.
package struct BarrierClientScreen: Equatable, Sendable {
  package let width: Int
  package let height: Int

  package init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

/// Barrier server session over one admitted, already connected transport.
///
/// `connect()` runs the handshake and returns once the client is set up, or
/// fails within `handshakeTimeout`. After setup the session sends `CALV` every
/// three seconds and drops a client that sends nothing for three intervals in a
/// row as `timeout.keepalive`. Client `CALV`, `CNOP`, screen-info updates and
/// clipboard frames (`CCLP`, `DCLP`) are accepted. A complete client transfer
/// of clipboard 0 with UTF-8 text becomes one `.clipboard` event on `events`
/// (origin `.remote`, empty `contentHash`); a malformed or oversized transfer
/// is dropped without ending the session, as long as each frame fits the
/// 64 KiB frame limit (Barrier 2.4 sends 32 KiB chunks). A larger frame, like
/// any other unexpected client frame, ends the session. `send(_:)` writes enter, leave, pointer, button, wheel, supported
/// key and clipboard events; `canSend(_:)` says which events those are.
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

  /// Largest clipboard text, in UTF-8 bytes, sent or accepted.
  package static let clipboardByteLimit = 1 << 20
  private static let clipboardLimit = ClipboardByteLimit(byteCount: clipboardByteLimit)!

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
  private var input: BarrierServerInputEncoder?
  private var clipboard = BarrierClipboardAssembler(limit: clipboardTransferLimit)
  private let clientDevice = DeviceID()
  private var readyWaiter: CheckedContinuation<Result<Void, CoreError>, Never>?
  private var readyResult: Result<Void, CoreError>?
  private var reader: Task<Void, Never>?
  private var keepalive: Task<Void, Never>?
  private var clientHeard = false
  private var receivedFrames = 0
  private var frameWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  /// Fails with `nil` when the name set, name bound or timeout is invalid.
  package init?(
    transport: any Transport, expectedScreenNames: Set<String>, clock: any KVMClock,
    handshakeTimeout: Duration
  ) {
    guard handshakeTimeout > .zero,
      let handshake = try? BarrierServerHandshake(
        expectedScreenNames: expectedScreenNames, maximumScreenNameByteCount: 64),
      let reassembler = try? BarrierFrameReassembler(maximumPayloadLength: Self.frameLimit),
      let decoder = try? BarrierControlDecoder(maximumPayloadLength: Self.controlFrameLimit)
    else { return nil }
    self.transport = transport
    self.clock = clock
    self.handshakeTimeout = handshakeTimeout
    self.handshake = handshake
    self.reassembler = reassembler
    self.decoder = decoder
    (events, eventContinuation) = AsyncThrowingStream.makeStream()
  }

  /// Whether `send(_:)` can write `event`: everything but keys without an
  /// evidence-backed Barrier identifier and clipboard text over the limit.
  package static func canSend(_ event: KVMEvent) -> Bool {
    switch event {
    case .enterScreen, .leaveScreen, .mouseMove, .mouseButton, .scroll: true
    case .key(let key, _, _): BarrierServerInputEncoder.canEncode(key)
    case .clipboard(let payload): payload.utf8ByteCount <= clipboardByteLimit
    }
  }

  /// The client's latest reported screen size, or `nil` before setup.
  package var clientScreen: BarrierClientScreen? {
    lock.withLock {
      input.map {
        BarrierClientScreen(width: Int($0.screen.width), height: Int($0.screen.height))
      }
    }
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
    let keepaliveTask = Task { await self.keepaliveLoop() }
    let stale = lock.withLock { () -> Bool in
      guard phase == .ready else { return true }
      keepalive = keepaliveTask
      return false
    }
    if stale { keepaliveTask.cancel() }
  }

  package func send(_ event: KVMEvent) async throws(CoreError) {
    let frames = try withState { () -> Result<[UInt8], CoreError> in
      guard phase == .ready, var control = encoder, let input else {
        return .failure(Self.error(.lifecycle(.subsystemUnavailable)))
      }
      switch event {
      case .enterScreen(_, let position):
        do throws(BarrierClipboardControlEncoderError) {
          let frame = try control.enter(position: position)
          encoder = control
          return .success(frame)
        } catch {
          return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
        }
      case .leaveScreen:
        let frame = control.leave()
        encoder = control
        return .success(frame)
      case .mouseMove(let position):
        return .success(input.pointer(to: position))
      case .mouseButton(let button, let phase):
        return .success(input.button(button, phase: phase))
      case .scroll(let deltaX, let deltaY):
        return .success(input.scroll(deltaX: deltaX, deltaY: deltaY) ?? [])
      case .key(let key, let phase, let modifiers):
        do throws(BarrierServerInputEncoderError) {
          return .success(try input.key(key, phase: phase, modifiers: modifiers).flatMap { $0 })
        } catch {
          return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
        }
      case .clipboard(let payload):
        do throws(BarrierClipboardControlEncoderError) {
          return .success(try control.clipboard(payload, limit: Self.clipboardLimit))
        } catch {
          return .failure(Self.error(.clipboard(.oversized)))
        }
      }
    }
    guard !frames.isEmpty else { return }
    try await transport.send(Data(frames))
  }

  package func disconnect(reason: DisconnectReason) async {
    let (wasOpen, tasks, waiter, waiters) = lock.withLock {
      let wasOpen = phase != .closed
      phase = .closed
      let waiter = readyWaiter
      readyWaiter = nil
      if readyResult == nil {
        readyResult = .failure(Self.error(.lifecycle(.subsystemUnavailable)))
      }
      let waiters = frameWaiters.map(\.continuation)
      frameWaiters = []
      return (wasOpen, [reader, keepalive], waiter, waiters)
    }
    for frameWaiter in waiters { frameWaiter.resume() }
    guard wasOpen else { return }
    waiter?.resume(returning: .failure(Self.error(.lifecycle(.subsystemUnavailable))))
    for task in tasks { task?.cancel() }
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

  /// Test scheduling barrier: completes once at least `count` client frames
  /// have been handled after setup, or the session closed.
  package func waitForReceivedFrames(atLeast count: Int) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        guard receivedFrames < count, phase != .closed else { return true }
        frameWaiters.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  }

  // MARK: - Handshake, keepalive and reading

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

  /// Sends `CALV` every interval and drops a client that stayed silent for
  /// `silentIntervalsBeforeTimeout` intervals in a row (M2-022: the client
  /// answers every `CALV` at once and itself gives up after about nine seconds).
  private func keepaliveLoop() async {
    var silentIntervals = 0
    while true {
      do throws(CoreError) {
        try await clock.sleep(for: Self.keepaliveInterval)
      } catch {
        return
      }
      let (ready, heard) = lock.withLock { () -> (Bool, Bool) in
        defer { clientHeard = false }
        return (phase == .ready, clientHeard)
      }
      guard ready else { return }
      silentIntervals = heard ? 0 : silentIntervals + 1
      if silentIntervals >= Self.silentIntervalsBeforeTimeout {
        await fail(Self.error(.timeout(.keepalive)))
        return
      }
      do throws(CoreError) {
        try await transport.send(Data(Self.keepaliveFrame))
      } catch {
        await fail(error)
        return
      }
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
    case received([CheckedContinuation<Void, Never>], inbound: KVMEvent?)
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
          input = BarrierServerInputEncoder(screen: screen)
          return .success(.reply(reply, ready: true))
        } catch {
          return .failure(Self.map(error))
        }
      case .ready:
        var inbound: KVMEvent?
        if Self.code(of: payload, is: "DCLP") {
          inbound = receiveClipboard(payload)
        } else if !Self.code(of: payload, is: "CCLP") {
          let outcome: BarrierControlOutcome
          do throws(BarrierControlMessageError) {
            outcome = try decoder.decode(payload: payload, direction: .clientToServer)
          } catch {
            return .failure(Self.error(.protocolViolation(.malformed)))
          }
          switch outcome {
          case .keepalive: break
          case .event(.screenInfo(let screen)):
            encoder?.screen = screen
            input = BarrierServerInputEncoder(screen: screen)
          case .event, .skipped:
            return .failure(Self.error(.protocolViolation(.unsupportedMessage)))
          }
        }
        clientHeard = true
        receivedFrames += 1
        let due = frameWaiters.filter { receivedFrames >= $0.count }.map(\.continuation)
        frameWaiters.removeAll { receivedFrames >= $0.count }
        return .success(.received(due, inbound: inbound))
      case .idle, .closed:
        return .success(.ignore)
      }
    }
    switch step {
    case .ignore:
      return
    case .received(let due, let inbound):
      if let inbound { eventContinuation.yield(inbound) }
      for waiter in due { waiter.resume() }
    case .reply(let frames, let ready):
      if !frames.isEmpty { try await transport.send(Data(frames)) }
      guard ready else { return }
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

  private static func code(of payload: [UInt8], is code: String) -> Bool {
    payload.prefix(4).elementsEqual(code.utf8)
  }

  /// Feeds a client `DCLP` frame for clipboard 0 to the assembler (lock
  /// held) and returns the clipboard event a completed transfer carries; a
  /// broken transfer is dropped. Clipboard 1 is not
  /// shared, so its frames are ignored unparsed. `CCLP` (ownership) needs no
  /// action: the data follows.
  private func receiveClipboard(_ payload: [UInt8]) -> KVMEvent? {
    guard payload.count > 4, payload[4] == 0 else { return nil }
    do throws(BarrierClipboardError) {
      guard let transfer = try clipboard.receive(payload: payload),
        let text = try BarrierClipboard.text(fromMarshalled: transfer.data),
        text.utf8.count <= Self.clipboardByteLimit
      else { return nil }
      return .clipboard(
        ClipboardPayload(
          transactionID: ClipboardTransactionID(), origin: .remote(clientDevice), utf8Text: text,
          contentHash: ""))
    } catch {
      return nil
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

  // MARK: - Constants and errors

  /// Largest inbound frame: a 32 KiB clipboard chunk, as Barrier 2.4 sends it
  /// (M2-022 chunk measurement), plus its `DCLP` header, with headroom.
  private static let frameLimit = 64 * 1024
  /// Largest frame the control decoder accepts; clipboard frames bypass it.
  private static let controlFrameLimit = 4096
  /// Largest marshalled client transfer: the text limit plus the formats
  /// Barrier sends along (about 2.5 times the text in the measurement).
  private static let clipboardTransferLimit = 4 << 20
  /// M2-022: the server sent `CALV` every 3.0 s.
  private static let keepaliveInterval = Duration.seconds(3)
  private static let silentIntervalsBeforeTimeout = 3
  private static let keepaliveFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04] + Array("CALV".utf8)

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

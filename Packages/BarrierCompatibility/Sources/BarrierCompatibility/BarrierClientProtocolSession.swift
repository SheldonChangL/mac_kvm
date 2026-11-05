// Client-role Barrier protocol session (M1-029-FOLLOWUP-001) for the first-party Linux client.
// It binds the M1-029 handshake, the M1-031 control decoder, the M1-032/033/034/041 input
// decoders, the M1-043 key mapper and the M2-028 clipboard transfer to one `Transport` behind
// the protocol-neutral `KVMProtocolSession` contract (C-003), so the client Core never sees a
// Barrier token. Layouts and the drop and fail-closed rules come only from
// docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md and
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md. The keepalive
// timeout, the size limits and the retry dispositions are first-party policy
// (docs/components/M1-029-FOLLOWUP-001-barrier-client-protocol-session.md).

import Foundation
import KVMContracts

/// The screen a Barrier client reports in `DINF` (M1-PROTOCOL-002): its rectangle and its
/// cursor position, in pixels.
///
/// Construction checks the values against the frozen `DINF` rules (a 16-bit signed origin,
/// width and height in `1...0x7FFF`, a cursor in `0...0x7FFF` inside the rectangle) by decoding
/// the encoded frame with `BarrierControlDecoder`, so the session's own decoder always accepts
/// the screen it reports.
package struct BarrierLocalScreen: Equatable, Sendable {
  let info: BarrierScreenInfo

  /// `nil` unless the values form a valid `DINF` screen.
  package init?(originX: Int, originY: Int, width: Int, height: Int, cursorX: Int, cursorY: Int) {
    guard let originX = Int16(exactly: originX), let originY = Int16(exactly: originY),
      let width = UInt16(exactly: width), let height = UInt16(exactly: height),
      let cursorX = UInt16(exactly: cursorX), let cursorY = UInt16(exactly: cursorY)
    else { return nil }
    let info = BarrierScreenInfo(
      originX: originX, originY: originY, width: width, height: height, cursorX: cursorX,
      cursorY: cursorY)
    let payload = Array(BarrierClientControlEncoder.screenInfo(info).dropFirst(4))
    guard
      var decoder = try? BarrierControlDecoder(
        maximumPayloadLength: BarrierControlDecoder.minimumMaximumPayloadLength)
    else { return nil }
    let outcome = try? decoder.decode(payload: payload, direction: .clientToServer)
    guard outcome == .event(.screenInfo(info)) else { return nil }
    self.info = info
  }
}

/// What a client session dropped while it went on, and how many keys its decoder holds.
/// Counts only: no wire value, key, coordinate or clipboard content (M1-011).
package struct BarrierClientSessionDiagnostics: Equatable, Sendable {
  /// Why a server frame or clipboard transfer was dropped (M1-PROTOCOL-003 "Drop and
  /// continue", plus the session's first-party rules).
  package enum DropReason: CaseIterable, Hashable, Sendable {
    /// `DMMV` with a raw coordinate above 0x7FFF.
    case pointerOutOfRange
    /// `DMMV` outside the reported rectangle.
    case pointerOutsideScreen
    /// `DMDN` or `DMUP` outside the contract's 1 to 5.
    case buttonOutOfContract
    /// `DMDN` or `DMUP` 5, which `MouseButton` cannot represent.
    case buttonUnrepresentable
    /// `DMWM` without a whole notch on either axis.
    case wheelWithoutNotch
    /// `DKRP` of a key that is not held (M1-041 consumer rule, Frozen Decision 7).
    case unpairedRepeat
    /// A clipboard 0 transfer that breaks the start, chunk and end rules or the marshalled
    /// layout.
    case clipboardMalformed
    /// A clipboard 0 transfer over the transfer limit, or with text over
    /// `BarrierClientProtocolSession.clipboardByteLimit`.
    case clipboardOversized
    /// A complete clipboard 0 transfer without UTF-8 text (format 0).
    case clipboardWithoutText
  }

  package let dropsByReason: [DropReason: Int]
  /// Keys the session's decoder holds (pressed and not released), for the fail-safe report
  /// only. The session never releases them: the client Core's ledger does.
  package let heldKeyCount: Int

  package var unpairedRepeatsDropped: Int { dropsByReason[.unpairedRepeat, default: 0] }
}

/// Barrier client session over one `Transport`, which it connects.
///
/// `connect()` connects the transport, answers the server hello with HelloBack and `QINF` with
/// `DINF`, and returns once that `DINF` is written; it fails within `handshakeTimeout`. Every
/// later server frame is routed by its token before anything reaches `BarrierControlDecoder`:
/// pointer, button, wheel and key frames to their decoders (the key mapper composes the key
/// events), `DCLP` to the clipboard assembler, a server-to-client `CCLP` to a fail-closed
/// error, and the rest to the control decoder, which therefore never sees `DKRP` (M1-041).
///
/// - A `DKRP` of a key that is not held is never composed into an event (Frozen Decision 7);
///   it is counted. Unpaired releases are passed on. The session never synthesizes a release:
///   the client Core's ledger releases whatever is held on every terminal path.
/// - Drop-and-continue and fail-closed cases follow M1-PROTOCOL-003 "Rejection semantics"; a
///   fail-closed case ends the session with a typed `protocolViolation`.
/// - Each server `CALV` is answered with `CALV` at once. First-party policy: nine one-second
///   checks in a row without any server frame end the session with `timeout.keepalive`.
/// - `send(_:)` takes only `.clipboard`: `CCLP` and then the `DCLP` transfer of clipboard 0,
///   both with the sequence of the `CINN` in force. Input events fail closed with no bytes.
/// - `updateScreen(_:)` reports a new screen in `DINF` at once while the screen is not
///   entered, and after the next `COUT` while it is.
/// - Frames are written in the order they were composed, whichever task composed them.
/// - `disconnect(reason:)` is idempotent and never waits for the peer.
///
/// State lives behind one `NSLock`, hence `@unchecked Sendable`. Nothing is logged; errors carry
/// only frozen `CoreError` codes and the diagnostics only counts.
package final class BarrierClientProtocolSession: KVMProtocolSession, @unchecked Sendable {
  private enum Phase {
    case idle
    case handshaking
    case ready
    case closed
  }

  /// A composed frame and its place in the write order.
  private struct Write {
    let bytes: [UInt8]
    let ticket: UInt64
  }

  /// What handling one server frame produced.
  private struct Step {
    var events: [KVMEvent] = []
    var write: Write?
    var completesHelloBack = false
    var completesSetup = false
    var counted = false
  }

  /// Test scheduling conditions.
  private enum Barrier {
    case receivedFrames(Int)
    case pendingWrites(Int)
  }

  private typealias Waiter = CheckedContinuation<Void, Never>
  private typealias ReadyWaiter = CheckedContinuation<Result<Void, CoreError>, Never>

  /// Largest clipboard text, in UTF-8 bytes, sent or accepted (the first-party server's limit,
  /// M2-029-FOLLOWUP-001).
  package static let clipboardByteLimit = 1 << 20

  package let events: AsyncThrowingStream<KVMEvent, any Error>
  private let eventContinuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation
  private let transport: any Transport
  private let clock: any KVMClock
  private let handshakeTimeout: Duration
  private let localScreen: ScreenID
  /// The origin of inbound clipboard payloads: one identifier per session.
  private let serverDevice = DeviceID()
  private let lock = NSLock()
  private var phase = Phase.idle
  private var handshake: BarrierClientHandshake
  private var reassembler: BarrierFrameReassembler
  private var control: BarrierControlDecoder
  private var keyboard = BarrierKeyboardDecoder()
  private var clipboard = BarrierClipboardAssembler(limit: clipboardTransferLimit)
  /// The screen last reported in `DINF`, or the one to report when `QINF` arrives.
  private var screen: BarrierScreenInfo
  /// A screen change made while entered; reported after the next `COUT`.
  private var deferredScreen: BarrierScreenInfo?
  /// The pointer decoder of the reported screen; `nil` until the first `DINF`.
  private var pointer: BarrierMouseMoveDecoder?
  /// The sequence of the `CINN` in force, for `CCLP` and `DCLP` (BARRIER-EVID-0006-CLAIM-007).
  private var enterSequence: UInt32?
  private var drops: [BarrierClientSessionDiagnostics.DropReason: Int] = [:]
  private var readyWaiter: ReadyWaiter?
  private var readyResult: Result<Void, CoreError>?
  private var reader: Task<Void, Never>?
  private var keepalive: Task<Void, Never>?
  private var serverHeard = false
  private var receivedFrames = 0
  private var nextTicket: UInt64 = 0
  private var servingTicket: UInt64 = 0
  private var turnWaiters: [UInt64: CheckedContinuation<Bool, Never>] = [:]
  private var nextBarrierID = 0
  private var barrierWaiters: [(id: Int, barrier: Barrier, continuation: Waiter)] = []
  private var tornDown = false
  private var teardownWaiters: [Waiter] = []

  /// Fails with `nil` when the screen name is not a valid HelloBack name (M1-028) of at most
  /// 64 bytes, or the timeout is not positive.
  package init?(
    transport: any Transport, screenName: String, localScreen: ScreenID,
    screen: BarrierLocalScreen, clock: any KVMClock, handshakeTimeout: Duration
  ) {
    guard handshakeTimeout > .zero,
      let writer = try? BarrierClientHelloBackWriter(
        maximumScreenNameByteCount: Self.maximumScreenNameByteCount),
      (try? writer.frame(screenName: screenName)) != nil,
      let reassembler = try? BarrierFrameReassembler(maximumPayloadLength: Self.frameLimit),
      let control = try? BarrierControlDecoder(maximumPayloadLength: Self.controlFrameLimit)
    else { return nil }
    self.transport = transport
    self.clock = clock
    self.handshakeTimeout = handshakeTimeout
    self.localScreen = localScreen
    self.screen = screen.info
    self.handshake = BarrierClientHandshake(screenName: screenName, helloBackWriter: writer)
    self.reassembler = reassembler
    self.control = control
    (events, eventContinuation) = AsyncThrowingStream.makeStream()
  }

  /// Counts of the frames dropped so far, by reason, and the keys the decoder holds.
  package var diagnostics: BarrierClientSessionDiagnostics {
    lock.withLock {
      BarrierClientSessionDiagnostics(dropsByReason: drops, heldKeyCount: keyboard.heldKeys.count)
    }
  }

  package func connect() async throws(CoreError) {
    try withState { () -> Result<Void, CoreError> in
      guard phase == .idle else { return .failure(Self.internalError(.preconditionFailed)) }
      do throws(BarrierClientHandshakeError) {
        try handshake.start()
      } catch {
        return .failure(Self.map(error))
      }
      phase = .handshaking
      return .success(())
    }
    let readTask = Task { await self.run() }
    let late = lock.withLock { () -> Bool in
      guard phase != .closed else { return true }
      reader = readTask
      return false
    }
    if late { readTask.cancel() }
    if case .failure(let error) = await waitForReady() {
      await fail(error)
      throw error
    }
    let monitor = Task { await self.keepaliveLoop() }
    let stale = lock.withLock { () -> Bool in
      guard phase == .ready else { return true }
      keepalive = monitor
      return false
    }
    if stale { monitor.cancel() }
  }

  /// Writes the local clipboard: `CCLP` for clipboard 0, then its `DCLP` transfer, both with
  /// the sequence of the `CINN` in force. Every other event fails closed with no bytes.
  package func send(_ event: KVMEvent) async throws(CoreError) {
    guard case .clipboard(let payload) = event else {
      throw Self.refusal(.protocolViolation(.unsupportedMessage))
    }
    let (sequence, ticket) = try withState { () -> Result<(UInt32, UInt64), CoreError> in
      guard phase == .ready, let sequence = enterSequence else { return .failure(Self.unavailable) }
      guard payload.utf8ByteCount <= Self.clipboardByteLimit else {
        return .failure(Self.refusal(.clipboard(.oversized)))
      }
      return .success((sequence, reserveTicket()))
    }
    let bytes = BarrierClientControlEncoder.clipboard(
      marshalled: BarrierClipboard.marshal(text: payload.utf8Text), sequence: sequence)
    try await write(Write(bytes: bytes, ticket: ticket))
  }

  /// Reports `newScreen` in `DINF`: before setup it replaces the screen `QINF` will get; while
  /// the screen is entered it is deferred until after the next `COUT` (M1-031 accepts `DINF`
  /// only while not entered); otherwise it is written at once. An unchanged screen writes
  /// nothing.
  package func updateScreen(_ newScreen: BarrierLocalScreen) async throws(CoreError) {
    let pending: Write?
    do throws(CoreError) {
      pending = try withState { () -> Result<Write?, CoreError> in
        let info = newScreen.info
        guard phase != .closed else { return .failure(Self.unavailable) }
        guard pointer != nil else {
          screen = info
          return .success(nil)
        }
        if case .active = control.state {
          deferredScreen = info == screen ? nil : info
          return .success(nil)
        }
        guard info != screen else { return .success(nil) }
        return reportScreen(info).map(Optional.some)
      }
    } catch {
      await fail(error)
      throw error
    }
    guard let pending else { return }
    try await write(pending)
  }

  /// Ends the session once: cancels the reader and the keepalive check, disconnects the
  /// transport and finishes `events` as `reason` says. A later call returns when that first
  /// teardown has finished, which the transport's bounded `disconnect()` bounds.
  package func disconnect(reason: DisconnectReason) async {
    let (wasOpen, tasks, waiter) = lock.withLock {
      () -> (Bool, [Task<Void, Never>?], ReadyWaiter?) in
      let wasOpen = phase != .closed
      phase = .closed
      let waiter = readyWaiter
      readyWaiter = nil
      if readyResult == nil { readyResult = .failure(Self.unavailable) }
      return (wasOpen, [reader, keepalive], waiter)
    }
    let (barriers, turns) = lock.withLock {
      () -> ([Waiter], [CheckedContinuation<Bool, Never>]) in
      defer {
        barrierWaiters = []
        turnWaiters = [:]
      }
      return (barrierWaiters.map(\.continuation), Array(turnWaiters.values))
    }
    for barrier in barriers { barrier.resume() }
    for turn in turns { turn.resume(returning: false) }
    guard wasOpen else {
      await waitForTeardown()
      return
    }
    waiter?.resume(returning: .failure(Self.unavailable))
    for task in tasks { task?.cancel() }
    await transport.disconnect()
    switch reason {
    case .failure(let error):
      eventContinuation.finish(throwing: error)
    case .cancellation(let cancellation):
      eventContinuation.finish(
        throwing: CoreError(
          code: .cancellation(cancellation), severity: .info, retryDisposition: .never,
          cleanupDisposition: .completed))
    case .userRequested, .transportClosed, .applicationTermination:
      eventContinuation.finish()
    }
    let waiting = lock.withLock { () -> [Waiter] in
      tornDown = true
      defer { teardownWaiters = [] }
      return teardownWaiters
    }
    for waiter in waiting { waiter.resume() }
  }

  /// Test scheduling barrier: completes once at least `count` server frames have been handled
  /// after setup (each with its reply written), the session closed, or the waiting task is
  /// cancelled.
  package func waitForReceivedFrames(atLeast count: Int) async {
    await wait(for: .receivedFrames(count))
  }

  /// Test scheduling barrier: completes once at least `count` composed frames wait for an
  /// earlier write, the session closed, or the waiting task is cancelled.
  package func waitForPendingWrites(atLeast count: Int) async {
    await wait(for: .pendingWrites(count))
  }

  // MARK: - Handshake and liveness

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
          return .failure(Self.timeoutError(.handshake))
        } catch {
          // A cancelled wait (the caller cancelled `connect()`) fails the handshake; it never
          // disables the timeout.
          return .failure(error)
        }
      }
      let outcome = await group.next() ?? .failure(Self.timeoutError(.handshake))
      let waiter = lock.withLock { () -> ReadyWaiter? in
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

  /// First-party policy, not a Barrier claim: the first-party server sends `CALV` every three
  /// seconds and drops a silent client after three intervals (M2-029-FOLLOWUP-001), so the
  /// client checks once a second and ends the session after nine silent checks in a row.
  private func keepaliveLoop() async {
    var silentChecks = 0
    while true {
      do throws(CoreError) {
        try await clock.sleep(for: Self.keepaliveCheckInterval)
      } catch {
        return
      }
      let (ready, heard) = lock.withLock { () -> (Bool, Bool) in
        defer { serverHeard = false }
        return (phase == .ready, serverHeard)
      }
      guard ready else { return }
      silentChecks = heard ? 0 : silentChecks + 1
      if silentChecks >= Self.silentChecksBeforeTimeout {
        await fail(Self.timeoutError(.keepalive))
        return
      }
    }
  }

  // MARK: - Reading

  private func run() async {
    do throws(CoreError) {
      try await transport.connect()
    } catch {
      await finish(error)
      return
    }
    do {
      for try await chunk in transport.incomingBytes {
        let payloads = try withState { () -> Result<[[UInt8]], CoreError> in
          do throws(BarrierFrameReassemblerError) {
            try reassembler.append(Array(chunk))
            var payloads: [[UInt8]] = []
            while let payload = try reassembler.nextPayload() { payloads.append(payload) }
            return .success(payloads)
          } catch {
            return .failure(Self.map(error))
          }
        }
        for payload in payloads { try await handle(payload) }
      }
      await finish(nil)
    } catch let error as CoreError {
      await finish(error)
    } catch {
      await finish(Self.internalError(.unclassified))
    }
  }

  /// Handles one complete server payload: decodes it under the lock, yields its events,
  /// writes its reply in order, then completes the handshake steps and the frame barrier.
  private func handle(_ payload: [UInt8]) async throws(CoreError) {
    let step = try withState { () -> Result<Step, CoreError> in
      switch phase {
      case .idle, .closed:
        return .success(Step())
      case .handshaking:
        if case .awaitHello = handshake.state { return receiveHello(payload) }
        return route(payload)
      case .ready:
        serverHeard = true
        var routed = route(payload)
        if case .success(var step) = routed {
          step.counted = true
          routed = .success(step)
        }
        return routed
      }
    }
    for event in step.events { eventContinuation.yield(event) }
    if let write = step.write { try await self.write(write) }
    if step.completesHelloBack {
      try withState { () -> Result<Void, CoreError> in
        do throws(BarrierClientHandshakeError) {
          try handshake.helloBackSent()
          return .success(())
        } catch {
          return .failure(Self.map(error))
        }
      }
    }
    let (setupWaiter, due) = lock.withLock { () -> (ReadyWaiter?, [Waiter]) in
      var setupWaiter: ReadyWaiter?
      if step.completesSetup, phase == .handshaking {
        phase = .ready
        if readyResult == nil { readyResult = .success(()) }
        setupWaiter = readyWaiter
        readyWaiter = nil
      }
      if step.counted { receivedFrames += 1 }
      return (setupWaiter, dueBarrierWaiters())
    }
    setupWaiter?.resume(returning: .success(()))
    for waiter in due { waiter.resume() }
  }

  /// Lock held: validates the server hello (M1-027) and composes HelloBack (M1-028).
  private func receiveHello(_ payload: [UInt8]) -> Result<Step, CoreError> {
    do throws(BarrierClientHandshakeError) {
      let reply = try handshake.receiveServerHello(payload: payload)
      return .success(
        Step(write: Write(bytes: reply, ticket: reserveTicket()), completesHelloBack: true))
    } catch {
      return .failure(Self.map(error))
    }
  }

  /// Lock held: routes a payload by its token. Input, key and clipboard frames go to their own
  /// decoders before anything reaches `BarrierControlDecoder`, which skips `DKDN`, `DKUP` and
  /// `DCLP` and fails closed on `DKRP` and the pointer tokens (M1-041, M1-031).
  private func route(_ payload: [UInt8]) -> Result<Step, CoreError> {
    if BarrierMouseMoveToken(payloadPrefix: payload) != nil { return pointerFrame(payload) }
    if BarrierMouseButtonToken(payloadPrefix: payload) != nil { return buttonFrame(payload) }
    if BarrierMouseWheelToken(payloadPrefix: payload) != nil { return wheelFrame(payload) }
    if BarrierKeyboardToken(payloadPrefix: payload) != nil { return keyFrame(payload) }
    if payload.starts(with: BarrierControlToken.dclp.bytes) { return clipboardFrame(payload) }
    if payload.starts(with: BarrierClientControlEncoder.clipboardOwnershipToken) {
      // M1-PROTOCOL-003: a first-party client fails closed on a server-to-client CCLP.
      return .failure(Self.protocolError(.unsupportedMessage))
    }
    return controlFrame(payload)
  }

  private func pointerFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    guard let pointer else { return .failure(Self.beforeSetup) }
    do throws(BarrierMouseMoveDecoderError) {
      switch try pointer.decode(payload: payload, direction: .serverToClient) {
      case .event(let event):
        return .success(Step(events: [event]))
      case .dropped(let diagnostic):
        switch diagnostic.reason {
        case .coordinateOutOfRange: count(.pointerOutOfRange)
        case .coordinateOutsideScreen: count(.pointerOutsideScreen)
        }
        return .success(Step())
      }
    } catch {
      switch error {
      case .invalidBodyLength: return .failure(Self.protocolError(.malformed))
      case .unknownToken, .unexpectedDirection:
        return .failure(Self.protocolError(.unsupportedMessage))
      }
    }
  }

  private func buttonFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    guard pointer != nil else { return .failure(Self.beforeSetup) }
    do throws(BarrierMouseButtonDecoderError) {
      switch try BarrierMouseButtonDecoder.decode(payload: payload, direction: .serverToClient) {
      case .event(let event):
        return .success(Step(events: [event]))
      case .dropped(let diagnostic):
        switch diagnostic.reason {
        case .buttonOutOfContract: count(.buttonOutOfContract)
        case .unrepresentableButton: count(.buttonUnrepresentable)
        }
        return .success(Step())
      }
    } catch {
      switch error {
      case .invalidBodyLength: return .failure(Self.protocolError(.malformed))
      case .unknownToken, .unexpectedDirection:
        return .failure(Self.protocolError(.unsupportedMessage))
      }
    }
  }

  private func wheelFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    guard pointer != nil else { return .failure(Self.beforeSetup) }
    do throws(BarrierMouseWheelDecoderError) {
      switch try BarrierMouseWheelDecoder.decode(payload: payload, direction: .serverToClient) {
      case .event(let event):
        return .success(Step(events: [event]))
      case .dropped(let diagnostic):
        switch diagnostic.reason {
        case .noWholeNotch: count(.wheelWithoutNotch)
        }
        return .success(Step())
      }
    } catch {
      switch error {
      case .invalidBodyLength: return .failure(Self.protocolError(.malformed))
      case .unknownToken, .unexpectedDirection:
        return .failure(Self.protocolError(.unsupportedMessage))
      }
    }
  }

  private func keyFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    guard pointer != nil else { return .failure(Self.beforeSetup) }
    let event: BarrierKeyEvent
    do throws(BarrierKeyboardDecoderError) {
      event = try keyboard.decode(payload: payload, direction: .serverToClient)
    } catch {
      switch error {
      case .invalidBodyLength: return .failure(Self.protocolError(.malformed))
      case .unknownToken, .unexpectedDirection:
        return .failure(Self.protocolError(.unsupportedMessage))
      }
    }
    // M1-041 consumer rule (Frozen Decision 7): a repeat of a key that is not held is never
    // composed into an event, so nothing can press a key that nothing releases. An unpaired
    // release is passed on: releasing a key that is not pressed leaves nothing stuck.
    if event.phase == .repeatKey, event.pairing == .unpaired {
      count(.unpairedRepeat)
      return .success(Step())
    }
    return .success(Step(events: [BarrierVirtualKeyMapper.kvmEvent(for: event)]))
  }

  /// Lock held: feeds a `DCLP` payload of clipboard 0 to the assembler. A broken transfer is
  /// dropped and counted (M1-PROTOCOL-003 "Drop and continue"); a payload too short for the
  /// fixed `DCLP` header does not match the layout and fails closed.
  private func clipboardFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    guard pointer != nil else { return .failure(Self.beforeSetup) }
    guard payload.count >= Self.clipboardHeaderLength else {
      return .failure(Self.protocolError(.malformed))
    }
    // First-party convention: only clipboard 0 is shared; other ids are ignored unparsed.
    guard payload[4] == BarrierClientControlEncoder.sharedClipboardID else {
      return .success(Step())
    }
    let transfer: BarrierClipboardTransfer?
    do throws(BarrierClipboardError) {
      transfer = try clipboard.receive(payload: payload)
    } catch {
      count(error == .oversized ? .clipboardOversized : .clipboardMalformed)
      return .success(Step())
    }
    guard let transfer else { return .success(Step()) }
    let text: String?
    do throws(BarrierClipboardError) {
      text = try BarrierClipboard.text(fromMarshalled: transfer.data)
    } catch {
      count(.clipboardMalformed)
      return .success(Step())
    }
    guard let text else {
      count(.clipboardWithoutText)
      return .success(Step())
    }
    guard text.utf8.count <= Self.clipboardByteLimit else {
      count(.clipboardOversized)
      return .success(Step())
    }
    let event = KVMEvent.clipboard(
      ClipboardPayload(
        transactionID: ClipboardTransactionID(), origin: .remote(serverDevice), utf8Text: text,
        contentHash: ""))
    return .success(Step(events: [event]))
  }

  private func controlFrame(_ payload: [UInt8]) -> Result<Step, CoreError> {
    let outcome: BarrierControlOutcome
    do throws(BarrierControlMessageError) {
      outcome = try control.decode(payload: payload, direction: .serverToClient)
    } catch {
      return .failure(Self.map(error))
    }
    switch outcome {
    case .keepalive(.keepalive):
      // M1-PROTOCOL-003: a client answers each server CALV with a CALV.
      let reply = Write(bytes: BarrierClientControlEncoder.keepalive(), ticket: reserveTicket())
      return .success(Step(write: reply))
    case .event(.screenInfoRequested):
      let completesSetup = phase == .handshaking
      return reportScreen(screen).map { Step(write: $0, completesSetup: completesSetup) }
    case .event(.setup):
      return .success(Step())
    case .event(.enter(let enter)):
      // BARRIER-EVID-0006-CLAIM-007: the increment rule is not frozen, so the sequence is not
      // validated; the latest one is kept for CCLP and DCLP.
      enterSequence = enter.sequence.rawValue
      return .success(
        Step(events: [.enterScreen(screen: localScreen, position: position(of: enter))]))
    case .event(.leave):
      var step = Step(events: [.leaveScreen(screen: localScreen)])
      if let deferredScreen {
        switch reportScreen(deferredScreen) {
        case .success(let write): step.write = write
        case .failure(let error): return .failure(error)
        }
      }
      return .success(step)
    case .keepalive(.noOp), .event(.screenInfo), .skipped:
      // Client-to-server tokens fail on their direction and the excluded tokens are routed
      // before the control decoder, so none of these can come from a server.
      return .failure(Self.protocolError(.unsupportedMessage))
    }
  }

  /// First-party convention: the pixel-to-normalized mapping of `BarrierMouseMoveDecoder`.
  private func position(of enter: BarrierEnter) -> NormalizedPoint {
    NormalizedPoint(
      x: BarrierMouseMoveDecoder.normalized(
        pixel: enter.x, origin: screen.originX, extent: screen.width),
      y: BarrierMouseMoveDecoder.normalized(
        pixel: enter.y, origin: screen.originY, extent: screen.height))
  }

  /// Lock held: composes `DINF` for `info`, feeds it to the control decoder as the client's
  /// own frame (M1-031 validates enter coordinates against it), rebuilds the pointer decoder
  /// and reserves the frame's place in the write order.
  private func reportScreen(_ info: BarrierScreenInfo) -> Result<Write, CoreError> {
    let frame = BarrierClientControlEncoder.screenInfo(info)
    do throws(BarrierControlMessageError) {
      let outcome = try control.decode(
        payload: Array(frame.dropFirst(4)), direction: .clientToServer)
      guard outcome == .event(.screenInfo(info)) else {
        return .failure(Self.internalError(.stateInvariantViolation))
      }
    } catch {
      return .failure(Self.map(error))
    }
    screen = info
    deferredScreen = nil
    pointer = BarrierMouseMoveDecoder(screen: info)
    return .success(Write(bytes: frame, ticket: reserveTicket()))
  }

  /// Lock held.
  private func count(_ reason: BarrierClientSessionDiagnostics.DropReason) {
    drops[reason, default: 0] += 1
  }

  // MARK: - Ordered writes

  /// Lock held: the next place in the write order. Every reserved ticket is written (or
  /// skipped once closed) exactly once, so the order never stalls.
  private func reserveTicket() -> UInt64 {
    defer { nextTicket &+= 1 }
    return nextTicket
  }

  /// Writes `write` once every frame composed before it has been written. A transport failure
  /// ends the session and is rethrown.
  private func write(_ write: Write) async throws(CoreError) {
    let open = await waitForTurn(write.ticket)
    defer { finishTurn(write.ticket) }
    guard open else { throw Self.unavailable }
    do throws(CoreError) {
      try await transport.send(Data(write.bytes))
    } catch {
      await fail(error)
      throw error
    }
  }

  /// `true` once it is `ticket`'s turn, `false` once the session closed.
  private func waitForTurn(_ ticket: UInt64) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let (immediate, due) = lock.withLock { () -> (Bool?, [Waiter]) in
        guard phase != .closed else { return (false, []) }
        guard servingTicket != ticket else { return (true, []) }
        turnWaiters[ticket] = continuation
        return (nil, dueBarrierWaiters())
      }
      for waiter in due { waiter.resume() }
      if let immediate { continuation.resume(returning: immediate) }
    }
  }

  private func finishTurn(_ ticket: UInt64) {
    let next = lock.withLock { () -> (CheckedContinuation<Bool, Never>, Bool)? in
      servingTicket = max(servingTicket, ticket &+ 1)
      guard let next = turnWaiters.removeValue(forKey: servingTicket) else { return nil }
      return (next, phase != .closed)
    }
    if let next { next.0.resume(returning: next.1) }
  }

  // MARK: - Barriers and teardown

  private func wait(for barrier: Barrier) async {
    let id = lock.withLock { () -> Int in
      nextBarrierID += 1
      return nextBarrierID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: Waiter) in
        let ready = lock.withLock { () -> Bool in
          guard !isSatisfied(barrier), !Task.isCancelled else { return true }
          barrierWaiters.append((id, barrier, continuation))
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> Waiter? in
        guard let index = barrierWaiters.firstIndex(where: { $0.id == id }) else { return nil }
        return barrierWaiters.remove(at: index).continuation
      }
      waiter?.resume()
    }
  }

  /// Lock held.
  private func isSatisfied(_ barrier: Barrier) -> Bool {
    guard phase != .closed else { return true }
    switch barrier {
    case .receivedFrames(let count): return receivedFrames >= count
    case .pendingWrites(let count): return turnWaiters.count >= count
    }
  }

  /// Lock held: removes and returns the barrier waiters that are now satisfied.
  private func dueBarrierWaiters() -> [Waiter] {
    let due = barrierWaiters.filter { isSatisfied($0.barrier) }.map(\.continuation)
    barrierWaiters.removeAll { isSatisfied($0.barrier) }
    return due
  }

  /// Completes once the first `disconnect` has disconnected the transport and finished
  /// `events`.
  private func waitForTeardown() async {
    await withCheckedContinuation { (continuation: Waiter) in
      let done = lock.withLock { () -> Bool in
        if tornDown { return true }
        teardownWaiters.append(continuation)
        return false
      }
      if done { continuation.resume() }
    }
  }

  /// Runs `body` under the lock and unwraps its typed result.
  private func withState<T>(_ body: () -> Result<T, CoreError>) throws(CoreError) -> T {
    try lock.withLock(body).get()
  }

  /// Ends the session from the reading side: the end of the stream (`nil`) or an error.
  private func finish(_ error: CoreError?) async {
    let failure = error ?? Self.transportError(.disconnected)
    let waiter = lock.withLock { () -> ReadyWaiter? in
      let waiter = readyWaiter
      readyWaiter = nil
      if readyResult == nil { readyResult = .failure(failure) }
      return waiter
    }
    waiter?.resume(returning: .failure(failure))
    await disconnect(reason: error.map { .failure($0) } ?? .transportClosed)
  }

  private func fail(_ error: CoreError) async {
    await disconnect(reason: .failure(error))
  }

  // MARK: - Constants and errors

  /// The HelloBack screen-name bound; the first-party server accepts names up to 64 bytes.
  private static let maximumScreenNameByteCount = 64
  /// Largest inbound frame: a 32 KiB clipboard chunk and its header, with headroom (as the
  /// server).
  private static let frameLimit = 64 * 1024
  /// Largest frame the control decoder accepts; input and clipboard frames bypass it.
  private static let controlFrameLimit = 4096
  /// Largest marshalled clipboard transfer (as the server).
  private static let clipboardTransferLimit = 4 << 20
  /// The `DCLP` token, id, sequence, mark and data length: the fixed part of every `DCLP`.
  private static let clipboardHeaderLength = 14
  /// First-party keepalive policy: one check a second, nine silent checks in a row.
  private static let keepaliveCheckInterval = Duration.seconds(1)
  private static let silentChecksBeforeTimeout = 9

  /// The session is not ready or already closed; nothing was written.
  private static let unavailable = CoreError(
    code: .lifecycle(.subsystemUnavailable), severity: .warning, retryDisposition: .never,
    cleanupDisposition: .notRequired)
  /// An input or clipboard frame before the screen was reported.
  private static let beforeSetup = protocolError(.invariantViolation)

  /// A failure the server's bytes caused. It ends the session; a fresh session usually clears
  /// it, so reconnecting with backoff is allowed (first-party policy).
  private static func protocolError(_ code: ProtocolErrorCode) -> CoreError {
    CoreError(
      code: .protocolViolation(code), severity: .error, retryDisposition: .backoff,
      cleanupDisposition: .notRequired)
  }

  private static func timeoutError(_ code: TimeoutErrorCode) -> CoreError {
    CoreError(
      code: .timeout(code), severity: .error, retryDisposition: .backoff,
      cleanupDisposition: .notRequired)
  }

  private static func transportError(_ code: TransportErrorCode) -> CoreError {
    CoreError(
      code: .transport(code), severity: .error, retryDisposition: .backoff,
      cleanupDisposition: .notRequired)
  }

  /// A local misuse; never retried.
  private static func internalError(_ code: InternalErrorCode) -> CoreError {
    CoreError(
      code: .internalFailure(code), severity: .error, retryDisposition: .never,
      cleanupDisposition: .notRequired)
  }

  /// A refused `send`; nothing was written and the session goes on.
  private static func refusal(_ code: CoreErrorCode) -> CoreError {
    CoreError(
      code: code, severity: .warning, retryDisposition: .never, cleanupDisposition: .notRequired)
  }

  private static func map(_ error: BarrierControlMessageError) -> CoreError {
    switch error {
    case .oversizePayload: protocolError(.oversized)
    case .unknownToken, .unexpectedDirection, .unsupportedSetupOption:
      protocolError(.unsupportedMessage)
    case .invalidBodyLength, .nonZeroReservedField, .invalidScreenSize, .coordinateOutOfRange,
      .coordinateOutsideScreen:
      protocolError(.malformed)
    case .enterWithoutScreenInfo, .unexpectedInState: protocolError(.invariantViolation)
    case .invalidMaximumPayloadLength: internalError(.preconditionFailed)
    }
  }

  private static func map(_ error: BarrierFrameReassemblerError) -> CoreError {
    switch error {
    case .oversize: protocolError(.oversized)
    case .truncatedPrefix, .truncatedPayload, .appendAfterFinish: protocolError(.malformed)
    case .invalidMaximumPayloadLength: internalError(.preconditionFailed)
    }
  }

  private static func map(_ error: BarrierClientHandshakeError) -> CoreError {
    switch error {
    case .serverHelloRejected(.unsupportedMarker), .serverHelloRejected(.unsupportedVersion):
      protocolError(.unsupportedVersion)
    case .serverHelloRejected: protocolError(.malformed)
    case .timedOut: timeoutError(.handshake)
    case .cancelled:
      CoreError(
        code: .cancellation(.requested), severity: .info, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    case .helloBackRejected: internalError(.preconditionFailed)
    case .outOfOrderEvent, .alreadyConnected: internalError(.stateInvariantViolation)
    }
  }
}

import BarrierCompatibility
import Foundation
import KVMContracts
import KVMCore
import Testing

// M1-029-FOLLOWUP-001: the first-party Barrier server session (M2-029-FOLLOWUP-001, driven by
// KVMCore's ServerSession) and the first-party client session over an in-memory duplex byte
// stream. Each side reads exactly what the other side's encoders wrote. Only package API is
// used, as the Linux composition root will use it. Every wait is cancellation-aware and the
// suite has a time limit.

/// One end of an in-memory duplex byte stream: what it sends, the other end receives.
/// Disconnecting either end finishes both directions, as closing a socket does.
private final class LoopbackEnd: Transport, @unchecked Sendable {
  let incomingBytes: AsyncThrowingStream<Data, any Error>
  private let inbox: AsyncThrowingStream<Data, any Error>.Continuation
  private let outbox: AsyncThrowingStream<Data, any Error>.Continuation
  private let lock = NSLock()
  private var closed = false

  init(
    incoming: (
      AsyncThrowingStream<Data, any Error>, AsyncThrowingStream<Data, any Error>.Continuation
    ),
    outgoing: AsyncThrowingStream<Data, any Error>.Continuation
  ) {
    (incomingBytes, inbox) = incoming
    outbox = outgoing
  }

  func connect() async throws(CoreError) {}

  func send(_ data: Data) async throws(CoreError) {
    guard lock.withLock({ !closed }) else {
      throw CoreError(
        code: .transport(.disconnected), severity: .error, retryDisposition: .backoff,
        cleanupDisposition: .notRequired)
    }
    outbox.yield(data)
  }

  func disconnect() async {
    lock.withLock { closed = true }
    inbox.finish()
    outbox.finish()
  }
}

private func loopbackPair() -> (server: LoopbackEnd, client: LoopbackEnd) {
  let toServer = AsyncThrowingStream<Data, any Error>.makeStream()
  let toClient = AsyncThrowingStream<Data, any Error>.makeStream()
  return (
    LoopbackEnd(incoming: toServer, outgoing: toClient.continuation),
    LoopbackEnd(incoming: toClient, outgoing: toServer.continuation)
  )
}

/// A fake `KVMClock` whose sleeps end only on `fire()` or cancellation.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var sleepers:
    [Int: (duration: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
  private var arrivals:
    [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
  private var nextID = 0

  func sleep(for duration: Duration) async throws(CoreError) {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    let fired = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let waiting: [CheckedContinuation<Void, Never>]? = lock.withLock {
          if Task.isCancelled { return nil }
          sleepers[id] = (duration, continuation)
          let matching = arrivals.filter { $0.duration == duration }
          arrivals.removeAll { $0.duration == duration }
          return matching.map(\.continuation)
        }
        guard let waiting else {
          continuation.resume(returning: false)
          return
        }
        for arrival in waiting { arrival.resume() }
      }
    } onCancel: {
      let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
      sleeper?.continuation.resume(returning: false)
    }
    guard fired else {
      throw CoreError(
        code: .cancellation(.requested), severity: .info, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    }
  }

  /// Completes once a sleeper of `duration` exists, or on cancellation.
  func waitForSleeper(duration: Duration) async {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          let present = sleepers.values.contains { $0.duration == duration }
          guard !present, !Task.isCancelled else { return true }
          arrivals.append((id, duration, continuation))
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let arrival = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        guard let index = arrivals.firstIndex(where: { $0.id == id }) else { return nil }
        return arrivals.remove(at: index).continuation
      }
      arrival?.resume()
    }
  }

  func fire(duration: Duration) {
    let due = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
      let selected = sleepers.filter { $0.value.duration == duration }
      for id in selected.keys { sleepers.removeValue(forKey: id) }
      return selected.values.map(\.continuation)
    }
    for sleeper in due { sleeper.resume(returning: true) }
  }
}

/// Records what `ServerSession.monitorPeer` hands to its owner.
private final class InboundRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [KVMEvent] = []
  private var nextID = 0
  private var waiters: [(id: Int, count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  var recorded: [KVMEvent] { lock.withLock { events } }

  func record(_ event: KVMEvent) {
    let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      events.append(event)
      let due = waiters.filter { events.count >= $0.count }.map(\.continuation)
      waiters.removeAll { events.count >= $0.count }
      return due
    }
    for waiter in due { waiter.resume() }
  }

  /// Completes once `count` events are recorded, or on cancellation.
  func waitForCount(_ count: Int) async {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          guard events.count < count, !Task.isCancelled else { return true }
          waiters.append((id, count, continuation))
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
      }
      waiter?.resume()
    }
  }
}

/// Opens once; waiters resume at the first `open()`.
private final class OnceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      isOpen = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        if isOpen { return true }
        waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
}

/// Waits for `body`, or until the waiting task is cancelled (the suite's time limit), for
/// barriers that do not observe cancellation themselves.
private func untilCancelled(_ body: @escaping @Sendable () async -> Void) async {
  let gate = OnceGate()
  let task = Task {
    await body()
    gate.open()
  }
  await withTaskCancellationHandler {
    await gate.wait()
  } onCancel: {
    task.cancel()
    gate.open()
  }
}

private func id(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xE3, value))
}

private let screenName = "m1-client"
private let serverKeepaliveInterval = Duration.seconds(3)

private func clipboard(_ text: String) -> ClipboardPayload {
  ClipboardPayload(
    transactionID: ClipboardTransactionID(), origin: .local, utf8Text: text, contentHash: "h")
}

/// Both sessions over one loopback pair, connected and set up.
private struct Linked {
  let linux: ScreenID
  let serverClock: ManualClock
  let barrierServer: BarrierServerProtocolSession
  let session: ServerSession
  let client: BarrierClientProtocolSession

  static func connect() async throws -> Linked {
    let (serverEnd, clientEnd) = loopbackPair()
    let linux = ScreenID(rawValue: id(2))
    let serverClock = ManualClock()
    let barrierServer = try #require(
      BarrierServerProtocolSession(
        transport: serverEnd, expectedScreenNames: [screenName], clock: serverClock,
        handshakeTimeout: .seconds(5)))
    let session = ServerSession(
      id: SessionID(rawValue: id(1)), screen: linux, protocolSession: barrierServer)
    let screen = try #require(
      BarrierLocalScreen(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450))
    let client = try #require(
      BarrierClientProtocolSession(
        transport: clientEnd, screenName: screenName, localScreen: linux, screen: screen,
        clock: ManualClock(), handshakeTimeout: .seconds(5)))
    async let serverStarted: Void = session.start()
    async let clientConnected: Void = client.connect()
    try await serverStarted
    try await clientConnected
    return Linked(
      linux: linux, serverClock: serverClock, barrierServer: barrierServer, session: session,
      client: client)
  }
}

@Suite("M1-029-FOLLOWUP-001 Barrier client and server loopback", .timeLimit(.minutes(1)))
struct BarrierClientServerLoopbackIntegrationTests {
  @Test("enter, pointer, buttons, wheel, keys, clipboard both ways, keepalive, leave, disconnect")
  func fullSessionCrossesTheWireBothWays() async throws {
    let linked = try await Linked.connect()
    let (linux, session, client) = (linked.linux, linked.session, linked.client)
    #expect(linked.barrierServer.clientScreen == BarrierClientScreen(width: 1600, height: 900))
    let inbound = InboundRecorder()
    let monitor = Task { await session.monitorPeer { inbound.record($0) } }
    var events = client.events.makeAsyncIterator()

    // The server's keepalive is answered by the client, so the server keeps the session.
    for round in 1...2 {
      await linked.serverClock.waitForSleeper(duration: serverKeepaliveInterval)
      linked.serverClock.fire(duration: serverKeepaliveInterval)
      let barrierServer = linked.barrierServer
      await untilCancelled { await barrierServer.waitForReceivedFrames(atLeast: round) }
    }

    try await session.enter(at: NormalizedPoint(x: 0, y: 0.5))
    #expect(
      try await events.next()
        == .enterScreen(screen: linux, position: NormalizedPoint(x: 0, y: 450.0 / 899)))

    try await session.forward(.mouseMove(position: NormalizedPoint(x: 0.25, y: 0.75)))
    #expect(
      try await events.next()
        == .mouseMove(position: NormalizedPoint(x: 400.0 / 1599, y: 674.0 / 899)))

    for phase in [ButtonPhase.down, .up] {
      try await session.forward(.mouseButton(button: .right, phase: phase))
      #expect(try await events.next() == .mouseButton(button: .right, phase: phase))
    }

    try await session.forward(.scroll(deltaX: 1, deltaY: -2))
    #expect(try await events.next() == .scroll(deltaX: 1, deltaY: -2))

    // Mac capture reports each event with the modifier state after it; the wire carries a
    // modifier key's own press without its bit and its release with it (M1-PROTOCOL-003).
    let none = ModifierState()
    let shift = ModifierState(shift: true)
    let sent: [KVMEvent] = [
      .key(key: .shift, phase: .down, modifiers: shift),
      .key(key: .letter(1), phase: .down, modifiers: shift),
      .key(key: .letter(1), phase: .repeatKey, modifiers: shift),
      .key(key: .letter(1), phase: .up, modifiers: shift),
      .key(key: .shift, phase: .up, modifiers: none),
    ]
    let received: [KVMEvent] = [
      .key(key: .shift, phase: .down, modifiers: none),
      .key(key: .letter(1), phase: .down, modifiers: shift),
      .key(key: .letter(1), phase: .repeatKey, modifiers: shift),
      .key(key: .letter(1), phase: .up, modifiers: shift),
      .key(key: .shift, phase: .up, modifiers: shift),
    ]
    for event in sent { try await session.forward(event) }
    for event in received { #expect(try await events.next() == event) }
    #expect(client.diagnostics.heldKeyCount == 0)

    // Server to client: a short text and 600,001 bytes in 32 KiB chunks.
    let large = String(repeating: "mackvm-chunk-probe-", count: 31_579)
    for text in ["server \u{65E5}\u{672C}", large] {
      try await session.forward(.clipboard(clipboard(text)))
      guard case .clipboard(let payload)? = try await events.next() else {
        Issue.record("the client yielded no clipboard event")
        return
      }
      #expect(payload.utf8Text == text)
      guard case .remote = payload.origin else {
        Issue.record("an inbound clipboard must be remote")
        return
      }
    }

    // Client to server, while entered and after the leave (the CINN sequence stays in force).
    try await client.send(.clipboard(clipboard("client \u{2713}")))
    await inbound.waitForCount(1)
    try await session.leave()
    #expect(try await events.next() == .leaveScreen(screen: linux))
    try await client.send(.clipboard(clipboard(large)))
    await inbound.waitForCount(2)
    let texts = inbound.recorded.compactMap { event -> String? in
      if case .clipboard(let payload) = event { payload.utf8Text } else { nil }
    }
    #expect(texts == ["client \u{2713}", large])

    // The client disconnects: its stream finishes, the server sees the stream end.
    await client.disconnect(reason: .userRequested)
    #expect(try await events.next() == nil)
    #expect(await monitor.value == .transportClosed)
    #expect(await session.state == .closed)
  }

  @Test("a server close with a key held ends the client stream; no release is synthesized")
  func serverCloseWithAKeyHeld() async throws {
    let linked = try await Linked.connect()
    let (linux, session, client) = (linked.linux, linked.session, linked.client)
    var events = client.events.makeAsyncIterator()
    try await session.enter(at: NormalizedPoint(x: 1, y: 1))
    #expect(
      try await events.next()
        == .enterScreen(screen: linux, position: NormalizedPoint(x: 1, y: 1)))
    try await session.forward(.key(key: .letter(0), phase: .down, modifiers: ModifierState()))
    #expect(
      try await events.next() == .key(key: .letter(0), phase: .down, modifiers: ModifierState()))
    #expect(client.diagnostics.heldKeyCount == 1)

    await session.close(reason: .userRequested)
    // The stream ends without an up: releasing held input is the client Core's cleanup.
    #expect(try await events.next() == nil)
    #expect(client.diagnostics.heldKeyCount == 1)
    await expectThrowsLifecycleUnavailable {
      try await client.send(.clipboard(clipboard("late")))
    }
  }
}

private func expectThrowsLifecycleUnavailable(
  sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void
) async {
  do {
    try await body()
    Issue.record("the closed session accepted a send", sourceLocation: sourceLocation)
  } catch {
    #expect(
      (error as? CoreError)?.code == .lifecycle(.subsystemUnavailable),
      sourceLocation: sourceLocation)
  }
}

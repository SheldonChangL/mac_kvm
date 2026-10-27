import Foundation
import KVMContracts
import KVMCore
import Testing

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x29, value))
}

private let sessionID = SessionID(rawValue: fixedUUID(1))
private let screen = ScreenID(rawValue: fixedUUID(2))
private let entry = NormalizedPoint(x: 0, y: 0.5)
private let keyDown = KVMEvent.key(key: .letter(1), phase: .down, modifiers: ModifierState())
private let keyUp = KVMEvent.key(key: .letter(1), phase: .up, modifiers: ModifierState())

private let resetError = CoreError(
  code: .transport(.reset), severity: .error, retryDisposition: .backoff,
  cleanupDisposition: .notRequired)

/// Fake protocol session recording sends; individual sends can be held open or failed.
private final class FakeProtocolSession: KVMProtocolSession, @unchecked Sendable {
  private let lock = NSLock()
  private var sentEvents: [KVMEvent] = []
  private var disconnectReasons: [DisconnectReason] = []
  private var connectError: CoreError?
  private var failingEvents: [(KVMEvent, CoreError)] = []
  private var heldEvent: KVMEvent?
  private var held: CheckedContinuation<Void, Never>?
  private var heldArrival: CheckedContinuation<Void, Never>?
  let events: AsyncThrowingStream<KVMEvent, any Error>
  private let continuation: AsyncThrowingStream<KVMEvent, any Error>.Continuation

  init(connectError: CoreError? = nil) {
    self.connectError = connectError
    (events, continuation) = AsyncThrowingStream.makeStream()
  }

  var sent: [KVMEvent] { lock.withLock { sentEvents } }
  var disconnects: [DisconnectReason] { lock.withLock { disconnectReasons } }

  func fail(_ event: KVMEvent, with error: CoreError) {
    lock.withLock { failingEvents.append((event, error)) }
  }

  func hold(_ event: KVMEvent) {
    lock.withLock { heldEvent = event }
  }

  func waitUntilHeld() async {
    await withCheckedContinuation { (arrival: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock {
        if held == nil { heldArrival = arrival }
        return held != nil
      }
      if ready { arrival.resume() }
    }
  }

  func releaseHeld() {
    let waiting = lock.withLock {
      let waiting = held
      held = nil
      heldEvent = nil
      return waiting
    }
    waiting?.resume()
  }

  func finishFromPeer() {
    continuation.finish()
  }

  func connect() async throws(CoreError) {
    if let connectError { throw connectError }
  }

  func send(_ event: KVMEvent) async throws(CoreError) {
    let shouldHold = lock.withLock { heldEvent == event }
    if shouldHold {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let arrival = lock.withLock {
          held = continuation
          let arrival = heldArrival
          heldArrival = nil
          return arrival
        }
        arrival?.resume()
      }
    }
    let failure = lock.withLock { () -> CoreError? in
      sentEvents.append(event)
      return failingEvents.first { $0.0 == event }?.1
    }
    if let failure { throw failure }
  }

  func disconnect(reason: DisconnectReason) async {
    lock.withLock { disconnectReasons.append(reason) }
    continuation.finish()
  }
}

private func readySession(_ fake: FakeProtocolSession) async throws -> ServerSession {
  let session = ServerSession(id: sessionID, screen: screen, protocolSession: fake)
  try await session.start()
  return session
}

@Suite("M2-029 ServerSession")
struct ServerSessionTests {
  @Test("happy path: start, enter, forward, leave, close")
  func lifecycle() async throws {
    let fake = FakeProtocolSession()
    let session = ServerSession(id: sessionID, screen: screen, protocolSession: fake)
    #expect(await session.state == .idle)
    try await session.start()
    #expect(await session.state == .ready)
    try await session.enter(at: entry)
    #expect(await session.state == .active)
    try await session.forward(keyDown)
    try await session.forward(keyUp)
    try await session.leave()
    #expect(await session.state == .ready)
    await session.close(reason: .userRequested)
    #expect(await session.state == .closed)
    #expect(
      fake.sent == [
        .enterScreen(screen: screen, position: entry), keyDown, keyUp, .leaveScreen(screen: screen),
      ])
    #expect(fake.disconnects == [.userRequested])
  }

  @Test("failure: connect failure closes without becoming ready")
  func connectFailure() async throws {
    let fake = FakeProtocolSession(connectError: resetError)
    let session = ServerSession(id: sessionID, screen: screen, protocolSession: fake)
    await #expect(throws: resetError) { try await session.start() }
    #expect(await session.state == .closed)
    #expect(fake.disconnects == [.failure(resetError)])
  }

  @Test("failure: a send failure is terminal and cleans up once")
  func sendFailure() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    try await session.enter(at: entry)
    fake.fail(keyDown, with: resetError)
    await #expect(throws: resetError) { try await session.forward(keyDown) }
    #expect(await session.state == .closed)
    await session.close(reason: .userRequested)
    #expect(fake.disconnects == [.failure(resetError)])
  }

  @Test("failure: an enter failure closes the session")
  func enterFailure() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    fake.fail(.enterScreen(screen: screen, position: entry), with: resetError)
    await #expect(throws: resetError) { try await session.enter(at: entry) }
    #expect(await session.state == .closed)
  }

  @Test("invalid: operations in the wrong state fail without side effects")
  func wrongState() async throws {
    let fake = FakeProtocolSession()
    let session = ServerSession(id: sessionID, screen: screen, protocolSession: fake)
    let precondition = CoreError(
      code: .internalFailure(.preconditionFailed), severity: .warning, retryDisposition: .never,
      cleanupDisposition: .notRequired)
    await #expect(throws: precondition) { try await session.forward(keyDown) }
    await #expect(throws: precondition) { try await session.enter(at: entry) }
    try await session.start()
    await #expect(throws: precondition) { try await session.start() }
    await #expect(throws: precondition) { try await session.forward(keyDown) }
    await #expect(throws: precondition) { try await session.leave() }
    #expect(fake.sent.isEmpty)
    #expect(await session.state == .ready)
  }

  @Test("ordering: a concurrent forward waits for the in-flight send")
  func singleWriter() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    try await session.enter(at: entry)
    fake.hold(keyDown)
    let first = Task { try await session.forward(keyDown) }
    await fake.waitUntilHeld()
    let second = Task { try await session.forward(keyUp) }
    await session.waitForQueuedWriters(count: 1)
    fake.releaseHeld()
    try await first.value
    try await second.value
    #expect(Array(fake.sent.suffix(2)) == [keyDown, keyUp])
  }

  @Test("a leave during an in-flight enter closes the session instead of leaving it entered")
  func leaveDuringPendingEnter() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    let enterEvent = KVMEvent.enterScreen(screen: screen, position: entry)
    fake.hold(enterEvent)
    let entering = Task { try await session.enter(at: entry) }
    await fake.waitUntilHeld()
    #expect(await session.state == .entering)
    try await session.leave()
    #expect(await session.state == .closed)
    fake.releaseHeld()
    await #expect(throws: CoreError.self) { try await entering.value }
    #expect(await session.state == .closed)
    #expect(fake.disconnects == [.cancellation(.superseded)])
  }

  @Test("cleanup: close is idempotent and later operations fail")
  func closeIdempotent() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    await session.close(reason: .applicationTermination)
    await session.close(reason: .userRequested)
    #expect(fake.disconnects == [.applicationTermination])
    let closed = CoreError(
      code: .lifecycle(.subsystemUnavailable), severity: .warning, retryDisposition: .never,
      cleanupDisposition: .notRequired)
    await #expect(throws: closed) { try await session.enter(at: entry) }
  }

  @Test("peer end: monitoring the event stream reports closure")
  func peerEnd() async throws {
    let fake = FakeProtocolSession()
    let session = try await readySession(fake)
    let monitor = Task { await session.monitorPeer() }
    fake.finishFromPeer()
    #expect(await monitor.value == .transportClosed)
    #expect(await session.state == .closed)
    #expect(fake.disconnects == [.transportClosed])
  }
}

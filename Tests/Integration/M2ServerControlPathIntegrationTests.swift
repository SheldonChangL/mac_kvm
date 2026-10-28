import BarrierCompatibility
import Foundation
import KVMContracts
import KVMCore
import Testing

/// In-memory connected transport standing in for an admitted client socket.
private final class PipeTransport: Transport, @unchecked Sendable {
  private let lock = NSLock()
  private var written: [UInt8] = []
  private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  let incomingBytes: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init() {
    (incomingBytes, continuation) = AsyncThrowingStream.makeStream()
  }

  var sent: [UInt8] { lock.withLock { written } }
  func feed(_ bytes: [UInt8]) { continuation.yield(Data(bytes)) }

  func waitForSent(byteCount: Int) async {
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock {
        if written.count < byteCount { waiters.append((byteCount, waiter)) }
        return written.count >= byteCount
      }
      if ready { waiter.resume() }
    }
  }

  func connect() async throws(CoreError) {}
  func send(_ data: Data) async throws(CoreError) {
    let due = lock.withLock {
      written += Array(data)
      let due = waiters.filter { written.count >= $0.count }
      waiters.removeAll { written.count >= $0.count }
      return due
    }
    for waiter in due { waiter.continuation.resume() }
  }
  func disconnect() async { continuation.finish() }
}

private final class RecordingSafety: ServerLocalInputSafety, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var stopCount: Int { lock.withLock { count } }
  func stopSuppression() throws(CoreError) { lock.withLock { count += 1 } }
  func releaseAllKeys() throws(CoreError) {}
  func releaseAllMouseButtons() throws(CoreError) {}
  func restoreLocalCursor() throws(CoreError) {}
  func clearTransientState() throws(CoreError) {}
}

// Golden client frames from BARRIER-EVID-0005 (M1-PROTOCOL-002).
private let helloBack: [UInt8] = [
  0x00, 0x00, 0x00, 0x19, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06, 0x00,
  0x00, 0x00, 0x0A, 0x6D, 0x31, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C,
]
private let dinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04, 0x5D,
  0x00, 0x00, 0x03, 0x04, 0x02, 0x52,
]

private func id(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xE2, value))
}

@Suite("M2 server control path integration")
struct M2ServerControlPathIntegrationTests {
  @Test(
    "edge enter reaches the Barrier client, pointer input follows, unsupported input fails closed"
  )
  func controlPath() async throws {
    let linux = ScreenID(rawValue: id(2))
    let pipe = PipeTransport()
    let barrier = try #require(
      BarrierServerProtocolSession(
        transport: pipe, expectedScreenNames: ["m1-control"], clock: ContinuousKVMClock(),
        handshakeTimeout: .seconds(30)))
    let session = ServerSession(
      id: SessionID(rawValue: id(1)), screen: linux, protocolSession: barrier)
    let manager = try #require(SessionManager(maximumSessions: 1))

    let starting = Task { try await session.start() }
    await pipe.waitForSent(byteCount: 15)
    pipe.feed(helloBack)
    await pipe.waitForSent(byteCount: 23)
    pipe.feed(dinf)
    try await starting.value
    try await manager.register(session)

    let entry = NormalizedPoint(x: 1, y: 0.25)
    var transition = InputStateReducer.reduce(.local, .edgeActivated(target: linux, entry: entry))
    #expect(transition.effects.contains(.sendEnter(target: linux, entry: entry)))
    try await session.enter(at: entry)
    transition = InputStateReducer.reduce(transition.state, .enterDelivered(linux))
    #expect(transition.state == .remote(linux))
    #expect(Array(pipe.sent.suffix(14).prefix(4)) == [0x43, 0x49, 0x4E, 0x4E])

    try await session.forward(.mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)))
    #expect(Array(pipe.sent.suffix(8).prefix(4)) == [0x44, 0x4D, 0x4D, 0x56])

    let written = pipe.sent.count
    let clipboard = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "m2-probe",
      contentHash: "hash")
    await #expect(throws: CoreError.self) { try await session.forward(.clipboard(clipboard)) }
    #expect(pipe.sent.count == written)
    #expect(await session.state == .closed)

    transition = InputStateReducer.reduce(transition.state, .sessionLost(linux))
    #expect(transition.state == .local)
    #expect(transition.effects.first == .disableSuppression)
    let safety = RecordingSafety()
    let outcome = await ServerFailSafe(local: safety).recoverAll(sessions: manager)
    #expect(outcome.disposition == .completed)
    #expect(safety.stopCount == 1)
    #expect(await manager.count == 0)
  }
}

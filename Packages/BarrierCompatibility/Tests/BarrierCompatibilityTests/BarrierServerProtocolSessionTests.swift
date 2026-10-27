import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

// Golden bytes copied by hand from BARRIER-EVID-0005
// (docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md).
private let hello: [UInt8] = [
  0x00, 0x00, 0x00, 0x0B, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let helloBack: [UInt8] = [
  0x00, 0x00, 0x00, 0x19, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06, 0x00,
  0x00, 0x00, 0x0A, 0x6D, 0x31, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C,
]
private let qinf: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x51, 0x49, 0x4E, 0x46]
private let dinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04, 0x5D,
  0x00, 0x00, 0x03, 0x04, 0x02, 0x52,
]
private let setup: [UInt8] =
  [0x00, 0x00, 0x00, 0x04, 0x43, 0x49, 0x41, 0x4B]
  + [0x00, 0x00, 0x00, 0x04, 0x43, 0x52, 0x4F, 0x50]
  + [0x00, 0x00, 0x00, 0x08, 0x44, 0x53, 0x4F, 0x50, 0x00, 0x00, 0x00, 0x00]
private let calv: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]
private let cout: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4F, 0x55, 0x54]

/// In-memory connected transport: the test feeds client bytes and observes
/// every server write, with a barrier instead of polling.
private final class PipeTransport: Transport, @unchecked Sendable {
  private let lock = NSLock()
  private var written: [UInt8] = []
  private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var disconnects = 0
  let incomingBytes: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init() {
    (incomingBytes, continuation) = AsyncThrowingStream.makeStream()
  }

  var sent: [UInt8] { lock.withLock { written } }
  var disconnectCount: Int { lock.withLock { disconnects } }

  func feed(_ bytes: [UInt8]) { continuation.yield(Data(bytes)) }
  func closeFromPeer() { continuation.finish() }

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

  func disconnect() async {
    lock.withLock { disconnects += 1 }
    continuation.finish()
  }
}

/// Clock whose sleeps only end on cancellation or `fire()`.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var sleepers: [Int: CheckedContinuation<Bool, Never>] = [:]
  private var arrivals: [CheckedContinuation<Void, Never>] = []
  private var nextID = 0

  func sleep(for duration: Duration) async throws(CoreError) {
    let id = lock.withLock {
      nextID += 1
      return nextID
    }
    let fired = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let waiting: [CheckedContinuation<Void, Never>]? = lock.withLock {
          if Task.isCancelled { return nil }
          sleepers[id] = continuation
          let waiting = arrivals
          arrivals = []
          return waiting
        }
        guard let waiting else {
          continuation.resume(returning: false)
          return
        }
        for arrival in waiting { arrival.resume() }
      }
    } onCancel: {
      let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
      sleeper?.resume(returning: false)
    }
    guard fired else {
      throw CoreError(
        code: .cancellation(.requested), severity: .info, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    }
  }

  func waitForSleeper() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock {
        if sleepers.isEmpty { arrivals.append(continuation) }
        return !sleepers.isEmpty
      }
      if ready { continuation.resume() }
    }
  }

  func fire() {
    let due = lock.withLock {
      let due = Array(sleepers.values)
      sleepers = [:]
      return due
    }
    for sleeper in due { sleeper.resume(returning: true) }
  }
}

private func makeSession(
  _ pipe: PipeTransport, clock: ManualClock = ManualClock(), names: Set<String> = ["m1-control"]
)
  throws -> BarrierServerProtocolSession
{
  try #require(
    BarrierServerProtocolSession(
      transport: pipe, expectedScreenNames: names, clock: clock, handshakeTimeout: .seconds(5)))
}

private func connected(_ pipe: PipeTransport) async throws -> BarrierServerProtocolSession {
  let session = try makeSession(pipe)
  let connecting = Task { try await session.connect() }
  await pipe.waitForSent(byteCount: hello.count)
  pipe.feed(helloBack)
  await pipe.waitForSent(byteCount: hello.count + qinf.count)
  pipe.feed(dinf)
  try await connecting.value
  return session
}

private let screen = ScreenID(
  rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x2A, 1)))

@Suite("M2 BarrierServerProtocolSession")
struct BarrierServerProtocolSessionTests {
  @Test("handshake writes hello, QINF and setup frames in order")
  func handshake() async throws {
    let pipe = PipeTransport()
    _ = try await connected(pipe)
    #expect(pipe.sent == hello + qinf + setup)
  }

  @Test("handshake bytes split across chunks are reassembled")
  func splitChunks() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(pipe)
    let connecting = Task { try await session.connect() }
    await pipe.waitForSent(byteCount: hello.count)
    pipe.feed(Array(helloBack.prefix(5)))
    pipe.feed(Array(helloBack.dropFirst(5)) + Array(dinf.prefix(3)))
    await pipe.waitForSent(byteCount: hello.count + qinf.count)
    pipe.feed(Array(dinf.dropFirst(3)))
    try await connecting.value
    #expect(pipe.sent == hello + qinf + setup)
  }

  @Test("enter once and leave map to CINN and COUT inside the client rectangle")
  func enterAndLeave() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let before = pipe.sent.count
    try await session.send(.enterScreen(screen: screen, position: NormalizedPoint(x: 1, y: 0.25)))
    let cinn = Array(pipe.sent[before...])
    #expect(Array(cinn.prefix(8)) == [0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E])
    #expect(Array(cinn[8..<12]) == [0x06, 0xBF, 0x01, 0x17])
    try await session.send(.leaveScreen(screen: screen))
    #expect(Array(pipe.sent.suffix(cout.count)) == cout)
    await #expect(throws: CoreError.self) {
      try await session.send(.enterScreen(screen: screen, position: NormalizedPoint(x: 1, y: 0.5)))
    }
  }

  @Test("input and clipboard fail closed without writing bytes")
  func inputFailsClosed() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let before = pipe.sent
    let unsupported: [KVMEvent] = [
      .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)),
      .mouseButton(button: .left, phase: .down),
      .scroll(deltaX: 0, deltaY: 1),
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .clipboard(
        ClipboardPayload(
          transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "probe",
          contentHash: "h")),
    ]
    for event in unsupported {
      do {
        try await session.send(event)
        Issue.record("unsupported event was accepted")
      } catch {
        #expect(error.code == .protocolViolation(.unsupportedMessage))
      }
    }
    #expect(pipe.sent == before)
  }

  @Test("client keepalives are accepted; an unexpected client frame ends the session")
  func clientFrames() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(calv)
    pipe.feed(cout)
    await #expect(throws: CoreError.self) {
      for try await _ in session.events {}
    }
    #expect(pipe.disconnectCount == 1)
  }

  @Test("handshake timeout fails closed and disconnects")
  func timeout() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try makeSession(pipe, clock: clock)
    let connecting = Task { try await session.connect() }
    await clock.waitForSleeper()
    clock.fire()
    do {
      try await connecting.value
      Issue.record("connect succeeded without a client")
    } catch {
      #expect((error as? CoreError)?.code == .timeout(.handshake))
    }
    #expect(pipe.disconnectCount == 1)
  }

  @Test("an unexpected client identity is rejected as a trust failure")
  func identityRejected() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(pipe, names: ["someone-else"])
    let connecting = Task { try await session.connect() }
    await pipe.waitForSent(byteCount: hello.count)
    pipe.feed(helloBack)
    do {
      try await connecting.value
      Issue.record("unknown identity was accepted")
    } catch {
      #expect((error as? CoreError)?.code == .security(.trustRejected))
    }
    #expect(pipe.sent == hello)
  }

  @Test("disconnect is idempotent and later sends fail")
  func disconnectIdempotent() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    await session.disconnect(reason: .userRequested)
    await session.disconnect(reason: .userRequested)
    #expect(pipe.disconnectCount == 1)
    await #expect(throws: CoreError.self) { try await session.send(.leaveScreen(screen: screen)) }
  }
}

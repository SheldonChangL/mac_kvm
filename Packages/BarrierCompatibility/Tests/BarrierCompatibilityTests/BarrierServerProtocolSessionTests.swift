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

/// Clock whose sleeps only end on cancellation or `fire()`. Sleepers can be
/// selected by duration, so the handshake timeout and the keepalive interval
/// never fire each other.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var sleepers:
    [Int: (duration: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
  private var arrivals: [(duration: Duration?, continuation: CheckedContinuation<Void, Never>)] =
    []
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
          sleepers[id] = (duration, continuation)
          let matching = arrivals.filter { $0.duration == nil || $0.duration == duration }
          arrivals.removeAll { $0.duration == nil || $0.duration == duration }
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

  /// Completes once a sleeper exists, of `duration` when given.
  func waitForSleeper(duration: Duration? = nil) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        let present = sleepers.values.contains { duration == nil || $0.duration == duration }
        if !present { arrivals.append((duration, continuation)) }
        return present
      }
      if ready { continuation.resume() }
    }
  }

  /// Ends every sleep, or only those of `duration` when given.
  func fire(duration: Duration? = nil) {
    let due = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
      let selected = sleepers.filter { duration == nil || $0.value.duration == duration }
      for id in selected.keys { sleepers.removeValue(forKey: id) }
      return selected.values.map(\.continuation)
    }
    for sleeper in due { sleeper.resume(returning: true) }
  }
}

/// The keepalive interval observed in the M2-022 capture.
private let keepaliveInterval = Duration.seconds(3)

/// `DINF` for a 1600 x 900 client at the origin, as sent in the M2-022 capture.
private let dinf1600: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0x00, 0x00, 0x00, 0x00, 0x06, 0x40, 0x03, 0x84,
  0x00, 0x00, 0x03, 0x20, 0x01, 0xC2,
]
private let cnop: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4E, 0x4F, 0x50]

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// The client's `CCLP` and `DCLP` frames from the M2-022 clipboard capture, in
/// order; `DCLP` data is zero-filled by the fixture's sanitization.
private func capturedClientClipboardFrames() throws -> [[UInt8]] {
  let url = repositoryRoot().appendingPathComponent(
    "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/"
      + "client-clipboard-keepalive-capture.json")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: [[UInt8]] = []
  for observation in observations
  where observation["direction"] as? String == "client-to-server" {
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    let frame = [UInt8](try #require(Data(base64Encoded: base64)))
    let code = frame.dropFirst(4).prefix(4)
    if code.elementsEqual("CCLP".utf8) || code.elementsEqual("DCLP".utf8) {
      frames.append(frame)
    }
  }
  return frames
}
/// `DMMV` at (1599, 899): the far corner of a 1600 x 900 client.
private let cornerMove: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x4D, 0x4D, 0x56, 0x06, 0x3F, 0x03, 0x83,
]

private func makeSession(
  _ pipe: PipeTransport, clock: ManualClock = ManualClock(), names: Set<String> = ["m1-control"]
)
  throws -> BarrierServerProtocolSession
{
  try #require(
    BarrierServerProtocolSession(
      transport: pipe, expectedScreenNames: names, clock: clock, handshakeTimeout: .seconds(5)))
}

private func connected(
  _ pipe: PipeTransport, clock: ManualClock = ManualClock(), screenInfo: [UInt8] = dinf
) async throws -> BarrierServerProtocolSession {
  let session = try makeSession(pipe, clock: clock)
  let connecting = Task { try await session.connect() }
  await pipe.waitForSent(byteCount: hello.count)
  pipe.feed(helloBack)
  await pipe.waitForSent(byteCount: hello.count + qinf.count)
  pipe.feed(screenInfo)
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

  @Test("enter, leave and enter again map to CINN and COUT with the captured sequence")
  func enterAndLeave() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let before = pipe.sent.count
    try await session.send(.enterScreen(screen: screen, position: NormalizedPoint(x: 1, y: 0.25)))
    let cinn = Array(pipe.sent[before...])
    #expect(Array(cinn.prefix(8)) == [0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E])
    #expect(Array(cinn[8..<12]) == [0x06, 0xBF, 0x01, 0x17])
    #expect(Array(cinn[12..<18]) == [0, 0, 0, 1, 0, 0])
    try await session.send(.leaveScreen(screen: screen))
    #expect(Array(pipe.sent.suffix(cout.count)) == cout)
    try await session.send(.enterScreen(screen: screen, position: NormalizedPoint(x: 1, y: 0.25)))
    #expect(Array(pipe.sent.suffix(6)) == [0, 0, 0, 3, 0, 0])
  }

  @Test("input events are written as the encoder's frames; clipboard and unknown keys fail closed")
  func inputEncodes() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe, screenInfo: dinf1600)
    let encoder = BarrierServerInputEncoder(
      screen: BarrierScreenInfo(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450))
    let a = KVMEvent.key(key: .letter(0), phase: .down, modifiers: ModifierState())
    let cases: [(KVMEvent, [UInt8])] = [
      (
        .mouseMove(position: NormalizedPoint(x: 10.0 / 1599, y: 450.0 / 899)),
        encoder.pointer(to: NormalizedPoint(x: 10.0 / 1599, y: 450.0 / 899))
      ),
      (.mouseButton(button: .left, phase: .down), encoder.button(.left, phase: .down)),
      (.scroll(deltaX: 0, deltaY: 1), try #require(encoder.scroll(deltaX: 0, deltaY: 1))),
      (a, try encoder.key(.letter(0), phase: .down, modifiers: ModifierState()).flatMap { $0 }),
    ]
    for (event, frame) in cases {
      let before = pipe.sent.count
      try await session.send(event)
      #expect(Array(pipe.sent[before...]) == frame)
    }
    let quiet = pipe.sent
    try await session.send(.scroll(deltaX: 0, deltaY: 0))
    #expect(pipe.sent == quiet)

    let unsupported: [KVMEvent] = [
      .key(key: .unknown(42), phase: .down, modifiers: ModifierState()),
      .clipboard(
        ClipboardPayload(
          transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "probe",
          contentHash: "h")),
    ]
    for event in unsupported {
      #expect(!BarrierServerProtocolSession.canSend(event))
      do {
        try await session.send(event)
        Issue.record("unsupported event was accepted")
      } catch {
        #expect(error.code == .protocolViolation(.unsupportedMessage))
      }
    }
    #expect(pipe.sent == quiet)
    for (event, _) in cases { #expect(BarrierServerProtocolSession.canSend(event)) }
  }

  @Test("client clipboard frames are ignored and the session stays usable")
  func clientClipboardIgnored() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let clipboard = try capturedClientClipboardFrames()
    #expect(clipboard.count == 4)
    pipe.feed(clipboard.flatMap { $0 } + cnop)
    await session.waitForReceivedFrames(atLeast: clipboard.count + 1)
    try await session.send(.leaveScreen(screen: screen))
    #expect(Array(pipe.sent.suffix(cout.count)) == cout)
    #expect(pipe.disconnectCount == 0)
  }

  @Test("a screen-info update rescales later pointer frames")
  func screenInfoUpdate() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(dinf1600)
    await session.waitForReceivedFrames(atLeast: 1)
    #expect(session.clientScreen == BarrierClientScreen(width: 1600, height: 900))
    let before = pipe.sent.count
    try await session.send(.mouseMove(position: NormalizedPoint(x: 1, y: 1)))
    #expect(Array(pipe.sent[before...]) == cornerMove)
  }

  @Test("keepalive: CALV every interval while the client answers")
  func keepaliveWhileAnswered() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try await connected(pipe, clock: clock)
    for round in 1...4 {
      await clock.waitForSleeper(duration: keepaliveInterval)
      let before = pipe.sent.count
      clock.fire(duration: keepaliveInterval)
      await pipe.waitForSent(byteCount: before + calv.count)
      #expect(Array(pipe.sent[before...]) == calv)
      pipe.feed(calv)
      await session.waitForReceivedFrames(atLeast: round)
    }
    #expect(pipe.disconnectCount == 0)
  }

  @Test("keepalive: a client silent for three intervals is dropped as a keepalive timeout")
  func silentClientTimesOut() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try await connected(pipe, clock: clock)
    let afterSetup = pipe.sent.count
    for _ in 1...3 {
      await clock.waitForSleeper(duration: keepaliveInterval)
      clock.fire(duration: keepaliveInterval)
    }
    do {
      for try await _ in session.events {}
      Issue.record("a silent client was not dropped")
    } catch {
      #expect((error as? CoreError)?.code == .timeout(.keepalive))
    }
    #expect(pipe.disconnectCount == 1)
    #expect(Array(pipe.sent[afterSetup...]) == calv + calv)
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

  @Test("cancelling connect fails closed instead of disabling the timeout")
  func cancelledConnect() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try makeSession(pipe, clock: clock)
    let connecting = Task { try await session.connect() }
    await clock.waitForSleeper()
    connecting.cancel()
    do {
      try await connecting.value
      Issue.record("cancelled connect succeeded")
    } catch {
      #expect((error as? CoreError)?.code == .cancellation(.requested))
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

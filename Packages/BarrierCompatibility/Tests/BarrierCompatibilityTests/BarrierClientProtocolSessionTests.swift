import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

// M1-029-FOLLOWUP-001: the client-role Barrier session. Golden bytes are copied by hand from
// docs/components/M1-029-barrier-client-handshake.md (hello, HelloBack `m1-client`),
// docs/components/M1-031-barrier-control-messages.md (control frames, DINF) and
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md; the replay test reads
// the M2-022 server-input capture (BARRIER-EVID-0006) from Tests/Fixtures/Barrier/.
// Every wait is a cancellation-aware barrier and the suite has a time limit, so a broken
// session fails a test instead of hanging the run.

private typealias DropReason = BarrierClientSessionDiagnostics.DropReason

// MARK: - Golden frames

private let hello: [UInt8] = [
  0x00, 0x00, 0x00, 0x0B, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
/// HelloBack for the synthetic screen name `m1-client` (M1-029, BARRIER-EVID-0004).
private let helloBack: [UInt8] = [
  0x00, 0x00, 0x00, 0x18, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06, 0x00,
  0x00, 0x00, 0x09, 0x6D, 0x31, 0x2D, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
]
private let qinf: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x51, 0x49, 0x4E, 0x46]
/// The M1-031 golden DINF: origin (-1920, 0), 3648 x 1117, cursor (772, 594).
private let goldenDinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04, 0x5D,
  0x00, 0x00, 0x03, 0x04, 0x02, 0x52,
]
/// The client DINF of the M2-022 captures: origin (0, 0), 1600 x 900, cursor (800, 450).
private let captureDinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0x00, 0x00, 0x00, 0x00, 0x06, 0x40, 0x03, 0x84,
  0x00, 0x00, 0x03, 0x20, 0x01, 0xC2,
]
private let ciak: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x49, 0x41, 0x4B]
private let crop: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x52, 0x4F, 0x50]
private let dsop: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x53, 0x4F, 0x50, 0x00, 0x00, 0x00, 0x00,
]
private let calv: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]
private let cout: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4F, 0x55, 0x54]
private let cnop: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4E, 0x4F, 0x50]

private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

private func be32(_ value: UInt32) -> [UInt8] {
  [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
}

/// The frames in order, as one byte stream.
private func joined(_ frames: [UInt8]...) -> [UInt8] { frames.flatMap { $0 } }

/// A frame: the 4-byte length, the token and the body.
private func frame(_ token: String, _ body: [UInt8] = []) -> [UInt8] {
  let payload = Array(token.utf8) + body
  return be32(UInt32(payload.count)) + payload
}

private func cinn(x: UInt16, y: UInt16, sequence: UInt32, mask: UInt16 = 0) -> [UInt8] {
  frame("CINN", be16(x) + be16(y) + be32(sequence) + be16(mask))
}

private func dmmv(x: UInt16, y: UInt16) -> [UInt8] { frame("DMMV", be16(x) + be16(y)) }
private func dmdn(_ value: UInt8) -> [UInt8] { frame("DMDN", [value]) }
private func dmup(_ value: UInt8) -> [UInt8] { frame("DMUP", [value]) }

private func dmwm(x: Int16, y: Int16) -> [UInt8] {
  frame("DMWM", be16(UInt16(bitPattern: x)) + be16(UInt16(bitPattern: y)))
}

private func dkdn(_ identifier: UInt16, mask: UInt16 = 0, button: UInt16) -> [UInt8] {
  frame("DKDN", be16(identifier) + be16(mask) + be16(button))
}

private func dkup(_ identifier: UInt16, mask: UInt16 = 0, button: UInt16) -> [UInt8] {
  frame("DKUP", be16(identifier) + be16(mask) + be16(button))
}

private func dkrp(_ identifier: UInt16, mask: UInt16 = 0, button: UInt16) -> [UInt8] {
  frame("DKRP", be16(identifier) + be16(mask) + be16(1) + be16(button))
}

private func cclp(id: UInt8, sequence: UInt32) -> [UInt8] { frame("CCLP", [id] + be32(sequence)) }

private func dclp(id: UInt8 = 0, sequence: UInt32 = 0, mark: UInt8, data: [UInt8]) -> [UInt8] {
  frame("DCLP", joined([id], be32(sequence), [mark], be32(UInt32(data.count)), data))
}

private func dinf(_ screen: BarrierLocalScreen) -> [UInt8] {
  BarrierClientControlEncoder.screenInfo(screen.info)
}

/// A marshalled clipboard with `text` and a second format of `html` bytes, as Barrier 2.4 sends
/// one (about 2.5 times the text in the M2-022 chunk measurement).
private func marshalled(text: String, html: Int) -> [UInt8] {
  let bytes = Array(text.utf8)
  return be32(2) + be32(0) + be32(UInt32(bytes.count)) + bytes + be32(1) + be32(UInt32(html))
    + [UInt8](repeating: 0x68, count: html)
}

private func transfer(_ text: String, id: UInt8 = 0, sequence: UInt32 = 0) -> [UInt8] {
  BarrierClipboard.frames(id: id, sequence: sequence, data: BarrierClipboard.marshal(text: text))
    .flatMap { $0 }
}

// MARK: - Test doubles

private func coreError(_ code: CoreErrorCode, retry: RetryDisposition = .backoff) -> CoreError {
  CoreError(code: code, severity: .error, retryDisposition: retry, cleanupDisposition: .notRequired)
}

/// In-memory transport: the test feeds server bytes and observes every client write through
/// cancellation-aware barriers.
private final class PipeTransport: Transport, @unchecked Sendable {
  private enum Condition {
    case sentBytes(Int)
    case sendCalls(Int)
    case connectCalls(Int)
  }

  private let lock = NSLock()
  private var written: [UInt8] = []
  private var sends = 0
  private var connects = 0
  private var disconnects = 0
  private var connectFailure: CoreError?
  private var hangsOnConnect = false
  private var connectWaiter: CheckedContinuation<Void, Never>?
  private var holdsNextSend = false
  private var heldSend: CheckedContinuation<Void, Never>?
  private var nextSendFailure: CoreError?
  private var nextWaiterID = 0
  private var waiters:
    [(id: Int, condition: Condition, continuation: CheckedContinuation<Void, Never>)] = []
  let incomingBytes: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

  init() {
    (incomingBytes, continuation) = AsyncThrowingStream.makeStream()
  }

  var sent: [UInt8] { lock.withLock { written } }
  var disconnectCount: Int { lock.withLock { disconnects } }

  func feed(_ bytes: [UInt8]) { continuation.yield(Data(bytes)) }
  func closeFromPeer() { continuation.finish() }
  func failConnect(with error: CoreError) { lock.withLock { connectFailure = error } }
  func hangConnectUntilDisconnect() { lock.withLock { hangsOnConnect = true } }
  func holdNextSend() { lock.withLock { holdsNextSend = true } }
  func failNextSend(with error: CoreError) { lock.withLock { nextSendFailure = error } }

  func releaseHeldSend() {
    let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      defer { heldSend = nil }
      return heldSend
    }
    held?.resume()
  }

  func waitForSent(byteCount: Int) async { await wait(for: .sentBytes(byteCount)) }
  func waitForSendCalls(_ count: Int) async { await wait(for: .sendCalls(count)) }
  func waitForConnectCalls(_ count: Int) async { await wait(for: .connectCalls(count)) }

  func connect() async throws(CoreError) {
    let (failure, hangs) = lock.withLock { () -> (CoreError?, Bool) in
      connects += 1
      return (connectFailure, hangsOnConnect)
    }
    resumeSatisfiedWaiters()
    if let failure { throw failure }
    guard hangs else { return }
    await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
      let disconnected = lock.withLock { () -> Bool in
        guard disconnects == 0 else { return true }
        connectWaiter = waiter
        return false
      }
      if disconnected { waiter.resume() }
    }
    throw coreError(.transport(.disconnected))
  }

  func send(_ data: Data) async throws(CoreError) {
    let (failure, holds) = lock.withLock { () -> (CoreError?, Bool) in
      if let failure = nextSendFailure {
        nextSendFailure = nil
        sends += 1
        return (failure, false)
      }
      if holdsNextSend {
        holdsNextSend = false
        return (nil, true)
      }
      sends += 1
      written += Array(data)
      return (nil, false)
    }
    if holds {
      await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
        lock.withLock {
          sends += 1
          heldSend = waiter
        }
        resumeSatisfiedWaiters()
      }
      let disconnected = lock.withLock { () -> Bool in
        guard disconnects == 0 else { return true }
        written += Array(data)
        return false
      }
      resumeSatisfiedWaiters()
      if disconnected { throw coreError(.transport(.disconnected)) }
      return
    }
    resumeSatisfiedWaiters()
    if let failure { throw failure }
  }

  func disconnect() async {
    let (waiter, held) = lock.withLock {
      () -> (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Never>?) in
      disconnects += 1
      defer {
        connectWaiter = nil
        heldSend = nil
      }
      return (connectWaiter, heldSend)
    }
    waiter?.resume()
    held?.resume()
    continuation.finish()
  }

  private func satisfied(_ condition: Condition) -> Bool {
    switch condition {
    case .sentBytes(let count): written.count >= count
    case .sendCalls(let count): sends >= count
    case .connectCalls(let count): connects >= count
    }
  }

  private func resumeSatisfiedWaiters() {
    let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      let due = waiters.filter { satisfied($0.condition) }.map(\.continuation)
      waiters.removeAll { satisfied($0.condition) }
      return due
    }
    for waiter in due { waiter.resume() }
  }

  /// Completes once `condition` holds, or when the waiting task is cancelled.
  private func wait(for condition: Condition) async {
    let id = lock.withLock { () -> Int in
      nextWaiterID += 1
      return nextWaiterID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          guard !satisfied(condition), !Task.isCancelled else { return true }
          waiters.append((id, condition, continuation))
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

/// A fake `KVMClock`: sleeps end only on `fire()` or cancellation. Sleepers are selected by
/// duration, so the handshake timeout and the keepalive check never fire each other.
private final class ManualClock: KVMClock, @unchecked Sendable {
  private let lock = NSLock()
  private var sleepers:
    [Int: (duration: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
  private var arrivals:
    [(id: Int, duration: Duration?, continuation: CheckedContinuation<Void, Never>)] = []
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
    guard fired else { throw coreError(.cancellation(.requested), retry: .never) }
  }

  /// Completes once a sleeper of `duration` (any, when `nil`) exists, or on cancellation.
  func waitForSleeper(duration: Duration? = nil) async {
    let id = lock.withLock { () -> Int in
      nextID += 1
      return nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = lock.withLock { () -> Bool in
          let present = sleepers.values.contains { duration == nil || $0.duration == duration }
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

  /// Ends every sleep of `duration` (all sleeps, when `nil`).
  func fire(duration: Duration? = nil) {
    let due = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
      let selected = sleepers.filter { duration == nil || $0.value.duration == duration }
      for id in selected.keys { sleepers.removeValue(forKey: id) }
      return selected.values.map(\.continuation)
    }
    for sleeper in due { sleeper.resume(returning: true) }
  }
}

// MARK: - Helpers

private let handshakeTimeout = Duration.seconds(5)
/// The session checks for server frames once a second (first-party keepalive policy).
private let keepaliveTick = Duration.seconds(1)
private let localScreen = ScreenID(
  rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x29, 1)))

private func screen(
  _ originX: Int, _ originY: Int, _ width: Int, _ height: Int, _ cursorX: Int, _ cursorY: Int
) throws -> BarrierLocalScreen {
  try #require(
    BarrierLocalScreen(
      originX: originX, originY: originY, width: width, height: height, cursorX: cursorX,
      cursorY: cursorY))
}

private func captureScreen() throws -> BarrierLocalScreen { try screen(0, 0, 1600, 900, 800, 450) }

private func moved(_ x: Double, _ y: Double) -> KVMEvent {
  .mouseMove(position: NormalizedPoint(x: x / 1599, y: y / 899))
}

private func entered(_ x: Double, _ y: Double) -> KVMEvent {
  .enterScreen(screen: localScreen, position: NormalizedPoint(x: x / 1599, y: y / 899))
}

private func key(_ identifier: UInt16) -> VirtualKey {
  BarrierVirtualKeyMapper.virtualKey(for: BarrierKeyIdentifier(rawValue: identifier))
}

private func makeSession(
  _ pipe: PipeTransport, clock: ManualClock = ManualClock(), name: String = "m1-client",
  screen: BarrierLocalScreen? = nil
) throws -> BarrierClientProtocolSession {
  try #require(
    BarrierClientProtocolSession(
      transport: pipe, screenName: name, localScreen: localScreen,
      screen: try screen ?? captureScreen(), clock: clock, handshakeTimeout: handshakeTimeout))
}

/// A session past setup: hello answered with HelloBack, QINF with DINF, then CIAK, CROP and
/// DSOP handled (three frames after setup).
private func connected(
  _ pipe: PipeTransport, clock: ManualClock = ManualClock(), screen: BarrierLocalScreen? = nil
) async throws -> BarrierClientProtocolSession {
  let session = try makeSession(pipe, clock: clock, screen: screen)
  pipe.feed(hello + qinf)
  try await session.connect()
  pipe.feed(ciak + crop + dsop)
  await session.waitForReceivedFrames(atLeast: 3)
  return session
}

/// Awaits `task`, cancelling it when the waiting test is cancelled (the suite's time limit).
private func value(of task: Task<Void, any Error>) async throws {
  try await withTaskCancellationHandler {
    try await task.value
  } onCancel: {
    task.cancel()
  }
}

/// Every event until the stream ends, and the error it ended with.
private func drain(
  _ session: BarrierClientProtocolSession
) async -> (events: [KVMEvent], error: CoreError?) {
  var events: [KVMEvent] = []
  do {
    for try await event in session.events { events.append(event) }
    return (events, nil)
  } catch {
    return (events, error as? CoreError ?? coreError(.internalFailure(.unclassified)))
  }
}

private func expectFailure(
  _ code: CoreErrorCode, sourceLocation: SourceLocation = #_sourceLocation,
  _ body: () async throws -> Void
) async {
  do {
    try await body()
    Issue.record("expected \(code)", sourceLocation: sourceLocation)
  } catch {
    #expect((error as? CoreError)?.code == code, sourceLocation: sourceLocation)
  }
}

/// Whether `first` completes before `second`; the other is cancelled. Both must be
/// cancellation-aware barriers.
private func completesFirst(
  _ first: @escaping @Sendable () async -> Void,
  before second: @escaping @Sendable () async -> Void
) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await first()
      return true
    }
    group.addTask {
      await second()
      return false
    }
    let winner = await group.next() ?? false
    group.cancelAll()
    return winner
  }
}

/// Feeds `bytes` and then a CALV, and reports whether the session closed before it answered
/// that CALV, so a session that wrongly goes on fails at once instead of at the time limit.
private func closesBeforeAnswering(
  _ bytes: [UInt8], session: BarrierClientProtocolSession, pipe: PipeTransport
) async -> Bool {
  let answered = pipe.sent.count + calv.count
  pipe.feed(bytes + calv)
  return await completesFirst {
    await session.waitForReceivedFrames(atLeast: .max)
  } before: {
    await pipe.waitForSent(byteCount: answered)
  }
}

/// True when `value`, or any node reachable from it, is a string, a byte array, a fixed-width
/// integer (the shape of a wire value) or a class instance. Only `Int` counts and payload-free
/// enums pass.
private func containsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
  if value is UInt8 || value is Int8 || value is UInt16 || value is Int16 || value is UInt32
    || value is Int32 || value is UInt64 || value is Int64 || value is UInt
  {
    return true
  }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { containsSensitiveShape($0.value) }
}

/// A small deterministic generator for the random key streams.
private struct SplitMix64 {
  var state: UInt64

  mutating func next(below bound: Int) -> Int {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    value ^= value >> 31
    return Int(value % UInt64(bound))
  }
}

// MARK: - The M2-022 server stream

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

private func token(_ frame: [UInt8]) -> String {
  String(decoding: frame.dropFirst(4).prefix(4), as: UTF8.self)
}

/// The server-input capture's frames in order, split by direction.
private func serverInputCapture() throws -> (server: [[UInt8]], client: [[UInt8]]) {
  let url = repositoryRoot().appendingPathComponent(
    "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var server: [[UInt8]] = []
  var client: [[UInt8]] = []
  for observation in observations {
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    let bytes = [UInt8](try #require(Data(base64Encoded: base64)))
    if observation["direction"] as? String == "client-to-server" {
      client.append(bytes)
    } else {
      server.append(bytes)
    }
  }
  return (server, client)
}

/// The key events the capture's key frames must produce, from an independent pairing model of
/// BARRIER-EVID-0006-CLAIM-004: an up and a repeat take the identifier of the press of the
/// same button; a repeat of a button that is not held is never yielded.
private func expectedKeyEvents(_ frames: [[UInt8]]) -> [KVMEvent] {
  var held: [UInt16: UInt16] = [:]
  var events: [KVMEvent] = []
  for frame in frames where ["DKDN", "DKUP", "DKRP"].contains(token(frame)) {
    let body = Array(frame.dropFirst(8))
    let identifier = UInt16(body[0]) << 8 | UInt16(body[1])
    let mask = UInt16(body[2]) << 8 | UInt16(body[3])
    let button = UInt16(body[body.count - 2]) << 8 | UInt16(body[body.count - 1])
    let modifiers = ModifierState(
      shift: mask & 0x0001 != 0, control: mask & 0x0002 != 0, option: mask & 0x0004 != 0,
      command: mask & 0x0010 != 0, capsLock: mask & 0x1000 != 0)
    switch token(frame) {
    case "DKDN":
      let press = held[button] ?? identifier
      held[button] = press
      events.append(.key(key: key(press), phase: .down, modifiers: modifiers))
    case "DKUP":
      let press = held.removeValue(forKey: button) ?? identifier
      events.append(.key(key: key(press), phase: .up, modifiers: modifiers))
    default:
      guard let press = held[button] else { continue }
      events.append(.key(key: key(press), phase: .repeatKey, modifiers: modifiers))
    }
  }
  return events
}

/// Replays the capture's server frames into a session named like the captured client and
/// returns what it wrote, what it yielded and its diagnostics.
private func replayServerInputCapture() async throws -> (
  sent: [UInt8], events: [KVMEvent], diagnostics: BarrierClientSessionDiagnostics
) {
  let capture = try serverInputCapture()
  let pipe = PipeTransport()
  let session = try makeSession(pipe, name: "capclient")
  pipe.feed(capture.server.flatMap { $0 })
  pipe.closeFromPeer()
  try await session.connect()
  let (events, error) = await drain(session)
  #expect(error == nil)
  return (pipe.sent, events, session.diagnostics)
}

// MARK: - Tests

@Suite("M1-029-FOLLOWUP-001 BarrierClientProtocolSession", .timeLimit(.minutes(1)))
struct BarrierClientProtocolSessionTests {
  // MARK: Handshake

  @Test func handshakeWritesTheGoldenHelloBackAndDinfAndAcceptsTheSetupFrames() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(
      pipe, screen: try screen(-1920, 0, 3648, 1117, 772, 594))
    let connecting = Task { try await session.connect() }
    pipe.feed(hello)
    await pipe.waitForSent(byteCount: helloBack.count)
    #expect(pipe.sent == helloBack)
    pipe.feed(qinf)
    try await value(of: connecting)
    #expect(pipe.sent == helloBack + goldenDinf)
    pipe.feed(ciak + crop + dsop)
    await session.waitForReceivedFrames(atLeast: 3)
    #expect(pipe.sent == helloBack + goldenDinf)
    #expect(pipe.disconnectCount == 0)
    await session.disconnect(reason: .userRequested)
    let (events, error) = await drain(session)
    #expect(events.isEmpty)
    #expect(error == nil)
  }

  @Test func splitAndCoalescedChunksAreReassembled() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(pipe)
    let connecting = Task { try await session.connect() }
    for byte in hello { pipe.feed([byte]) }
    await pipe.waitForSent(byteCount: helloBack.count)
    let move = dmmv(x: 10, y: 450)
    var coalesced = joined(qinf, ciak, crop, dsop, calv)
    coalesced += cinn(x: 0, y: 450, sequence: 1)
    coalesced += Array(move.prefix(3))
    pipe.feed(coalesced)
    try await value(of: connecting)
    pipe.feed(Array(move[3..<7]))
    pipe.feed(Array(move[7...]))
    var events = session.events.makeAsyncIterator()
    #expect(try await events.next() == entered(0, 450))
    #expect(try await events.next() == moved(10, 450))
    // CIAK, CROP, DSOP, CALV, CINN and DMMV after setup.
    await session.waitForReceivedFrames(atLeast: 6)
    #expect(pipe.sent == helloBack + captureDinf + calv)
  }

  @Test func theLatestScreenBeforeQinfIsTheOneReported() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(pipe)
    let smaller = try screen(0, 0, 800, 600, 400, 300)
    try await session.updateScreen(smaller)
    #expect(pipe.sent.isEmpty)
    pipe.feed(hello + qinf)
    try await session.connect()
    #expect(pipe.sent == helloBack + dinf(smaller))
  }

  @Test func anUnsupportedServerHelloIsRejectedBeforeAnyHelloBack() async throws {
    let marker: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
    let cases: [(name: String, payload: [UInt8], code: CoreErrorCode)] = [
      ("version 1.5", marker + [0x00, 0x01, 0x00, 0x05], .protocolViolation(.unsupportedVersion)),
      (
        "another marker", Array("Synergy".utf8) + [0, 1, 0, 6],
        .protocolViolation(.unsupportedVersion)
      ),
      ("a trailing byte", marker + [0x00, 0x01, 0x00, 0x06, 0x00], .protocolViolation(.malformed)),
      ("a truncated version", marker + [0x00, 0x01], .protocolViolation(.malformed)),
      ("QINF first", Array("QINF".utf8), .protocolViolation(.unsupportedVersion)),
    ]
    for testCase in cases {
      let pipe = PipeTransport()
      let session = try makeSession(pipe)
      pipe.feed(be32(UInt32(testCase.payload.count)) + testCase.payload)
      await expectFailure(testCase.code) { try await session.connect() }
      #expect(pipe.sent.isEmpty, "\(testCase.name)")
      #expect(pipe.disconnectCount == 1, "\(testCase.name)")
    }
  }

  @Test func inputBeforeTheScreenIsReportedFailsClosed() async throws {
    let frames = [
      dmmv(x: 0, y: 0), dmdn(1), dmwm(x: 0, y: 120), dkdn(0x61, button: 38),
      dclp(mark: 1, data: Array("4".utf8)), cinn(x: 0, y: 0, sequence: 1),
    ]
    for early in frames {
      let pipe = PipeTransport()
      let session = try makeSession(pipe)
      pipe.feed(hello + early + qinf)
      await expectFailure(.protocolViolation(.invariantViolation)) { try await session.connect() }
      #expect(pipe.sent == helloBack, "\(token(early))")
      #expect(pipe.disconnectCount == 1, "\(token(early))")
    }
  }

  @Test func aServerThatNeverCompletesSetupTimesOut() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try makeSession(pipe, clock: clock)
    let connecting = Task { try await session.connect() }
    pipe.feed(hello)
    await pipe.waitForSent(byteCount: helloBack.count)
    await clock.waitForSleeper(duration: handshakeTimeout)
    clock.fire(duration: handshakeTimeout)
    do {
      try await value(of: connecting)
      Issue.record("connect succeeded without QINF")
    } catch {
      #expect((error as? CoreError)?.code == .timeout(.handshake))
      #expect((error as? CoreError)?.retryDisposition == .backoff)
    }
    #expect(pipe.sent == helloBack)
    #expect(pipe.disconnectCount == 1)
  }

  @Test func cancellingConnectFailsClosedWhetherTheTransportOrTheServerIsSlow() async throws {
    for hangsInTransport in [false, true] {
      let pipe = PipeTransport()
      if hangsInTransport { pipe.hangConnectUntilDisconnect() }
      let clock = ManualClock()
      let session = try makeSession(pipe, clock: clock)
      let connecting = Task { try await session.connect() }
      await pipe.waitForConnectCalls(1)
      await clock.waitForSleeper(duration: handshakeTimeout)
      connecting.cancel()
      do {
        try await value(of: connecting)
        Issue.record("a cancelled connect succeeded")
        await session.disconnect(reason: .userRequested)
      } catch {
        #expect((error as? CoreError)?.code == .cancellation(.requested))
      }
      #expect(pipe.disconnectCount == 1)
      #expect(pipe.sent.isEmpty)
      let (events, error) = await drain(session)
      #expect(events.isEmpty)
      #expect(error?.code == .cancellation(.requested))
    }
  }

  @Test func aTransportConnectFailurePassesThroughUnchanged() async throws {
    let pipe = PipeTransport()
    let refused = coreError(.transport(.refused))
    pipe.failConnect(with: refused)
    let session = try makeSession(pipe)
    do {
      try await session.connect()
      Issue.record("connect succeeded on a refused transport")
    } catch {
      #expect(error == refused)
    }
    #expect(pipe.sent.isEmpty)
  }

  @Test func theServerClosingDuringSetupFailsConnect() async throws {
    let pipe = PipeTransport()
    let session = try makeSession(pipe)
    pipe.feed(hello)
    pipe.closeFromPeer()
    do {
      try await session.connect()
      Issue.record("connect succeeded on a closed stream")
    } catch {
      #expect(error.code == .transport(.disconnected))
      #expect(error.retryDisposition == .backoff)
    }
  }

  @Test func connectIsSingleUse() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    await expectFailure(.internalFailure(.preconditionFailed)) { try await session.connect() }
    #expect(pipe.disconnectCount == 0)
  }

  @Test func invalidConfigurationIsRejectedAtConstruction() throws {
    let pipe = PipeTransport()
    let good = try captureScreen()
    func make(_ name: String, _ timeout: Duration) -> BarrierClientProtocolSession? {
      BarrierClientProtocolSession(
        transport: pipe, screenName: name, localScreen: localScreen, screen: good,
        clock: ManualClock(), handshakeTimeout: timeout)
    }
    #expect(make("m1-client", .seconds(5)) != nil)
    #expect(make(String(repeating: "a", count: 64), .seconds(5)) != nil)
    #expect(make(String(repeating: "a", count: 65), .seconds(5)) == nil)
    #expect(make("", .seconds(5)) == nil)
    #expect(make("m1 client", .seconds(5)) == nil)
    #expect(make("m1-client", .zero) == nil)
    #expect(make("m1-client", .seconds(-1)) == nil)

    #expect(
      BarrierLocalScreen(originX: 0, originY: 0, width: 1, height: 1, cursorX: 0, cursorY: 0) != nil
    )
    let invalid: [(Int, Int, Int, Int, Int, Int)] = [
      (0, 0, 0, 900, 0, 0), (0, 0, 1600, 0, 0, 0), (0, 0, 0x8000, 900, 0, 0),
      (0, 0, 1600, 900, 1600, 0), (0, 0, 1600, 900, 0, 900), (0, 0, 1600, 900, -1, 0),
      (0, 0, 1600, 900, 0x8000, 0), (40_000, 0, 1600, 900, 0, 0), (0, -40_000, 1600, 900, 0, 0),
      (100, 100, 1600, 900, 99, 100),
    ]
    for values in invalid {
      #expect(
        BarrierLocalScreen(
          originX: values.0, originY: values.1, width: values.2, height: values.3,
          cursorX: values.4, cursorY: values.5) == nil, "\(values)")
    }
  }

  // MARK: The M2-022 server stream

  @Test func theM2022ServerStreamReplaysToTheExpectedEvents() async throws {
    let capture = try serverInputCapture()
    let (sent, events, diagnostics) = try await replayServerInputCapture()

    // The session writes the captured client's frames, except the CNOP it does not send.
    #expect(sent == capture.client.filter { token($0) != "CNOP" }.flatMap { $0 })

    // Every key frame lies between the last wheel frame and the first leave, with only CALV
    // in between, so the key events follow the wheel events directly.
    let keyTokens = ["DKDN", "DKUP", "DKRP"]
    let firstKey = try #require(capture.server.firstIndex { keyTokens.contains(token($0)) })
    let firstLeave = try #require(capture.server.firstIndex { token($0) == "COUT" })
    #expect(
      capture.server[firstKey..<firstLeave].allSatisfy {
        (keyTokens + ["CALV"]).contains(token($0))
      })
    #expect(capture.server[firstLeave...].allSatisfy { !keyTokens.contains(token($0)) })
    let keys = expectedKeyEvents(capture.server)
    #expect(keys.count == 232)
    #expect(
      Array(keys.prefix(2)) == [
        .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
        .key(key: .letter(0), phase: .up, modifiers: ModifierState()),
      ])
    #expect(
      keys.filter { if case .key(_, .repeatKey, _) = $0 { true } else { false } }
        == Array(
          repeating: .key(key: .letter(0), phase: .repeatKey, modifiers: ModifierState()),
          count: 14))

    var expected: [KVMEvent] = [entered(0, 450)]
    let positions: [(Double, Double)] = [
      (10, 450), (10, 460), (0, 460), (0, 450), (100, 500), (101, 501),
    ]
    expected += positions.map { moved($0.0, $0.1) }
    // Wire 1 left, 3 right, 2 middle, 4 auxiliary; 5 is dropped both ways.
    let buttons: [MouseButton] = [.left, .right, .middle, .auxiliary]
    for button in buttons {
      expected += [
        .mouseButton(button: button, phase: .down), .mouseButton(button: button, phase: .up),
      ]
    }
    expected += [
      .mouseButton(button: .left, phase: .down), moved(116, 506),
      .mouseButton(button: .left, phase: .up),
    ]
    // Up, down, left, right notches (first-party sign convention, M1-PROTOCOL-003).
    expected += [
      .scroll(deltaX: 0, deltaY: 1), .scroll(deltaX: 0, deltaY: -1), .scroll(deltaX: 1, deltaY: 0),
      .scroll(deltaX: -1, deltaY: 0),
    ]
    expected += keys
    expected += [
      .leaveScreen(screen: localScreen), entered(0, 450), .leaveScreen(screen: localScreen),
    ]
    #expect(events.count == 257)
    #expect(events == expected)

    // The empty clipboard 0 at the first enter has no text; clipboard 1 is not shared.
    #expect(diagnostics.dropsByReason == [.buttonUnrepresentable: 2, .clipboardWithoutText: 1])
    #expect(diagnostics.heldKeyCount == 0)
    #expect(diagnostics.unpairedRepeatsDropped == 0)
  }

  @Test func fiveRepeatedReplaysGiveIdenticalBytesAndEvents() async throws {
    let first = try await replayServerInputCapture()
    for _ in 2...5 {
      let run = try await replayServerInputCapture()
      #expect(run.sent == first.sent)
      #expect(run.events == first.events)
      #expect(run.diagnostics == first.diagnostics)
    }
  }

  // MARK: Fail closed

  @Test func everyFailClosedCaseEndsTheSessionWithATypedProtocolViolation() async throws {
    let malformed = CoreErrorCode.protocolViolation(.malformed)
    let unsupported = CoreErrorCode.protocolViolation(.unsupportedMessage)
    let invariant = CoreErrorCode.protocolViolation(.invariantViolation)
    let cases: [(name: String, entered: Bool, bytes: [UInt8], code: CoreErrorCode)] = [
      ("5-byte DMMV", true, frame("DMMV", [0, 1, 0, 1, 0]), malformed),
      ("3-byte DMMV", true, frame("DMMV", [0, 1, 0]), malformed),
      ("2-byte DMDN", true, frame("DMDN", [1, 1]), malformed),
      ("empty DMUP", true, frame("DMUP"), malformed),
      ("3-byte DMWM", true, frame("DMWM", [0, 0, 120]), malformed),
      ("5-byte DKDN", true, frame("DKDN", [0, 0x61, 0, 0, 0]), malformed),
      ("7-byte DKUP", true, frame("DKUP", [0, 0x61, 0, 0, 0, 38, 0]), malformed),
      ("6-byte DKRP", true, frame("DKRP", be16(0x61) + be16(0) + be16(38)), malformed),
      ("CALV with a body", false, frame("CALV", [0]), malformed),
      ("COUT with a body", true, frame("COUT", [0]), malformed),
      ("9-byte CINN", false, frame("CINN", [UInt8](repeating: 0, count: 9)), malformed),
      (
        "DCLP shorter than its header", true, frame("DCLP", [0, 0, 0, 0, 0, 1, 0, 0, 0]), malformed
      ),
      ("CINN outside the screen", false, cinn(x: 1600, y: 0, sequence: 1), malformed),
      ("CINN above 0x7FFF", false, cinn(x: 0x8000, y: 0, sequence: 1), malformed),
      ("server-to-client CCLP", true, cclp(id: 0, sequence: 1), unsupported),
      ("unknown token", false, frame("ZZZZ"), unsupported),
      ("payload shorter than a token", false, [0, 0, 0, 2, 0x43, 0x41], unsupported),
      ("empty payload", false, [0, 0, 0, 0], unsupported),
      ("client-only CNOP", false, cnop, unsupported),
      ("client-only DINF", false, captureDinf, unsupported),
      ("DSOP with a non-zero value", false, frame("DSOP", [0, 0, 0, 1]), unsupported),
      ("CIAK after the first enter", true, ciak, invariant),
      ("CINN while entered", true, cinn(x: 1, y: 1, sequence: 2), invariant),
      ("COUT while not entered", false, cout, invariant),
      ("QINF while entered", true, qinf, invariant),
      (
        "frame over 64 KiB", false, be32(64 * 1024 + 1) + Array("DCLP".utf8),
        .protocolViolation(.oversized)
      ),
      (
        "control frame over 4 KiB", false, frame("QINF", [UInt8](repeating: 0, count: 4093)),
        .protocolViolation(.oversized)
      ),
    ]
    for testCase in cases {
      let pipe = PipeTransport()
      let session = try await connected(pipe)
      var expected: [KVMEvent] = []
      if testCase.entered {
        pipe.feed(cinn(x: 0, y: 0, sequence: 1))
        expected.append(entered(0, 0))
      }
      let quiet = pipe.sent
      // A valid frame after the failing one must not reach the event stream.
      let closed = await closesBeforeAnswering(
        testCase.bytes + dmmv(x: 1, y: 1), session: session, pipe: pipe)
      #expect(closed, "\(testCase.name): the session went on after the failure")
      guard closed else {
        await session.disconnect(reason: .userRequested)
        continue
      }
      let (events, error) = await drain(session)
      #expect(events == expected, "\(testCase.name)")
      #expect(error?.code == testCase.code, "\(testCase.name)")
      #expect(error?.retryDisposition == .backoff, "\(testCase.name)")
      #expect(pipe.disconnectCount == 1, "\(testCase.name)")
      #expect(pipe.sent == quiet, "\(testCase.name): nothing is written after the failure")
    }
  }

  @Test func aFailedWriteEndsTheSessionWithTheTransportError() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let reset = coreError(.transport(.reset))
    pipe.failNextSend(with: reset)
    pipe.feed(calv)
    let (events, error) = await drain(session)
    #expect(events.isEmpty)
    #expect(error == reset)
    #expect(pipe.disconnectCount == 1)
  }

  // MARK: Drop and continue

  @Test func dropAndContinueCasesAreCountedAndTheSessionGoesOn() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    var events = session.events.makeAsyncIterator()
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    #expect(try await events.next() == entered(0, 0))
    let largeText = String(repeating: "x", count: (1 << 20) + 1)
    let drops: [(name: String, bytes: [UInt8], reason: DropReason)] = [
      ("DMMV x above 0x7FFF", dmmv(x: 0x8000, y: 0), .pointerOutOfRange),
      ("DMMV y 0xFFFF", dmmv(x: 0, y: 0xFFFF), .pointerOutOfRange),
      ("DMMV right of the screen", dmmv(x: 1600, y: 0), .pointerOutsideScreen),
      ("DMMV below the screen", dmmv(x: 0, y: 900), .pointerOutsideScreen),
      ("DMDN 0", dmdn(0), .buttonOutOfContract),
      ("DMUP 6", dmup(6), .buttonOutOfContract),
      ("DMDN 255", dmdn(255), .buttonOutOfContract),
      ("DMDN 5", dmdn(5), .buttonUnrepresentable),
      ("DMUP 5", dmup(5), .buttonUnrepresentable),
      ("DMWM (0, 0)", dmwm(x: 0, y: 0), .wheelWithoutNotch),
      ("DMWM below a notch", dmwm(x: 119, y: -119), .wheelWithoutNotch),
      ("DCLP chunk without a start", dclp(mark: 2, data: [1, 2, 3]), .clipboardMalformed),
      (
        "DCLP inner length beyond its body",
        frame("DCLP", joined([0], be32(0), [1], be32(5), [0x31])), .clipboardMalformed
      ),
      (
        "DCLP end before the announced size",
        dclp(mark: 1, data: Array("5".utf8)) + dclp(mark: 2, data: [1, 2, 3])
          + dclp(mark: 3, data: []), .clipboardMalformed
      ),
      ("DCLP mark 4", dclp(mark: 4, data: []), .clipboardMalformed),
      (
        "DCLP start that is not decimal", dclp(mark: 1, data: Array("4x".utf8)), .clipboardMalformed
      ),
      (
        "DCLP chunk of another transfer sequence",
        dclp(mark: 1, data: Array("1".utf8)) + dclp(sequence: 1, mark: 2, data: [7]),
        .clipboardMalformed
      ),
      (
        "marshalled clipboard with a truncated format",
        BarrierClipboard.frames(id: 0, sequence: 0, data: joined(be32(1), be32(0), be32(9), [1]))
          .flatMap { $0 }, .clipboardMalformed
      ),
      ("DCLP start over 4 MiB", dclp(mark: 1, data: Array("4194305".utf8)), .clipboardOversized),
      ("text over 1 MiB", transfer(largeText), .clipboardOversized),
      (
        "transfer without text",
        BarrierClipboard.frames(id: 0, sequence: 0, data: be32(0)).flatMap { $0 },
        .clipboardWithoutText
      ),
      ("unpaired DKRP", dkrp(0x61, button: 38), .unpairedRepeat),
    ]
    let marker = dmmv(x: 7, y: 9)
    var counts: [DropReason: Int] = [:]
    for drop in drops {
      pipe.feed(drop.bytes + marker)
      #expect(
        try await events.next() == moved(7, 9), "\(drop.name): nothing came before the marker")
      counts[drop.reason, default: 0] += 1
      #expect(session.diagnostics.dropsByReason == counts, "\(drop.name)")
    }
    // Clipboard 1 and other ids are not shared: ignored, not counted.
    pipe.feed(transfer("selection", id: 1) + transfer("other", id: 7) + marker)
    #expect(try await events.next() == moved(7, 9))
    #expect(session.diagnostics.dropsByReason == counts)
    // A complete transfer after all of that still arrives.
    pipe.feed(transfer("after"))
    guard case .clipboard(let payload)? = try await events.next() else {
      Issue.record("no clipboard event after the drops")
      return
    }
    #expect(payload.utf8Text == "after")
    #expect(pipe.disconnectCount == 0)
  }

  // MARK: Keys and the fail-safe rule

  @Test func anUnpairedRepeatIsNeverYieldedAndAnUnpairedReleaseIsPassedOn() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    var events = session.events.makeAsyncIterator()
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    #expect(try await events.next() == entered(0, 0))
    let shift = ModifierState(shift: true)
    pipe.feed(dkrp(0x61, button: 38) + dkup(0x62, button: 56) + dkdn(0x61, button: 38))
    // The unpaired repeat is dropped; the unpaired release of `b` is passed on.
    #expect(
      try await events.next() == .key(key: .letter(1), phase: .up, modifiers: ModifierState()))
    #expect(
      try await events.next() == .key(key: .letter(0), phase: .down, modifiers: ModifierState()))
    #expect(session.diagnostics.heldKeyCount == 1)
    #expect(session.diagnostics.unpairedRepeatsDropped == 1)
    // A paired repeat repeats the held key with the press's identity.
    pipe.feed(
      dkrp(0x41, mask: 0x0001, button: 38) + dkup(0x61, button: 38) + dkrp(0x61, button: 38))
    #expect(try await events.next() == .key(key: .letter(0), phase: .repeatKey, modifiers: shift))
    #expect(
      try await events.next() == .key(key: .letter(0), phase: .up, modifiers: ModifierState()))
    pipe.feed(dmmv(x: 7, y: 9))
    #expect(try await events.next() == moved(7, 9))
    #expect(session.diagnostics.heldKeyCount == 0)
    #expect(session.diagnostics.unpairedRepeatsDropped == 2)
  }

  @Test func randomKeyStreamsNeverYieldARepeatOfAKeyThatIsNotHeld() async throws {
    for seed: UInt64 in [0x029, 0x041, 0x7D7] {
      var random = SplitMix64(state: seed)
      var frames: [UInt8] = []
      var heldButtons: Set<UInt16> = []
      var pairedRepeats = 0
      var unpairedRepeats = 0
      for _ in 0..<300 {
        let button = UInt16(10 + random.next(below: 3))
        let identifier = 0x61 + button - 10
        switch random.next(below: 3) {
        case 0:
          frames += dkdn(identifier, button: button)
          heldButtons.insert(button)
        case 1:
          frames += dkup(identifier, button: button)
          heldButtons.remove(button)
        default:
          frames += dkrp(identifier, button: button)
          if heldButtons.contains(button) { pairedRepeats += 1 } else { unpairedRepeats += 1 }
        }
      }
      let pipe = PipeTransport()
      let session = try await connected(pipe)
      pipe.feed(cinn(x: 0, y: 0, sequence: 1) + frames + dmmv(x: 7, y: 9))
      var events = session.events.makeAsyncIterator()
      #expect(try await events.next() == entered(0, 0))
      var yieldedHeld: [VirtualKey] = []
      var repeats = 0
      while let event = try await events.next(), event != moved(7, 9) {
        guard case .key(let key, let phase, _) = event else {
          Issue.record("unexpected event")
          continue
        }
        switch phase {
        case .down: if !yieldedHeld.contains(key) { yieldedHeld.append(key) }
        case .up: yieldedHeld.removeAll { $0 == key }
        case .repeatKey:
          repeats += 1
          #expect(yieldedHeld.contains(key), "a repeat was yielded for a key that is not held")
        }
      }
      #expect(repeats == pairedRepeats)
      #expect(session.diagnostics.unpairedRepeatsDropped == unpairedRepeats)
      #expect(session.diagnostics.heldKeyCount == heldButtons.count)
    }
  }

  @Test func theServerClosingEndsTheStreamCleanlyAndNoReleaseIsSynthesized() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(cinn(x: 0, y: 0, sequence: 1) + dkdn(0x61, button: 38) + dmdn(1))
    pipe.closeFromPeer()
    let (events, error) = await drain(session)
    #expect(error == nil)
    #expect(
      events == [
        entered(0, 0), .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
        .mouseButton(button: .left, phase: .down),
      ])
    // The Core ledger releases what is held on this terminal path; the session reports it.
    #expect(session.diagnostics.heldKeyCount == 1)
    #expect(pipe.disconnectCount == 1)
  }

  // MARK: Keepalive

  @Test func everyServerKeepaliveIsAnsweredAtOnce() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let afterSetup = pipe.sent.count
    for round in 1...3 {
      pipe.feed(calv)
      await session.waitForReceivedFrames(atLeast: 3 + round)
      #expect(
        Array(pipe.sent[afterSetup...]) == Array(repeating: calv, count: round).flatMap { $0 })
    }
    // Between the frames of a clipboard transfer, too (BARRIER-EVID-0006 interleaving).
    let frames = BarrierClipboard.frames(
      id: 0, sequence: 0, data: BarrierClipboard.marshal(text: "z"))
    pipe.feed(joined(frames[0], calv, frames[1], calv, frames[2]))
    await session.waitForReceivedFrames(atLeast: 3 + 3 + 5)
    #expect(Array(pipe.sent[afterSetup...]) == Array(repeating: calv, count: 5).flatMap { $0 })
    #expect(pipe.disconnectCount == 0)
  }

  @Test func nineSilentSecondsEndTheSessionAsAKeepaliveTimeout() async throws {
    let pipe = PipeTransport()
    let clock = ManualClock()
    let session = try await connected(pipe, clock: clock)
    // Eight silent checks keep the session up.
    for _ in 1...8 {
      await clock.waitForSleeper(duration: keepaliveTick)
      clock.fire(duration: keepaliveTick)
    }
    await clock.waitForSleeper(duration: keepaliveTick)
    #expect(pipe.disconnectCount == 0)
    // Any server frame starts the count again.
    pipe.feed(calv)
    await session.waitForReceivedFrames(atLeast: 4)
    for _ in 1...9 {
      await clock.waitForSleeper(duration: keepaliveTick)
      clock.fire(duration: keepaliveTick)
    }
    await clock.waitForSleeper(duration: keepaliveTick)
    #expect(pipe.disconnectCount == 0)
    // The ninth silent check in a row ends the session.
    clock.fire(duration: keepaliveTick)
    let closedFirst = await completesFirst {
      await session.waitForReceivedFrames(atLeast: .max)
    } before: {
      await clock.waitForSleeper(duration: keepaliveTick)
    }
    try #require(closedFirst, "the session kept waiting after nine silent seconds")
    let (events, error) = await drain(session)
    #expect(events.isEmpty)
    #expect(error?.code == .timeout(.keepalive))
    #expect(error?.retryDisposition == .backoff)
    #expect(pipe.disconnectCount == 1)
    #expect(Array(pipe.sent.suffix(calv.count)) == calv)
  }

  // MARK: Clipboard

  @Test func serverClipboardTransfersBecomeClipboardEvents() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    var events = session.events.makeAsyncIterator()
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    #expect(try await events.next() == entered(0, 0))
    let small = "server \u{65E5}\u{672C}"
    pipe.feed(transfer(small))
    guard case .clipboard(let first)? = try await events.next() else {
      Issue.record("no clipboard event")
      return
    }
    #expect(first.utf8Text == small)
    #expect(first.contentHash.isEmpty)
    guard case .remote(let device) = first.origin else {
      Issue.record("an inbound clipboard must be remote")
      return
    }
    // 600,001 bytes of text and a 900,000-byte second format in 32 KiB chunks, with a CALV
    // between two chunks.
    let text = String(repeating: "mackvm-chunk-probe-", count: 31_579)
    let frames = BarrierClipboard.frames(
      id: 0, sequence: 0, data: marshalled(text: text, html: 900_000))
    #expect(frames.count > 40)
    var stream: [UInt8] = []
    for (index, chunk) in frames.enumerated() {
      stream += chunk
      if index == 2 { stream += calv }
    }
    let before = pipe.sent.count
    pipe.feed(stream)
    guard case .clipboard(let large)? = try await events.next() else {
      Issue.record("no clipboard event for the large transfer")
      return
    }
    #expect(large.utf8Text.utf8.count == 600_001)
    #expect(large.utf8Text == text)
    #expect(large.origin == .remote(device))
    #expect(large.transactionID != first.transactionID)
    #expect(Array(pipe.sent[before...]) == calv)
    #expect(pipe.disconnectCount == 0)
  }

  @Test func localClipboardIsSentAsCclpThenDclpWithTheSequenceOfTheEnterInForce() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let text = "probe \u{2713}"
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: text, contentHash: "h")
    // Before the first enter no sequence is in force: refused, nothing written.
    let quiet = pipe.sent
    await expectFailure(.lifecycle(.subsystemUnavailable)) {
      try await session.send(.clipboard(payload))
    }
    #expect(pipe.sent == quiet)
    // The increment rule is not frozen: whatever CINN carries is used.
    pipe.feed(cinn(x: 0, y: 0, sequence: 7))
    await session.waitForReceivedFrames(atLeast: 4)
    try await session.send(.clipboard(payload))
    #expect(
      Array(pipe.sent[quiet.count...]) == cclp(id: 0, sequence: 7) + transfer(text, sequence: 7))
    // A later enter's sequence replaces it, and stays in force after the leave.
    pipe.feed(cout + cinn(x: 0, y: 0, sequence: 9) + cout)
    await session.waitForReceivedFrames(atLeast: 7)
    var mark = pipe.sent.count
    try await session.send(.clipboard(payload))
    #expect(Array(pipe.sent[mark...]) == cclp(id: 0, sequence: 9) + transfer(text, sequence: 9))
    // Text over 1 MiB is refused before any byte; exactly 1 MiB is sent.
    mark = pipe.sent.count
    let over = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local,
      utf8Text: String(repeating: "x", count: (1 << 20) + 1), contentHash: "h")
    await expectFailure(.clipboard(.oversized)) { try await session.send(.clipboard(over)) }
    #expect(pipe.sent.count == mark)
    let limit = String(repeating: "x", count: 1 << 20)
    try await session.send(
      .clipboard(
        ClipboardPayload(
          transactionID: ClipboardTransactionID(), origin: .local, utf8Text: limit,
          contentHash: "h")))
    #expect(Array(pipe.sent[mark...]) == cclp(id: 0, sequence: 9) + transfer(limit, sequence: 9))
    #expect(pipe.disconnectCount == 0)
  }

  @Test func sendingInputFailsClosedAndWritesNothing() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    await session.waitForReceivedFrames(atLeast: 4)
    let quiet = pipe.sent
    let inputs: [KVMEvent] = [
      .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)),
      .mouseButton(button: .left, phase: .down), .scroll(deltaX: 0, deltaY: 1),
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .enterScreen(screen: localScreen, position: NormalizedPoint(x: 0, y: 0)),
      .leaveScreen(screen: localScreen),
    ]
    for event in inputs {
      await expectFailure(.protocolViolation(.unsupportedMessage)) { try await session.send(event) }
    }
    #expect(pipe.sent == quiet)
    #expect(pipe.disconnectCount == 0)
    try await session.send(
      .clipboard(
        ClipboardPayload(
          transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "still up",
          contentHash: "h")))
    #expect(pipe.sent.count > quiet.count)
  }

  // MARK: Screen updates

  @Test func aScreenChangeWhileEnteredIsReportedAfterTheLeave() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    var events = session.events.makeAsyncIterator()
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    #expect(try await events.next() == entered(0, 0))
    let quiet = pipe.sent
    let smaller = try screen(0, 0, 800, 600, 400, 300)
    try await session.updateScreen(smaller)
    #expect(pipe.sent == quiet, "no DINF while the screen is entered")
    // Pointer frames still use the reported rectangle until the leave.
    pipe.feed(dmmv(x: 1599, y: 899))
    #expect(try await events.next() == moved(1599, 899))
    pipe.feed(cout)
    #expect(try await events.next() == .leaveScreen(screen: localScreen))
    await session.waitForReceivedFrames(atLeast: 6)
    #expect(Array(pipe.sent[quiet.count...]) == dinf(smaller))
    // After the next enter, frames are checked against the new rectangle.
    pipe.feed(
      joined(
        cinn(x: 799, y: 599, sequence: 3), dmmv(x: 799, y: 599), dmmv(x: 800, y: 0),
        dmmv(x: 0, y: 0)))
    #expect(
      try await events.next()
        == .enterScreen(screen: localScreen, position: NormalizedPoint(x: 1, y: 1)))
    #expect(try await events.next() == .mouseMove(position: NormalizedPoint(x: 1, y: 1)))
    #expect(try await events.next() == .mouseMove(position: NormalizedPoint(x: 0, y: 0)))
    #expect(session.diagnostics.dropsByReason == [.pointerOutsideScreen: 1])
  }

  @Test func aScreenChangeWhileNotEnteredIsReportedAtOnce() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    let quiet = pipe.sent
    let smaller = try screen(0, 0, 800, 600, 400, 300)
    try await session.updateScreen(smaller)
    #expect(Array(pipe.sent[quiet.count...]) == dinf(smaller))
    // An unchanged screen writes nothing.
    try await session.updateScreen(smaller)
    #expect(Array(pipe.sent[quiet.count...]) == dinf(smaller))
    // Back to the capture screen, then a change and its reversal while entered: nothing pending.
    let original = try captureScreen()
    try await session.updateScreen(original)
    var events = session.events.makeAsyncIterator()
    pipe.feed(cinn(x: 1599, y: 899, sequence: 1))
    #expect(try await events.next() == entered(1599, 899))
    try await session.updateScreen(smaller)
    try await session.updateScreen(original)
    pipe.feed(cout + calv)
    #expect(try await events.next() == .leaveScreen(screen: localScreen))
    await session.waitForReceivedFrames(atLeast: 6)
    #expect(Array(pipe.sent[quiet.count...]) == dinf(smaller) + dinf(original) + calv)
  }

  @Test func anEnterIsValidatedAgainstTheNewlyReportedScreen() async throws {
    // The session feeds its own DINF to the control decoder (M1-031), so an enter that fits
    // the old 1600 x 900 rectangle but not the new 800 x 600 one fails closed.
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    try await session.updateScreen(try screen(0, 0, 800, 600, 400, 300))
    let closed = await closesBeforeAnswering(
      cinn(x: 1000, y: 0, sequence: 1), session: session, pipe: pipe)
    try #require(closed, "an enter outside the newly reported screen was accepted")
    let (events, error) = await drain(session)
    #expect(events.isEmpty)
    #expect(error?.code == .protocolViolation(.malformed))
    #expect(pipe.disconnectCount == 1)
  }

  // MARK: Ordering, lifecycle and diagnostics

  @Test func framesLeaveInTheOrderTheyWereComposed() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(cinn(x: 0, y: 0, sequence: 1))
    await session.waitForReceivedFrames(atLeast: 4)
    let mark = pipe.sent.count
    // The clipboard transfer is held inside the transport.
    pipe.holdNextSend()
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "first",
      contentHash: "h")
    let sending = Task { try await session.send(.clipboard(payload)) }
    await pipe.waitForSendCalls(3)
    // A keepalive answer, then a screen report, are composed while it is in flight.
    pipe.feed(cout + calv)
    let calvQueued = await completesFirst {
      await session.waitForPendingWrites(atLeast: 1)
    } before: {
      await pipe.waitForSendCalls(4)
    }
    #expect(calvQueued, "the CALV answer did not wait for the earlier transfer")
    let smaller = try screen(0, 0, 800, 600, 400, 300)
    let updating = Task { try await session.updateScreen(smaller) }
    let dinfQueued = await completesFirst {
      await session.waitForPendingWrites(atLeast: 2)
    } before: {
      await pipe.waitForSendCalls(5)
    }
    #expect(dinfQueued, "the DINF did not wait for the earlier frames")
    pipe.releaseHeldSend()
    try await value(of: sending)
    try await value(of: updating)
    await session.waitForReceivedFrames(atLeast: 6)
    let expected = joined(
      cclp(id: 0, sequence: 1), transfer("first", sequence: 1), calv, dinf(smaller))
    #expect(Array(pipe.sent[mark...]) == expected)
  }

  @Test func disconnectIsIdempotentAndEndsEverything() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    await session.disconnect(reason: .userRequested)
    await session.disconnect(reason: .userRequested)
    #expect(pipe.disconnectCount == 1)
    let (events, error) = await drain(session)
    #expect(events.isEmpty)
    #expect(error == nil)
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "late", contentHash: "h")
    await expectFailure(.lifecycle(.subsystemUnavailable)) {
      try await session.send(.clipboard(payload))
    }
    await expectFailure(.lifecycle(.subsystemUnavailable)) {
      try await session.updateScreen(try screen(0, 0, 800, 600, 400, 300))
    }
    await expectFailure(.internalFailure(.preconditionFailed)) { try await session.connect() }
    await session.waitForReceivedFrames(atLeast: .max)
    await session.waitForPendingWrites(atLeast: .max)
    #expect(pipe.disconnectCount == 1)
  }

  @Test func disconnectReasonsFinishTheStreamAsTheContractSays() async throws {
    let failure = coreError(.transport(.reset))
    let reasons: [(DisconnectReason, CoreErrorCode?)] = [
      (.userRequested, nil), (.transportClosed, nil), (.applicationTermination, nil),
      (.failure(failure), .transport(.reset)),
      (.cancellation(.superseded), .cancellation(.superseded)),
    ]
    for (reason, code) in reasons {
      let pipe = PipeTransport()
      let session = try await connected(pipe)
      await session.disconnect(reason: reason)
      let (_, error) = await drain(session)
      #expect(error?.code == code, "\(reason)")
      #expect(pipe.disconnectCount == 1)
    }
  }

  @Test func diagnosticsHoldOnlyCounts() async throws {
    let pipe = PipeTransport()
    let session = try await connected(pipe)
    pipe.feed(
      joined(
        cinn(x: 0, y: 0, sequence: 1), dmdn(5), dmmv(x: 0x8000, y: 0), dkdn(0x61, button: 38),
        dkrp(0x62, button: 56), transfer(""), dclp(mark: 4, data: [])))
    await session.waitForReceivedFrames(atLeast: 3 + 7 + 2)
    let diagnostics = session.diagnostics
    #expect(diagnostics.heldKeyCount == 1)
    #expect(diagnostics.dropsByReason.values.reduce(0, +) == 4)
    #expect(!containsSensitiveShape(diagnostics))
    #expect(DropReason.allCases.count == 9)
  }
}

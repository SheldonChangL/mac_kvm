import Testing
@testable import BarrierCompatibility

private typealias HandshakeError = BarrierClientHandshakeError
private typealias HandshakeState = BarrierClientHandshake.State

// Golden server hello: the first server-to-client frame of BARRIER-EVID-0002, the same bytes
// used by BarrierServerHelloTests (M1-027). Source:
// evidence/issues/M1-WIRE-001/barrier-frame-conformance.json /derived/runs/0.
// Golden HelloBack: the client-to-server run of BARRIER-EVID-0004 attempt 0 (`m1-client`),
// the same bytes used by BarrierClientHelloBackTests (M1-028). Source:
// Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json and
// docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md. Copied by hand; if that evidence
// is superseded, update these bytes from the superseding artifact.
private let goldenServerHelloPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let goldenServerHelloFrame: [UInt8] = [0x00, 0x00, 0x00, 0x0B] + goldenServerHelloPayload
private let goldenHelloBackFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x18, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00,
  0x06, 0x00, 0x00, 0x00, 0x09, 0x6D, 0x31, 0x2D, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
]

private func makeHandshake(
  screenName: String = "m1-client", limit: Int = 64
) throws -> BarrierClientHandshake {
  BarrierClientHandshake(
    screenName: screenName,
    helloBackWriter: try BarrierClientHelloBackWriter(maximumScreenNameByteCount: limit))
}

/// A handshake that has already accepted the hello and returned the HelloBack frame.
private func makeHandshakeSendingHelloBack() throws -> BarrierClientHandshake {
  var handshake = try makeHandshake()
  try handshake.start()
  _ = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  return handshake
}

private func helloFailure(
  _ handshake: inout BarrierClientHandshake, payload: [UInt8]
) -> HandshakeError? {
  do throws(HandshakeError) {
    _ = try handshake.receiveServerHello(payload: payload)
    return nil
  } catch {
    return error
  }
}

// MARK: - Happy path

@Test func handshakeProgressesThroughEveryStateToProtocolConnected() throws {
  var handshake = try makeHandshake()
  #expect(handshake.state == .connected)
  try handshake.start()
  #expect(handshake.state == .awaitHello)
  let frame = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  #expect(handshake.state == .sendHelloBack)
  #expect(frame == goldenHelloBackFrame)
  try handshake.helloBackSent()
  #expect(handshake.state == .protocolConnected)
}

@Test func handshakeEmitsGoldenHelloBackFrameForM1xExactly() throws {
  var handshake = try makeHandshake(screenName: "m1x")
  try handshake.start()
  let frame = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  let expected: [UInt8] = [
    0x00, 0x00, 0x00, 0x12, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00,
    0x06, 0x00, 0x00, 0x00, 0x03, 0x6D, 0x31, 0x78,
  ]
  #expect(frame == expected)
}

@Test func handshakeEmitsSameBytesAsTheHelloBackWriter() throws {
  // Conformance: the handshake adds no framing or bytes of its own around M1-028 output.
  let writer = try BarrierClientHelloBackWriter(maximumScreenNameByteCount: 64)
  var handshake = BarrierClientHandshake(screenName: "m1-client", helloBackWriter: writer)
  try handshake.start()
  let frame = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  #expect(frame == (try writer.frame(screenName: "m1-client")))
}

@Test func handshakeAcceptsHelloReassembledFromByteByByteFragments() throws {
  // Stream fragmentation belongs to M1-022; this pins the hand-off of a fragmented frame.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var handshake = try makeHandshake()
  try handshake.start()
  var frame: [UInt8]?
  for byte in goldenServerHelloFrame {
    try reassembler.append([byte])
    if let payload = try reassembler.nextPayload() {
      #expect(frame == nil)
      frame = try handshake.receiveServerHello(payload: payload)
    }
  }
  #expect(frame == goldenHelloBackFrame)
  #expect(handshake.state == .sendHelloBack)
}

@Test func handshakeConsumesOnlyTheHelloFromCoalescedFrames() throws {
  // A frame coalesced after the hello stays queued in the reassembler for the next owner;
  // the handshake consumes exactly one payload.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(goldenServerHelloFrame + [0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB])
  var handshake = try makeHandshake()
  try handshake.start()
  let payload = try #require(try reassembler.nextPayload())
  #expect(try handshake.receiveServerHello(payload: payload) == goldenHelloBackFrame)
  try handshake.helloBackSent()
  #expect(handshake.state == .protocolConnected)
  #expect(try reassembler.nextPayload() == [0xAA, 0xBB])
}

@Test func truncatedHelloFrameNeverReachesTheHandshakeAndTimeoutTerminates() throws {
  // A frame truncated in the stream yields no payload; the handshake keeps waiting until the
  // caller injects its timeout signal. No sleep or real clock is involved.
  for length in 1..<goldenServerHelloFrame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    try reassembler.append(Array(goldenServerHelloFrame[..<length]))
    #expect(try reassembler.nextPayload() == nil)
    var handshake = try makeHandshake()
    try handshake.start()
    #expect(handshake.state == .awaitHello)
    handshake.timeOut()
    #expect(handshake.state == .failed(.timedOut))
  }
}

// MARK: - Boundary

@Test func handshakeAcceptsScreenNameAtExactlyTheConfiguredLimit() throws {
  let name = String(repeating: "a", count: 16)
  var handshake = try makeHandshake(screenName: name, limit: 16)
  try handshake.start()
  let frame = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  #expect(frame.count == 4 + 7 + 4 + 4 + 16)
  #expect(Array(frame[15..<19]) == [0x00, 0x00, 0x00, 0x10])
  #expect(Array(frame[19...]) == Array(name.utf8))
  try handshake.helloBackSent()
  #expect(handshake.state == .protocolConnected)
}

@Test func handshakeFailsForScreenNameOneByteOverTheConfiguredLimit() throws {
  var handshake = try makeHandshake(screenName: String(repeating: "a", count: 17), limit: 16)
  try handshake.start()
  let expected = HandshakeError.helloBackRejected(.screenNameTooLong(byteCount: 17, limit: 16))
  #expect(helloFailure(&handshake, payload: goldenServerHelloPayload) == expected)
  #expect(handshake.state == .failed(expected))
}

@Test func handshakeAcceptsSingleByteScreenNameAtMinimumLimit() throws {
  var handshake = try makeHandshake(screenName: "x", limit: 1)
  try handshake.start()
  let frame = try handshake.receiveServerHello(payload: goldenServerHelloPayload)
  #expect(Array(frame[15...]) == [0x00, 0x00, 0x00, 0x01, 0x78])
}

// MARK: - Invalid input / failure

@Test func handshakeFailsClosedOnUnsupportedMarker() throws {
  var payload = goldenServerHelloPayload
  payload[0] = 0x62
  var handshake = try makeHandshake()
  try handshake.start()
  #expect(helloFailure(&handshake, payload: payload) == .serverHelloRejected(.unsupportedMarker))
  #expect(handshake.state == .failed(.serverHelloRejected(.unsupportedMarker)))
}

@Test func handshakeFailsClosedOnUnsupportedVersion() throws {
  for index in 7..<11 {
    var payload = goldenServerHelloPayload
    payload[index] ^= 0x01
    var handshake = try makeHandshake()
    try handshake.start()
    #expect(
      helloFailure(&handshake, payload: payload) == .serverHelloRejected(.unsupportedVersion))
    #expect(handshake.state == .failed(.serverHelloRejected(.unsupportedVersion)))
  }
}

@Test func handshakeFailsClosedOnTruncatedHelloPayload() throws {
  for length in 0..<goldenServerHelloPayload.count {
    var handshake = try makeHandshake()
    try handshake.start()
    let expected: HandshakeError =
      length < 7
      ? .serverHelloRejected(.truncatedMarker(payloadByteCount: length))
      : .serverHelloRejected(.truncatedVersion(payloadByteCount: length))
    let payload = Array(goldenServerHelloPayload[..<length])
    #expect(helloFailure(&handshake, payload: payload) == expected)
    #expect(handshake.state == .failed(expected))
  }
}

@Test func handshakeFailsClosedOnHelloWithTrailingBytes() throws {
  var handshake = try makeHandshake()
  try handshake.start()
  let expected = HandshakeError.serverHelloRejected(.unexpectedTrailingBytes(payloadByteCount: 12))
  #expect(helloFailure(&handshake, payload: goldenServerHelloPayload + [0x00]) == expected)
  #expect(handshake.state == .failed(expected))
}

@Test func handshakeFailsClosedOnInvalidScreenNames() throws {
  let cases: [(String, HandshakeError)] = [
    ("", .helloBackRejected(.emptyScreenName)),
    ("m1 client", .helloBackRejected(.unsupportedScreenNameCharacter)),
    ("user@host", .helloBackRejected(.unsupportedScreenNameCharacter)),
    ("m1-clïent", .helloBackRejected(.unsupportedScreenNameCharacter)),
  ]
  for (name, expected) in cases {
    var handshake = try makeHandshake(screenName: name)
    try handshake.start()
    #expect(helloFailure(&handshake, payload: goldenServerHelloPayload) == expected)
    #expect(handshake.state == .failed(expected))
  }
}

@Test func handshakeValidatesServerHelloBeforeScreenName() throws {
  // A rejected hello is reported even when the screen name would also be rejected, so no
  // HelloBack is ever composed for an unsupported server.
  var handshake = try makeHandshake(screenName: "")
  try handshake.start()
  #expect(
    helloFailure(&handshake, payload: [0x00]) == .serverHelloRejected(.unsupportedMarker))
}

@Test func handshakeRejectsHelloBeforeStart() throws {
  var handshake = try makeHandshake()
  #expect(helloFailure(&handshake, payload: goldenServerHelloPayload) == .outOfOrderEvent)
  #expect(handshake.state == .failed(.outOfOrderEvent))
}

@Test func handshakeRejectsOutOfOrderEvents() throws {
  var notStarted = try makeHandshake()
  #expect(throws: HandshakeError.outOfOrderEvent) { try notStarted.helloBackSent() }
  #expect(notStarted.state == .failed(.outOfOrderEvent))

  var awaiting = try makeHandshake()
  try awaiting.start()
  #expect(throws: HandshakeError.outOfOrderEvent) { try awaiting.start() }
  #expect(awaiting.state == .failed(.outOfOrderEvent))

  var awaitingSend = try makeHandshake()
  try awaitingSend.start()
  #expect(throws: HandshakeError.outOfOrderEvent) { try awaitingSend.helloBackSent() }
  #expect(awaitingSend.state == .failed(.outOfOrderEvent))

  var sending = try makeHandshakeSendingHelloBack()
  #expect(helloFailure(&sending, payload: goldenServerHelloPayload) == .outOfOrderEvent)
  #expect(sending.state == .failed(.outOfOrderEvent))
}

@Test func handshakeRejectsEventsAfterProtocolConnectedWithoutChangingState() throws {
  var handshake = try makeHandshakeSendingHelloBack()
  try handshake.helloBackSent()
  #expect(throws: HandshakeError.alreadyConnected) { try handshake.start() }
  #expect(helloFailure(&handshake, payload: goldenServerHelloPayload) == .alreadyConnected)
  #expect(throws: HandshakeError.alreadyConnected) { try handshake.helloBackSent() }
  #expect(handshake.state == .protocolConnected)
}

@Test func handshakeTimesOutFromEveryPendingState() throws {
  var connected = try makeHandshake()
  connected.timeOut()
  #expect(connected.state == .failed(.timedOut))

  var awaiting = try makeHandshake()
  try awaiting.start()
  awaiting.timeOut()
  #expect(awaiting.state == .failed(.timedOut))

  var sending = try makeHandshakeSendingHelloBack()
  sending.timeOut()
  #expect(sending.state == .failed(.timedOut))
  #expect(throws: HandshakeError.timedOut) { try sending.helloBackSent() }
}

@Test func handshakeErrorsCarryOnlyAllowlistedMetadata() throws {
  var handshake = try makeHandshake(screenName: "secret-name", limit: 4)
  try handshake.start()
  let error = try #require(helloFailure(&handshake, payload: goldenServerHelloPayload))
  #expect(error == .helloBackRejected(.screenNameTooLong(byteCount: 11, limit: 4)))
  #expect(!String(describing: error).contains("secret"))
  #expect(!String(describing: handshake).contains("secret"))
  // Walk every associated value: only Int counts and limits may appear.
  func leaves(_ value: Any) -> [Any] {
    let children = Mirror(reflecting: value).children
    return children.isEmpty ? [value] : children.flatMap { leaves($0.value) }
  }
  let errors: [HandshakeError] = [
    error, .serverHelloRejected(.truncatedMarker(payloadByteCount: 3)),
    .serverHelloRejected(.unexpectedTrailingBytes(payloadByteCount: 99)),
  ]
  for leaf in errors.flatMap({ leaves($0) }) {
    #expect(leaf is Int)
  }
  for simple: HandshakeError in [.timedOut, .cancelled, .outOfOrderEvent, .alreadyConnected] {
    #expect(Mirror(reflecting: simple).children.isEmpty)
  }
}

// MARK: - Cancel / cleanup / idempotency

@Test func handshakeCancelsFromEveryPendingState() throws {
  var connected = try makeHandshake()
  connected.cancel()
  #expect(connected.state == .failed(.cancelled))

  var awaiting = try makeHandshake()
  try awaiting.start()
  awaiting.cancel()
  #expect(awaiting.state == .failed(.cancelled))
  #expect(helloFailure(&awaiting, payload: goldenServerHelloPayload) == .cancelled)

  var sending = try makeHandshakeSendingHelloBack()
  sending.cancel()
  #expect(sending.state == .failed(.cancelled))
  #expect(throws: HandshakeError.cancelled) { try sending.helloBackSent() }
}

@Test func handshakeCancelAndTimeoutAreIdempotentAndKeepTheFirstTerminalReason() throws {
  var cancelled = try makeHandshake()
  try cancelled.start()
  cancelled.cancel()
  cancelled.cancel()
  cancelled.timeOut()
  #expect(cancelled.state == .failed(.cancelled))

  var timedOut = try makeHandshake()
  timedOut.timeOut()
  timedOut.timeOut()
  timedOut.cancel()
  #expect(timedOut.state == .failed(.timedOut))

  var rejected = try makeHandshake()
  try rejected.start()
  _ = helloFailure(&rejected, payload: [0x00])
  rejected.cancel()
  rejected.timeOut()
  #expect(rejected.state == .failed(.serverHelloRejected(.unsupportedMarker)))
}

@Test func handshakeFailureIsStickyForEveryLaterEvent() throws {
  var handshake = try makeHandshake()
  try handshake.start()
  let expected = HandshakeError.serverHelloRejected(.unsupportedVersion)
  var bad = goldenServerHelloPayload
  bad[10] = 0x07
  #expect(helloFailure(&handshake, payload: bad) == expected)
  // A later valid hello cannot revive a failed handshake.
  #expect(helloFailure(&handshake, payload: goldenServerHelloPayload) == expected)
  #expect(throws: expected) { try handshake.start() }
  #expect(throws: expected) { try handshake.helloBackSent() }
  #expect(handshake.state == .failed(expected))
}

@Test func handshakeLateCancelAndTimeoutDoNotTearDownProtocolConnected() throws {
  // After completion the handshake owns nothing; session teardown belongs to its owner.
  var handshake = try makeHandshakeSendingHelloBack()
  try handshake.helloBackSent()
  handshake.timeOut()
  handshake.cancel()
  #expect(handshake.state == .protocolConnected)
}

@Test func handshakeReleasesScreenNameOnEveryTerminalState() throws {
  func retainsScreenName(_ handshake: BarrierClientHandshake) -> Bool {
    Mirror(reflecting: handshake).children.contains { child in
      child.label == "screenName" && String(describing: child.value) != "nil"
    }
  }
  let pending = try makeHandshake()
  #expect(retainsScreenName(pending))

  var connected = try makeHandshakeSendingHelloBack()
  #expect(!retainsScreenName(connected))
  try connected.helloBackSent()
  #expect(!retainsScreenName(connected))

  var cancelled = try makeHandshake()
  cancelled.cancel()
  #expect(!retainsScreenName(cancelled))

  var timedOut = try makeHandshake()
  try timedOut.start()
  timedOut.timeOut()
  #expect(!retainsScreenName(timedOut))

  var rejected = try makeHandshake()
  try rejected.start()
  _ = helloFailure(&rejected, payload: [])
  #expect(!retainsScreenName(rejected))
}

@Test func handshakeRunsAreDeterministic() throws {
  // Separate instances with the same inputs produce identical bytes and states; a failed
  // instance does not affect a later one.
  var failed = try makeHandshake(screenName: "")
  try failed.start()
  _ = helloFailure(&failed, payload: goldenServerHelloPayload)
  var frames: [[UInt8]] = []
  for _ in 0..<2 {
    var handshake = try makeHandshake()
    try handshake.start()
    frames.append(try handshake.receiveServerHello(payload: goldenServerHelloPayload))
    try handshake.helloBackSent()
    #expect(handshake.state == .protocolConnected)
  }
  #expect(frames == [goldenHelloBackFrame, goldenHelloBackFrame])
}

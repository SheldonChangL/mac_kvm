import Testing

@testable import BarrierCompatibility

// Golden bytes, copied by hand from accepted evidence:
// - server hello and HelloBack (`m1-control`): BARRIER-EVID-0005 setup context,
//   docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md
// - QINF, CIAK, CROP, DSOP and DINF frames: BARRIER-EVID-0005, same ADR.
// The server role reuses them under the proposed docs/adr/M2-023.
private let helloFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0B, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let helloBackPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06, 0x00, 0x00, 0x00, 0x0A,
  0x6D, 0x31, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C,
]
private let qinfFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x51, 0x49, 0x4E, 0x46]
private let setupFrames: [UInt8] =
  [0x00, 0x00, 0x00, 0x04, 0x43, 0x49, 0x41, 0x4B]
  + [0x00, 0x00, 0x00, 0x04, 0x43, 0x52, 0x4F, 0x50]
  + [0x00, 0x00, 0x00, 0x08, 0x44, 0x53, 0x4F, 0x50, 0x00, 0x00, 0x00, 0x00]
private let dinfPayload: [UInt8] = [
  0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04, 0x5D, 0x00, 0x00, 0x03, 0x04,
  0x02, 0x52,
]
private let calvPayload: [UInt8] = [0x43, 0x41, 0x4C, 0x56]

private typealias HandshakeError = BarrierServerHandshakeError

private func makeHandshake(names: Set<String> = ["m1-control"]) throws -> BarrierServerHandshake {
  try BarrierServerHandshake(expectedScreenNames: names, maximumScreenNameByteCount: 64)
}

private func helloBack(name: [UInt8], declared: UInt32? = nil, version: [UInt8] = [0, 1, 0, 6])
  -> [UInt8]
{
  let count = declared ?? UInt32(name.count)
  return Array("Barrier".utf8) + version
    + [
      UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF),
      UInt8(count & 0xFF),
    ]
    + name
}

@Suite("M2-025 BarrierServerHandshake")
struct BarrierServerHandshakeTests {
  @Test("happy path: hello, QINF, setup frames, then ready with the client screen")
  func happyPath() throws {
    var handshake = try makeHandshake()
    #expect(try handshake.start() == helloFrame)
    #expect(try handshake.receive(payload: helloBackPayload) == qinfFrame)
    #expect(handshake.state == .awaitingScreenInfo)
    #expect(try handshake.receive(payload: dinfPayload) == setupFrames)
    let expected = BarrierScreenInfo(
      originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)
    #expect(handshake.state == .ready(expected))
    #expect(handshake.clientScreenName == "m1-control")
  }

  @Test("identity: an unexpected client screen name never reaches ready")
  func unknownScreen() throws {
    var handshake = try makeHandshake(names: ["other-name"])
    _ = try handshake.start()
    #expect(throws: HandshakeError.unknownClientScreen) {
      try handshake.receive(payload: helloBackPayload)
    }
    #expect(handshake.state == .failed(.unknownClientScreen))
    #expect(handshake.clientScreenName == nil)
    #expect(throws: HandshakeError.unknownClientScreen) {
      try handshake.receive(payload: dinfPayload)
    }
  }

  @Test("invalid HelloBack variants fail closed")
  func invalidHelloBack() throws {
    let name = Array("m1-control".utf8)
    let cases: [([UInt8], HandshakeError)] = [
      (Array(helloBackPayload.prefix(10)), .malformedHelloBack),
      (helloBack(name: name, version: [0, 1, 0, 5]), .unsupportedVersion),
      (Array("Barrieq".utf8) + [0, 1, 0, 6, 0, 0, 0, 1, 0x61], .unsupportedMarker),
      (helloBack(name: name, declared: 11), .malformedHelloBack),
      (helloBack(name: name, declared: 9), .malformedHelloBack),
      (helloBack(name: []), .invalidScreenName),
      (helloBack(name: Array("m1 control".utf8)), .invalidScreenName),
      (helloBack(name: [0xC3, 0xA9]), .invalidScreenName),
      (helloBack(name: Array(repeating: 0x61, count: 65)), .invalidScreenName),
    ]
    for (payload, error) in cases {
      var handshake = try makeHandshake()
      _ = try handshake.start()
      #expect(throws: error) { try handshake.receive(payload: payload) }
      #expect(handshake.state == .failed(error))
    }
  }

  @Test("invalid DINF or an out-of-order frame fails closed")
  func invalidScreenInfo() throws {
    var badSize = try makeHandshake()
    _ = try badSize.start()
    _ = try badSize.receive(payload: helloBackPayload)
    var zero = dinfPayload
    zero[8] = 0
    zero[9] = 0
    #expect(throws: HandshakeError.screenInfoRejected(.invalidScreenSize)) {
      try badSize.receive(payload: zero)
    }

    var early = try makeHandshake()
    _ = try early.start()
    #expect(throws: HandshakeError.unsupportedMarker) { try early.receive(payload: dinfPayload) }

    var keepalive = try makeHandshake()
    _ = try keepalive.start()
    _ = try keepalive.receive(payload: helloBackPayload)
    #expect(throws: HandshakeError.unexpectedFrame) { try keepalive.receive(payload: calvPayload) }

    var oversized = try makeHandshake()
    _ = try oversized.start()
    _ = try oversized.receive(payload: helloBackPayload)
    #expect(
      throws: HandshakeError.screenInfoRejected(.invalidBodyLength(token: .dinf, bodyByteCount: 15))
    ) {
      try oversized.receive(payload: dinfPayload + [0])
    }
  }

  @Test("order: receive before start and start twice fail closed")
  func ordering() throws {
    var notStarted = try makeHandshake()
    #expect(throws: HandshakeError.outOfOrderEvent) {
      try notStarted.receive(payload: helloBackPayload)
    }
    var twice = try makeHandshake()
    _ = try twice.start()
    #expect(throws: HandshakeError.outOfOrderEvent) { try twice.start() }

    var done = try makeHandshake()
    _ = try done.start()
    _ = try done.receive(payload: helloBackPayload)
    _ = try done.receive(payload: dinfPayload)
    #expect(throws: HandshakeError.alreadyReady) { try done.receive(payload: calvPayload) }
    #expect(throws: HandshakeError.alreadyReady) { try done.start() }
  }

  @Test("timeout and cancellation are terminal before ready and ignored after")
  func timeoutAndCancel() throws {
    var timed = try makeHandshake()
    _ = try timed.start()
    timed.timeOut()
    timed.cancel()
    #expect(timed.state == .failed(.timedOut))
    #expect(throws: HandshakeError.timedOut) { try timed.receive(payload: helloBackPayload) }

    var cancelled = try makeHandshake()
    cancelled.cancel()
    #expect(cancelled.state == .failed(.cancelled))

    var done = try makeHandshake()
    _ = try done.start()
    _ = try done.receive(payload: helloBackPayload)
    _ = try done.receive(payload: dinfPayload)
    done.timeOut()
    done.cancel()
    guard case .ready = done.state else {
      Issue.record("ready state was not kept")
      return
    }
  }

  @Test("configuration bounds are validated")
  func configuration() {
    #expect(throws: HandshakeError.invalidConfiguration) {
      try BarrierServerHandshake(expectedScreenNames: [], maximumScreenNameByteCount: 64)
    }
    #expect(throws: HandshakeError.invalidConfiguration) {
      try BarrierServerHandshake(expectedScreenNames: ["a"], maximumScreenNameByteCount: 0)
    }
    #expect(throws: HandshakeError.invalidConfiguration) {
      try BarrierServerHandshake(expectedScreenNames: ["a b"], maximumScreenNameByteCount: 64)
    }
    #expect(throws: HandshakeError.invalidConfiguration) {
      try BarrierServerHandshake(expectedScreenNames: ["a"], maximumScreenNameByteCount: 4096)
    }
  }

  @Test("errors and state descriptions carry no screen-name bytes")
  func privacy() throws {
    var handshake = try makeHandshake(names: ["other-name"])
    _ = try handshake.start()
    do {
      _ = try handshake.receive(payload: helloBackPayload)
    } catch {
      #expect(!String(describing: error).contains("m1-control"))
    }
    #expect(!String(describing: handshake).contains("m1-control"))
    #expect(!String(describing: handshake).contains("other-name"))
  }
}

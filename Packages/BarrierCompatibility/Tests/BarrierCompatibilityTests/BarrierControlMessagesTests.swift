import Foundation
import Testing

@testable import BarrierCompatibility

// M1-031: Barrier screen-info, setup, enter, leave and keepalive control decoder.
// Contract: docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md (BARRIER-EVID-0005).
// Golden frames are copied by hand from that ADR and are also checked byte-for-byte against
// Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json. If that
// evidence is superseded, update these bytes from the superseding artifact.

private typealias ControlError = BarrierControlMessageError
private typealias State = BarrierControlDecoder.State

private let limit = 64

// MARK: - Golden frames (BARRIER-EVID-0005)

private let qinfFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x51, 0x49, 0x4E, 0x46]
private let ciakFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x49, 0x41, 0x4B]
private let cropFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x52, 0x4F, 0x50]
private let dsopFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x53, 0x4F, 0x50, 0x00, 0x00, 0x00, 0x00,
]
private let calvFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]
private let cnopFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4E, 0x4F, 0x50]
private let coutFrame: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4F, 0x55, 0x54]
private let dinfFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04,
  0x5D, 0x00, 0x00, 0x03, 0x04, 0x02, 0x52,
]
private let cinnFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E, 0x03, 0x04, 0x02, 0x52, 0x00, 0x00, 0x00,
  0x01, 0x20, 0x00,
]

/// Observed DINF values (ADR table): origin -1920,0, size 3648x1117, cursor 772,594.
private let goldenScreen = BarrierScreenInfo(
  originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)
private let goldenEnter = BarrierEnter(
  x: 772, y: 594, sequence: BarrierEnterSequence(rawValue: 1),
  modifierMask: BarrierEnterModifierMask(rawValue: 0x2000))

private let qinfToken: [UInt8] = [0x51, 0x49, 0x4E, 0x46]
private let ciakToken: [UInt8] = [0x43, 0x49, 0x41, 0x4B]
private let cropToken: [UInt8] = [0x43, 0x52, 0x4F, 0x50]
private let dsopToken: [UInt8] = [0x44, 0x53, 0x4F, 0x50]
private let dinfToken: [UInt8] = [0x44, 0x49, 0x4E, 0x46]
private let cinnToken: [UInt8] = [0x43, 0x49, 0x4E, 0x4E]
private let coutToken: [UInt8] = [0x43, 0x4F, 0x55, 0x54]
private let calvToken: [UInt8] = [0x43, 0x41, 0x4C, 0x56]
private let cnopToken: [UInt8] = [0x43, 0x4E, 0x4F, 0x50]
private let dclpToken: [UInt8] = [0x44, 0x43, 0x4C, 0x50]
private let dkdnToken: [UInt8] = [0x44, 0x4B, 0x44, 0x4E]
private let dkupToken: [UInt8] = [0x44, 0x4B, 0x55, 0x50]

/// Synthetic excluded-frame body. Not Barrier bytes: BARRIER-EVID-0005 retains no excluded
/// body. The distinctive pattern lets tests prove the body never reaches any output.
private let syntheticExcludedBody: [UInt8] = [0xA5, 0x5A, 0xC3, 0x3C, 0x96, 0x69]

private func framePayload(_ frame: [UInt8]) -> [UInt8] { Array(frame.dropFirst(4)) }

private func frame(_ payload: [UInt8]) -> [UInt8] {
  let count = UInt32(payload.count)
  return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: count >> $0) } + payload
}

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

private func be32(_ value: UInt32) -> [UInt8] {
  [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
}

private func dinfPayload(
  originX: Int16, originY: Int16, width: UInt16, height: UInt16, reserved: UInt16 = 0,
  cursorX: UInt16, cursorY: UInt16
) -> [UInt8] {
  dinfToken + be16(UInt16(bitPattern: originX)) + be16(UInt16(bitPattern: originY))
    + be16(width) + be16(height) + be16(reserved) + be16(cursorX) + be16(cursorY)
}

private func cinnPayload(
  x: UInt16, y: UInt16, sequence: UInt32 = 1, modifierMask: UInt16 = 0x2000
) -> [UInt8] {
  cinnToken + be16(x) + be16(y) + be32(sequence) + be16(modifierMask)
}

private func makeDecoder(maximumPayloadLength: Int = limit) throws -> BarrierControlDecoder {
  try BarrierControlDecoder(maximumPayloadLength: maximumPayloadLength)
}

/// A decoder that has accepted the golden DINF and is ready for an enter.
private func decoderWithGoldenScreen() throws -> BarrierControlDecoder {
  var decoder = try makeDecoder()
  _ = try decoder.decode(payload: framePayload(dinfFrame), direction: .clientToServer)
  return decoder
}

private func expectFailure(
  _ expected: ControlError, payload: [UInt8], direction: BarrierControlDirection,
  decoder: inout BarrierControlDecoder, sourceLocation: SourceLocation = #_sourceLocation
) {
  let before = decoder.state
  #expect(throws: expected, sourceLocation: sourceLocation) {
    _ = try decoder.decode(payload: payload, direction: direction)
  }
  if case .failed = before {
    #expect(decoder.state == before, sourceLocation: sourceLocation)
  } else {
    #expect(decoder.state == .failed(expected), sourceLocation: sourceLocation)
  }
}

/// True when `value`, or any node reachable from it, is a string, a byte array, screen
/// geometry, a fixed-width integer (the shape of a wire field such as a coordinate, size,
/// sequence or mask) or a class instance. Only `Int` counts and limits and payload-free
/// enums pass. Class instances end the walk without being traversed.
private func reflectedGraphContainsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
  if value is BarrierScreenInfo || value is BarrierEnter { return true }
  if value is UInt8 || value is Int8 || value is UInt16 || value is Int16 || value is UInt32
    || value is Int32 || value is UInt64 || value is Int64 || value is UInt
  {
    return true
  }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { reflectedGraphContainsSensitiveShape($0.value) }
}

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

// MARK: - Golden bytes

@Test func goldenFramesEqualTheBarrierEvid0005FixtureBytesExactly() throws {
  let url = repositoryRoot().appendingPathComponent(
    "Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let streams = try #require(json["streams"] as? [[String: Any]])
  var consumable: [String: [[UInt8]]] = [:]
  for stream in streams {
    let direction = try #require(stream["direction"] as? String)
    for retained in try #require(stream["retainedFrames"] as? [[String: Any]]) {
      guard retained["classification"] as? String == "consumable" else { continue }
      let token = try #require(retained["token"] as? String)
      let base64 = try #require(retained["base64"] as? String)
      let bytes = [UInt8](try #require(Data(base64Encoded: base64)))
      #expect(bytes.count == retained["byteLength"] as? Int)
      consumable["\(direction) \(token)", default: []].append(bytes)
    }
  }
  #expect(
    consumable == [
      "server-to-client QINF": [qinfFrame],
      "server-to-client CIAK": [ciakFrame],
      "server-to-client CROP": [cropFrame],
      "server-to-client DSOP": [dsopFrame],
      "server-to-client CALV": [calvFrame],
      "server-to-client CINN": [cinnFrame],
      "server-to-client COUT": [coutFrame],
      "client-to-server DINF": [dinfFrame],
      "client-to-server CALV": [calvFrame],
      "client-to-server CNOP": [cnopFrame],
    ])
}

@Test func tokenBytesAreTheFrozenAsciiTokens() {
  let expected: [BarrierControlToken: [UInt8]] = [
    .qinf: qinfToken, .ciak: ciakToken, .crop: cropToken, .dsop: dsopToken,
    .dinf: dinfToken, .cinn: cinnToken, .cout: coutToken, .calv: calvToken,
    .cnop: cnopToken, .dclp: dclpToken, .dkdn: dkdnToken, .dkup: dkupToken,
  ]
  #expect(BarrierControlToken.allCases.count == expected.count)
  for token in BarrierControlToken.allCases {
    #expect(token.bytes == expected[token])
  }
}

@Test func goldenDinfDecodesToTheObservedFieldsAndItsPayloadBytesAreConsumedExactly() throws {
  var decoder = try makeDecoder()
  let outcome = try decoder.decode(payload: framePayload(dinfFrame), direction: .clientToServer)
  #expect(outcome == .event(.screenInfo(goldenScreen)))
  #expect(decoder.state == .setup(goldenScreen))
  // Re-serialising the decoded fields with the frozen layout reproduces the golden frame.
  let screen = try #require(decoder.state.screen)
  let rebuilt = frame(
    dinfPayload(
      originX: screen.originX, originY: screen.originY, width: screen.width,
      height: screen.height, cursorX: screen.cursorX, cursorY: screen.cursorY))
  #expect(rebuilt == dinfFrame)
}

@Test func goldenCinnDecodesToTheObservedFieldsWithOpaqueSequenceAndMask() throws {
  var decoder = try decoderWithGoldenScreen()
  let outcome = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
  #expect(outcome == .event(.enter(goldenEnter)))
  #expect(decoder.state == .active(goldenScreen))
  let rebuilt = frame(
    cinnPayload(
      x: goldenEnter.x, y: goldenEnter.y, sequence: goldenEnter.sequence.rawValue,
      modifierMask: goldenEnter.modifierMask.rawValue))
  #expect(rebuilt == cinnFrame)
}

// MARK: - Happy path for every allowed token and direction

@Test func observedControlSequenceDecodesEveryAllowedTokenInItsDirection() throws {
  var decoder = try makeDecoder()
  let steps: [([UInt8], BarrierControlDirection, BarrierControlOutcome, State)] = [
    (qinfFrame, .serverToClient, .event(.screenInfoRequested), .setup(nil)),
    (dinfFrame, .clientToServer, .event(.screenInfo(goldenScreen)), .setup(goldenScreen)),
    (ciakFrame, .serverToClient, .event(.setup(.ciak)), .setup(goldenScreen)),
    (cropFrame, .serverToClient, .event(.setup(.crop)), .setup(goldenScreen)),
    (dsopFrame, .serverToClient, .event(.setup(.dsopZero)), .setup(goldenScreen)),
    (calvFrame, .serverToClient, .keepalive(.keepalive(.serverToClient)), .setup(goldenScreen)),
    (calvFrame, .clientToServer, .keepalive(.keepalive(.clientToServer)), .setup(goldenScreen)),
    (cnopFrame, .clientToServer, .keepalive(.noOp), .setup(goldenScreen)),
    (cinnFrame, .serverToClient, .event(.enter(goldenEnter)), .active(goldenScreen)),
    (calvFrame, .serverToClient, .keepalive(.keepalive(.serverToClient)), .active(goldenScreen)),
    (coutFrame, .serverToClient, .event(.leave), .inactive(goldenScreen)),
    (calvFrame, .serverToClient, .keepalive(.keepalive(.serverToClient)), .inactive(goldenScreen)),
    (cnopFrame, .clientToServer, .keepalive(.noOp), .inactive(goldenScreen)),
  ]
  for (frameBytes, direction, outcome, state) in steps {
    #expect(try decoder.decode(payload: framePayload(frameBytes), direction: direction) == outcome)
    #expect(decoder.state == state)
  }
}

@Test func enterIsAcceptedAgainAfterLeaveAndValidatedAgainstTheReplacedScreen() throws {
  var decoder = try decoderWithGoldenScreen()
  _ = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
  _ = try decoder.decode(payload: framePayload(coutFrame), direction: .serverToClient)
  #expect(
    try decoder.decode(payload: framePayload(qinfFrame), direction: .serverToClient)
      == .event(.screenInfoRequested))
  let smaller = dinfPayload(
    originX: 0, originY: 0, width: 100, height: 50, cursorX: 10, cursorY: 10)
  _ = try decoder.decode(payload: smaller, direction: .clientToServer)
  let replaced = BarrierScreenInfo(
    originX: 0, originY: 0, width: 100, height: 50, cursorX: 10, cursorY: 10)
  #expect(decoder.state == .inactive(replaced))
  #expect(
    try decoder.decode(payload: cinnPayload(x: 99, y: 49), direction: .serverToClient)
      == .event(
        .enter(
          BarrierEnter(
            x: 99, y: 49, sequence: BarrierEnterSequence(rawValue: 1),
            modifierMask: BarrierEnterModifierMask(rawValue: 0x2000)))))
  _ = try decoder.decode(payload: framePayload(coutFrame), direction: .serverToClient)
  // The golden enter point lies outside the replaced 100x50 screen.
  expectFailure(
    .coordinateOutsideScreen(token: .cinn), payload: framePayload(cinnFrame),
    direction: .serverToClient, decoder: &decoder)
}

@Test func cinnSequenceAndModifierMaskPassThroughOpaqueForEveryExtremeValue() throws {
  for (sequence, mask) in [(UInt32(0), UInt16(0)), (.max, .max), (0x8000_0000, 0x8000)] {
    var decoder = try decoderWithGoldenScreen()
    let outcome = try decoder.decode(
      payload: cinnPayload(x: 0, y: 0, sequence: sequence, modifierMask: mask),
      direction: .serverToClient)
    #expect(
      outcome
        == .event(
          .enter(
            BarrierEnter(
              x: 0, y: 0, sequence: BarrierEnterSequence(rawValue: sequence),
              modifierMask: BarrierEnterModifierMask(rawValue: mask)))))
  }
}

// MARK: - DINF bounds and validation

@Test func dinfAcceptsOnlyPositiveNonZeroSizesUpTo0x7fff() throws {
  for size: UInt16 in [1, 2, 0x7FFE, 0x7FFF] {
    var decoder = try makeDecoder()
    let payload = dinfPayload(
      originX: 0, originY: 0, width: size, height: size, cursorX: 0, cursorY: 0)
    #expect(
      try decoder.decode(payload: payload, direction: .clientToServer)
        == .event(
          .screenInfo(
            BarrierScreenInfo(
              originX: 0, originY: 0, width: size, height: size, cursorX: 0, cursorY: 0))))
  }
  for size: UInt16 in [0, 0x8000, 0x8001, 0xFFFF] {
    var widthDecoder = try makeDecoder()
    expectFailure(
      .invalidScreenSize,
      payload: dinfPayload(originX: 0, originY: 0, width: size, height: 1, cursorX: 0, cursorY: 0),
      direction: .clientToServer, decoder: &widthDecoder)
    var heightDecoder = try makeDecoder()
    expectFailure(
      .invalidScreenSize,
      payload: dinfPayload(originX: 0, originY: 0, width: 1, height: size, cursorX: 0, cursorY: 0),
      direction: .clientToServer, decoder: &heightDecoder)
  }
}

@Test func dinfRejectsEveryNonZeroReservedValue() throws {
  for reserved: UInt16 in [0x0001, 0x0100, 0x8000, 0xFFFF] {
    var decoder = try makeDecoder()
    expectFailure(
      .nonZeroReservedField,
      payload: dinfPayload(
        originX: 0, originY: 0, width: 10, height: 10, reserved: reserved, cursorX: 0,
        cursorY: 0),
      direction: .clientToServer, decoder: &decoder)
  }
}

@Test func dinfCursorMustBeRawNonNegativeAndInsideItsOwnRectangle() throws {
  // Raw values with the high bit set are never accepted, whatever the rectangle.
  for raw: UInt16 in [0x8000, 0x8001, 0xFFFF] {
    var xDecoder = try makeDecoder()
    expectFailure(
      .coordinateOutOfRange(token: .dinf),
      payload: dinfPayload(
        originX: -32768, originY: -32768, width: 0x7FFF, height: 0x7FFF, cursorX: raw,
        cursorY: 0),
      direction: .clientToServer, decoder: &xDecoder)
    var yDecoder = try makeDecoder()
    expectFailure(
      .coordinateOutOfRange(token: .dinf),
      payload: dinfPayload(
        originX: 0, originY: 0, width: 0x7FFF, height: 0x7FFF, cursorX: 0, cursorY: raw),
      direction: .clientToServer, decoder: &yDecoder)
  }
  // The rectangle is [origin, origin + size): the first and last cells are inside.
  let inside: [(Int16, UInt16, UInt16)] = [
    (100, 10, 100), (100, 10, 109), (-1, 2, 0), (-1920, 3648, 1727), (0, 0x7FFF, 0x7FFE),
    (0x7FFF, 0x7FFF, 0x7FFF), (0x7FFE, 2, 0x7FFF),
  ]
  for (origin, size, cursor) in inside {
    var decoder = try makeDecoder()
    _ = try decoder.decode(
      payload: dinfPayload(
        originX: origin, originY: origin, width: size, height: size, cursorX: cursor,
        cursorY: cursor),
      direction: .clientToServer)
    #expect(decoder.state.screen?.cursorX == cursor)
  }
  let outside: [(Int16, UInt16, UInt16)] = [
    (100, 10, 99), (100, 10, 110), (-1, 2, 1), (-1920, 3648, 1728), (0, 0x7FFF, 0x7FFF),
    (-32768, 0x7FFF, 0), (-32768, 0x7FFF, 0x7FFF), (0x7FFF, 1, 0x7FFE),
  ]
  for (origin, size, cursor) in outside {
    var xDecoder = try makeDecoder()
    expectFailure(
      .coordinateOutsideScreen(token: .dinf),
      payload: dinfPayload(
        originX: origin, originY: 0, width: size, height: 10, cursorX: cursor, cursorY: 0),
      direction: .clientToServer, decoder: &xDecoder)
    var yDecoder = try makeDecoder()
    expectFailure(
      .coordinateOutsideScreen(token: .dinf),
      payload: dinfPayload(
        originX: 0, originY: origin, width: 10, height: size, cursorX: 0, cursorY: cursor),
      direction: .clientToServer, decoder: &yDecoder)
  }
}

@Test func dinfBodyMustBeExactlyFourteenBytes() throws {
  let body = Array(framePayload(dinfFrame).dropFirst(4))
  for count in [0, 1, 13, 15, 28] {
    let candidate =
      count <= body.count
      ? Array(body.prefix(count)) : body + [UInt8](repeating: 0, count: count - body.count)
    var decoder = try makeDecoder()
    expectFailure(
      .invalidBodyLength(token: .dinf, bodyByteCount: count), payload: dinfToken + candidate,
      direction: .clientToServer, decoder: &decoder)
  }
}

// MARK: - CINN bounds and validation

@Test func cinnFailsClosedWithoutACurrentScreen() throws {
  var decoder = try makeDecoder()
  expectFailure(
    .enterWithoutScreenInfo, payload: framePayload(cinnFrame), direction: .serverToClient,
    decoder: &decoder)
  // A rejected DINF leaves no screen behind: the decoder fails, so a later enter cannot
  // be accepted against stale or partial geometry.
  var rejected = try makeDecoder()
  expectFailure(
    .nonZeroReservedField,
    payload: dinfPayload(
      originX: 0, originY: 0, width: 10, height: 10, reserved: 1, cursorX: 0, cursorY: 0),
    direction: .clientToServer, decoder: &rejected)
  expectFailure(
    .nonZeroReservedField, payload: framePayload(cinnFrame), direction: .serverToClient,
    decoder: &rejected)
}

@Test func cinnCoordinatesMustBeRawNonNegativeAndInsideTheCurrentScreen() throws {
  let screen = dinfPayload(
    originX: 100, originY: 200, width: 10, height: 20, cursorX: 100, cursorY: 200)
  for (x, y) in [(UInt16(100), UInt16(200)), (109, 219), (100, 219), (109, 200)] {
    var decoder = try makeDecoder()
    _ = try decoder.decode(payload: screen, direction: .clientToServer)
    #expect(
      try decoder.decode(payload: cinnPayload(x: x, y: y), direction: .serverToClient)
        == .event(
          .enter(
            BarrierEnter(
              x: x, y: y, sequence: BarrierEnterSequence(rawValue: 1),
              modifierMask: BarrierEnterModifierMask(rawValue: 0x2000)))))
  }
  for (x, y) in [(UInt16(99), UInt16(200)), (110, 200), (100, 199), (100, 220), (0, 0)] {
    var decoder = try makeDecoder()
    _ = try decoder.decode(payload: screen, direction: .clientToServer)
    expectFailure(
      .coordinateOutsideScreen(token: .cinn), payload: cinnPayload(x: x, y: y),
      direction: .serverToClient, decoder: &decoder)
  }
  for (x, y) in [(UInt16(0x8000), UInt16(200)), (100, 0x8000), (0xFFFF, 0xFFFF)] {
    var decoder = try makeDecoder()
    _ = try decoder.decode(payload: screen, direction: .clientToServer)
    expectFailure(
      .coordinateOutOfRange(token: .cinn), payload: cinnPayload(x: x, y: y),
      direction: .serverToClient, decoder: &decoder)
  }
}

@Test func cinnBodyMustBeExactlyTenBytes() throws {
  let body = Array(framePayload(cinnFrame).dropFirst(4))
  for count in [0, 1, 9, 11, 20] {
    let candidate =
      count <= body.count
      ? Array(body.prefix(count)) : body + [UInt8](repeating: 0, count: count - body.count)
    var decoder = try decoderWithGoldenScreen()
    expectFailure(
      .invalidBodyLength(token: .cinn, bodyByteCount: count), payload: cinnToken + candidate,
      direction: .serverToClient, decoder: &decoder)
  }
}

// MARK: - Token-only frames and DSOP

@Test func tokenOnlyFramesRejectAnyBody() throws {
  let tokenOnly: [(BarrierControlToken, BarrierControlDirection)] = [
    (.qinf, .serverToClient), (.ciak, .serverToClient), (.crop, .serverToClient),
    (.calv, .serverToClient), (.calv, .clientToServer), (.cnop, .clientToServer),
    (.cout, .serverToClient),
  ]
  for (token, direction) in tokenOnly {
    for body in [[0x00], [0x00, 0x00, 0x00, 0x00]] as [[UInt8]] {
      var decoder = try decoderWithGoldenScreen()
      if token == .cout {
        _ = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
      }
      expectFailure(
        .invalidBodyLength(token: token, bodyByteCount: body.count), payload: token.bytes + body,
        direction: direction, decoder: &decoder)
    }
  }
}

@Test func dsopAcceptsOnlyAFourByteZeroBody() throws {
  for body in [[], [0x00], [0x00, 0x00, 0x00], [0x00, 0x00, 0x00, 0x00, 0x00]] as [[UInt8]] {
    var decoder = try makeDecoder()
    expectFailure(
      .invalidBodyLength(token: .dsop, bodyByteCount: body.count), payload: dsopToken + body,
      direction: .serverToClient, decoder: &decoder)
  }
  for value: UInt32 in [1, 0x0000_0100, 0x8000_0000, 0xFFFF_FFFF] {
    var decoder = try makeDecoder()
    expectFailure(
      .unsupportedSetupOption, payload: dsopToken + be32(value), direction: .serverToClient,
      decoder: &decoder)
  }
}

// MARK: - Direction

@Test func tokensFailClosedInTheDirectionTheyWereNotObservedIn() throws {
  let wrong: [(BarrierControlToken, [UInt8], BarrierControlDirection)] = [
    (.qinf, framePayload(qinfFrame), .clientToServer),
    (.ciak, framePayload(ciakFrame), .clientToServer),
    (.crop, framePayload(cropFrame), .clientToServer),
    (.dsop, framePayload(dsopFrame), .clientToServer),
    (.cinn, framePayload(cinnFrame), .clientToServer),
    (.cout, framePayload(coutFrame), .clientToServer),
    (.dinf, framePayload(dinfFrame), .serverToClient),
    (.cnop, framePayload(cnopFrame), .serverToClient),
    (.dclp, dclpToken + syntheticExcludedBody, .clientToServer),
    (.dkdn, dkdnToken + syntheticExcludedBody, .clientToServer),
    (.dkup, dkupToken + syntheticExcludedBody, .clientToServer),
  ]
  for (token, payload, direction) in wrong {
    var decoder = try decoderWithGoldenScreen()
    expectFailure(
      .unexpectedDirection(token: token, direction: direction), payload: payload,
      direction: direction, decoder: &decoder)
  }
  // Direction is checked before the body, so a malformed body cannot mask it.
  var decoder = try makeDecoder()
  expectFailure(
    .unexpectedDirection(token: .dinf, direction: .serverToClient), payload: dinfToken,
    direction: .serverToClient, decoder: &decoder)
}

// MARK: - Unknown tokens and limits

@Test func unknownTokensAndShortPayloadsFailClosedWithOnlyAByteCount() throws {
  let unknown: [[UInt8]] = [
    [], [0x51], [0x51, 0x49], [0x51, 0x49, 0x4E],  // shorter than any token
    [0x71, 0x69, 0x6E, 0x66],  // "qinf": tokens are case-sensitive
    [0x44, 0x4D, 0x4D, 0x56, 0x00, 0x01, 0x00, 0x02],  // DMMV: not frozen by M1-PROTOCOL-002
    [0x43, 0x42, 0x59, 0x45],  // CBYE: not frozen by M1-PROTOCOL-002
    [0x00, 0x00, 0x00, 0x00],
    [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06],  // hello payload
  ]
  for payload in unknown {
    for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
      var decoder = try decoderWithGoldenScreen()
      expectFailure(
        .unknownToken(payloadByteCount: payload.count), payload: payload, direction: direction,
        decoder: &decoder)
    }
  }
}

@Test func payloadLimitIsInclusiveAndCheckedBeforeDispatch() throws {
  #expect(BarrierControlDecoder.minimumMaximumPayloadLength == 18)
  #expect(throws: ControlError.invalidMaximumPayloadLength) {
    _ = try BarrierControlDecoder(maximumPayloadLength: 17)
  }
  #expect(throws: ControlError.invalidMaximumPayloadLength) {
    _ = try BarrierControlDecoder(maximumPayloadLength: -1)
  }
  // DINF is the largest consumable payload and fits exactly at the minimum limit.
  var atMinimum = try makeDecoder(maximumPayloadLength: 18)
  _ = try atMinimum.decode(payload: framePayload(dinfFrame), direction: .clientToServer)
  #expect(atMinimum.state == .setup(goldenScreen))

  // An excluded frame exactly at the limit is skipped; one byte more fails closed before
  // the token is inspected, so even an unknown token reports the oversize.
  let atLimit = dclpToken + [UInt8](repeating: 0xA5, count: limit - 4)
  var skipping = try makeDecoder()
  #expect(
    try skipping.decode(payload: atLimit, direction: .serverToClient)
      == .skipped(
        BarrierExcludedFrameDiagnostic(
          token: .dclp, direction: .serverToClient, payloadByteCount: limit,
          reason: .excludedSideEffectNotConsumable)))
  var over = try makeDecoder()
  expectFailure(
    .oversizePayload(limit: limit), payload: atLimit + [0xA5], direction: .serverToClient,
    decoder: &over)
  var overUnknown = try makeDecoder()
  expectFailure(
    .oversizePayload(limit: limit), payload: [UInt8](repeating: 0x00, count: limit + 1),
    direction: .clientToServer, decoder: &overUnknown)
}

// MARK: - Excluded frames

@Test func knownExcludedFramesAreSkippedWithAContentFreeDiagnostic() throws {
  for (token, tokenBytes) in [
    (BarrierControlToken.dclp, dclpToken), (.dkdn, dkdnToken), (.dkup, dkupToken),
  ] {
    for body in [[], syntheticExcludedBody] {
      for state in ["setup", "active", "inactive"] {
        var decoder = try decoderWithGoldenScreen()
        if state != "setup" {
          _ = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
        }
        if state == "inactive" {
          _ = try decoder.decode(payload: framePayload(coutFrame), direction: .serverToClient)
        }
        let before = decoder.state
        let outcome = try decoder.decode(payload: tokenBytes + body, direction: .serverToClient)
        let diagnostic = BarrierExcludedFrameDiagnostic(
          token: token, direction: .serverToClient, payloadByteCount: 4 + body.count,
          reason: .excludedSideEffectNotConsumable)
        #expect(outcome == .skipped(diagnostic))
        #expect(decoder.state == before)
        #expect(!reflectedGraphContainsSensitiveShape(outcome))
      }
    }
  }
}

// MARK: - Session state rules

@Test func stateRulesFailClosedOnUnobservedSequences() throws {
  // COUT without a preceding enter.
  var setupLeave = try decoderWithGoldenScreen()
  expectFailure(
    .unexpectedInState(token: .cout), payload: framePayload(coutFrame),
    direction: .serverToClient, decoder: &setupLeave)
  var inactiveLeave = try decoderWithGoldenScreen()
  _ = try inactiveLeave.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
  _ = try inactiveLeave.decode(payload: framePayload(coutFrame), direction: .serverToClient)
  expectFailure(
    .unexpectedInState(token: .cout), payload: framePayload(coutFrame),
    direction: .serverToClient, decoder: &inactiveLeave)

  // While active: no repeated enter and no screen-info exchange.
  let whileActive: [(BarrierControlToken, [UInt8], BarrierControlDirection)] = [
    (.cinn, framePayload(cinnFrame), .serverToClient),
    (.qinf, framePayload(qinfFrame), .serverToClient),
    (.dinf, framePayload(dinfFrame), .clientToServer),
    (.ciak, framePayload(ciakFrame), .serverToClient),
    (.crop, framePayload(cropFrame), .serverToClient),
    (.dsop, framePayload(dsopFrame), .serverToClient),
  ]
  for (token, payload, direction) in whileActive {
    var decoder = try decoderWithGoldenScreen()
    _ = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
    expectFailure(
      .unexpectedInState(token: token), payload: payload, direction: direction,
      decoder: &decoder)
  }

  // Setup frames are accepted only before the first enter.
  for (token, payload) in [
    (BarrierControlToken.ciak, framePayload(ciakFrame)), (.crop, framePayload(cropFrame)),
    (.dsop, framePayload(dsopFrame)),
  ] {
    var decoder = try decoderWithGoldenScreen()
    _ = try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient)
    _ = try decoder.decode(payload: framePayload(coutFrame), direction: .serverToClient)
    expectFailure(
      .unexpectedInState(token: token), payload: payload, direction: .serverToClient,
      decoder: &decoder)
  }
}

@Test func setupDinfMayBeReplacedBeforeTheFirstEnter() throws {
  var decoder = try decoderWithGoldenScreen()
  let replacement = dinfPayload(
    originX: 0, originY: 0, width: 800, height: 600, cursorX: 1, cursorY: 2)
  _ = try decoder.decode(payload: replacement, direction: .clientToServer)
  #expect(
    decoder.state
      == .setup(
        BarrierScreenInfo(
          originX: 0, originY: 0, width: 800, height: 600, cursorX: 1, cursorY: 2)))
}

@Test func failureIsStickyAndEveryLaterFrameRethrowsTheFirstError() throws {
  var decoder = try decoderWithGoldenScreen()
  expectFailure(
    .unknownToken(payloadByteCount: 4), payload: [0x00, 0x00, 0x00, 0x00],
    direction: .serverToClient, decoder: &decoder)
  let later: [([UInt8], BarrierControlDirection)] = [
    (framePayload(cinnFrame), .serverToClient), (framePayload(calvFrame), .serverToClient),
    (framePayload(cnopFrame), .clientToServer), (framePayload(dinfFrame), .clientToServer),
    (dclpToken, .serverToClient), ([UInt8](repeating: 0, count: limit + 1), .serverToClient),
  ]
  for (payload, direction) in later {
    expectFailure(
      .unknownToken(payloadByteCount: 4), payload: payload, direction: direction,
      decoder: &decoder)
  }
  #expect(decoder.state == .failed(.unknownToken(payloadByteCount: 4)))
}

@Test func keepaliveAndExcludedFramesNeverChangeStateInAnyLiveState() throws {
  var decoder = try makeDecoder()
  let neutral: [([UInt8], BarrierControlDirection)] = [
    (framePayload(calvFrame), .serverToClient), (framePayload(calvFrame), .clientToServer),
    (framePayload(cnopFrame), .clientToServer),
    (dkdnToken + syntheticExcludedBody, .serverToClient),
  ]
  let transitions: [([UInt8], BarrierControlDirection)] = [
    (framePayload(dinfFrame), .clientToServer), (framePayload(cinnFrame), .serverToClient),
    (framePayload(coutFrame), .serverToClient),
  ]
  for transition in [nil] + transitions.map(Optional.some) {
    if let (payload, direction) = transition {
      _ = try decoder.decode(payload: payload, direction: direction)
    }
    let before = decoder.state
    for (payload, direction) in neutral {
      _ = try decoder.decode(payload: payload, direction: direction)
      #expect(decoder.state == before)
    }
  }
}

@Test func freshDecodersAreIndependentAndRunsAreDeterministic() throws {
  let script: [([UInt8], BarrierControlDirection)] = [
    (framePayload(qinfFrame), .serverToClient), (framePayload(dinfFrame), .clientToServer),
    (framePayload(ciakFrame), .serverToClient), (framePayload(cropFrame), .serverToClient),
    (framePayload(dsopFrame), .serverToClient), (framePayload(cinnFrame), .serverToClient),
    (framePayload(coutFrame), .serverToClient),
  ]
  func run() throws -> ([BarrierControlOutcome], State) {
    var decoder = try makeDecoder()
    let outcomes = try script.map { try decoder.decode(payload: $0.0, direction: $0.1) }
    return (outcomes, decoder.state)
  }
  let first = try run()
  let second = try run()
  #expect(first.0 == second.0)
  #expect(first.1 == second.1)
  // Discarding a failed decoder and creating a new one is the documented reset path: the
  // new decoder starts in `setup(nil)` and is unaffected by the old failure.
  var failed = try makeDecoder()
  expectFailure(
    .enterWithoutScreenInfo, payload: framePayload(cinnFrame), direction: .serverToClient,
    decoder: &failed)
  let fresh = try makeDecoder()
  #expect(fresh.state == .setup(nil))
  #expect(try run().0 == first.0)
}

// MARK: - Keepalive isolation

@Test func keepaliveAndNoOpAreNeverControlEvents() throws {
  var decoder = try decoderWithGoldenScreen()
  for (payload, direction) in [
    (framePayload(calvFrame), BarrierControlDirection.serverToClient),
    (framePayload(calvFrame), .clientToServer), (framePayload(cnopFrame), .clientToServer),
  ] {
    let outcome = try decoder.decode(payload: payload, direction: direction)
    #expect(outcome.controlEvent == nil)
    guard case .keepalive = outcome else {
      Issue.record("keepalive frame produced \(outcome)")
      continue
    }
  }
  #expect(
    try decoder.decode(payload: framePayload(cinnFrame), direction: .serverToClient).controlEvent
      == .enter(goldenEnter))
}

/// Exhaustive over `BarrierControlEvent`: adding a keepalive, no-op or excluded case to
/// the control-event type stops this file from compiling.
private func controlEventKind(_ event: BarrierControlEvent) -> String {
  switch event {
  case .screenInfoRequested: "screenInfoRequested"
  case .setup: "setup"
  case .screenInfo: "screenInfo"
  case .enter: "enter"
  case .leave: "leave"
  }
}

@Test func controlEventTypeHasNoKeepaliveOrExcludedCase() {
  #expect(
    [
      BarrierControlEvent.screenInfoRequested, .setup(.ciak), .screenInfo(goldenScreen),
      .enter(goldenEnter), .leave,
    ].map(controlEventKind) == ["screenInfoRequested", "setup", "screenInfo", "enter", "leave"])
}

@Test func productionSourceImportsNothingAndNeverNamesKVMCoreTypes() throws {
  let source = try String(
    contentsOf: repositoryRoot().appendingPathComponent(
      "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierControlMessages.swift"),
    encoding: .utf8)
  // Comments may name KVMEvent to document the boundary; code lines may not.
  let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.hasPrefix("//") }
  #expect(!code.isEmpty)
  #expect(!code.contains { $0.hasPrefix("import ") || $0.contains(" import ") })
  for forbidden in ["KVMEvent", "KVMCore", "NativeProtocol", "print(", "Logger", "os_log"] {
    #expect(!code.contains { $0.contains(forbidden) }, "production code mentions \(forbidden)")
  }
}

// MARK: - Fragmentation, coalescing and truncation through BarrierFrameReassembler

/// Server-to-client control stream in observed order, with synthetic excluded frames
/// interleaved with keepalives while the client screen is active.
private let serverStream: [[UInt8]] = [
  qinfFrame, ciakFrame, cropFrame, dsopFrame, calvFrame, cinnFrame,
  frame(dclpToken + syntheticExcludedBody), calvFrame, frame(dkdnToken + syntheticExcludedBody),
  frame(dkupToken), calvFrame, coutFrame, calvFrame,
]

private func expectedServerOutcomes() -> [BarrierControlOutcome] {
  let skipped = { (token: BarrierControlToken, count: Int) in
    BarrierControlOutcome.skipped(
      BarrierExcludedFrameDiagnostic(
        token: token, direction: .serverToClient, payloadByteCount: count,
        reason: .excludedSideEffectNotConsumable))
  }
  let alive = BarrierControlOutcome.keepalive(.keepalive(.serverToClient))
  return [
    .event(.screenInfoRequested), .event(.setup(.ciak)), .event(.setup(.crop)),
    .event(.setup(.dsopZero)), alive, .event(.enter(goldenEnter)),
    skipped(.dclp, 4 + syntheticExcludedBody.count), alive,
    skipped(.dkdn, 4 + syntheticExcludedBody.count), skipped(.dkup, 4), alive, .event(.leave),
    alive,
  ]
}

/// Feeds `chunks` through a reassembler and the decoder; DINF is delivered on the
/// client-to-server path after the first server frame, as in the observed order.
private func decodeServerStream(
  _ chunks: [[UInt8]], decoder: inout BarrierControlDecoder,
  reassembler: inout BarrierFrameReassembler
) throws -> [BarrierControlOutcome] {
  var outcomes: [BarrierControlOutcome] = []
  for chunk in chunks {
    try reassembler.append(chunk)
    while let payload = try reassembler.nextPayload() {
      outcomes.append(try decoder.decode(payload: payload, direction: .serverToClient))
      if outcomes.count == 1 {
        _ = try decoder.decode(payload: framePayload(dinfFrame), direction: .clientToServer)
      }
    }
  }
  return outcomes
}

@Test func coalescedAndFragmentedStreamsYieldTheSameOutcomes() throws {
  let bytes = serverStream.flatMap { $0 }
  var fragmentations: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
  for cut in 1..<bytes.count {
    fragmentations.append([Array(bytes[..<cut]), Array(bytes[cut...])])
  }
  for chunks in fragmentations {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
    var decoder = try makeDecoder()
    let outcomes = try decodeServerStream(chunks, decoder: &decoder, reassembler: &reassembler)
    #expect(outcomes == expectedServerOutcomes())
    #expect(decoder.state == .inactive(goldenScreen))
    try reassembler.finish()
  }
}

@Test func clientStreamDecodesThroughTheReassemblerByteByByte() throws {
  let bytes = [dinfFrame, calvFrame, cnopFrame, cnopFrame].flatMap { $0 }
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
  var decoder = try makeDecoder()
  var outcomes: [BarrierControlOutcome] = []
  for byte in bytes {
    try reassembler.append([byte])
    while let next = try reassembler.nextPayload() {
      outcomes.append(try decoder.decode(payload: next, direction: .clientToServer))
    }
  }
  #expect(
    outcomes == [
      .event(.screenInfo(goldenScreen)), .keepalive(.keepalive(.clientToServer)),
      .keepalive(.noOp), .keepalive(.noOp),
    ])
}

@Test func truncatedStreamNeverHandsAPartialFrameToTheDecoder() throws {
  let bytes = serverStream.flatMap { $0 }
  var frameEnds: [Int] = []
  var end = 0
  for frameBytes in serverStream {
    end += frameBytes.count
    frameEnds.append(end)
  }
  for cut in 0..<bytes.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
    var decoder = try makeDecoder()
    let outcomes = try decodeServerStream(
      [Array(bytes[..<cut])], decoder: &decoder, reassembler: &reassembler)
    let completeFrames = frameEnds.filter { $0 <= cut }.count
    #expect(outcomes == Array(expectedServerOutcomes().prefix(completeFrames)))
    if frameEnds.contains(cut) || cut == 0 {
      try reassembler.finish()
    } else {
      #expect(throws: BarrierFrameReassemblerError.self) { try reassembler.finish() }
    }
  }
}

@Test func oversizeExcludedFrameIsRejectedByTheReassemblerBeforeBuffering() throws {
  // The caller configures the reassembler with the decoder's limit, so an excluded frame
  // whose prefix exceeds it fails before any body byte is buffered or decoded.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
  var decoder = try decoderWithGoldenScreen()
  let oversize = frame(dclpToken + [UInt8](repeating: 0xA5, count: limit - 3))
  #expect(throws: BarrierFrameReassemblerError.oversize(limit: limit)) {
    _ = try decodeServerStream(
      [Array(oversize.prefix(6))], decoder: &decoder, reassembler: &reassembler)
  }
  #expect(reassembler.pendingByteCount == 0)
  #expect(decoder.state == .setup(goldenScreen))
}

// MARK: - Sensitivity and privacy

@Test func everySingleBitFlipOfTheGoldenDinfAndCinnIsDetected() throws {
  // Flipping any one bit of a consumed payload must never yield the golden value. Flips in
  // the opaque CINN sequence and mask decode to a different opaque value by design; every
  // other flip either fails closed or changes a decoded field.
  let dinf = framePayload(dinfFrame)
  for index in dinf.indices {
    for mask: UInt8 in (0..<8).map({ 1 << $0 }) {
      var mutated = dinf
      mutated[index] ^= mask
      var decoder = try makeDecoder()
      let outcome = try? decoder.decode(payload: mutated, direction: .clientToServer)
      #expect(outcome != .event(.screenInfo(goldenScreen)), "DINF byte \(index) mask \(mask)")
    }
  }
  let cinn = framePayload(cinnFrame)
  for index in cinn.indices {
    for mask: UInt8 in (0..<8).map({ 1 << $0 }) {
      var mutated = cinn
      mutated[index] ^= mask
      var decoder = try decoderWithGoldenScreen()
      let outcome = try? decoder.decode(payload: mutated, direction: .serverToClient)
      #expect(outcome != .event(.enter(goldenEnter)), "CINN byte \(index) mask \(mask)")
    }
  }
}

/// Exhaustive over `BarrierControlMessageError`.
private func errorKind(_ error: ControlError) -> String {
  switch error {
  case .invalidMaximumPayloadLength: "invalidMaximumPayloadLength"
  case .oversizePayload: "oversizePayload"
  case .unknownToken: "unknownToken"
  case .unexpectedDirection: "unexpectedDirection"
  case .invalidBodyLength: "invalidBodyLength"
  case .unsupportedSetupOption: "unsupportedSetupOption"
  case .nonZeroReservedField: "nonZeroReservedField"
  case .invalidScreenSize: "invalidScreenSize"
  case .coordinateOutOfRange: "coordinateOutOfRange"
  case .coordinateOutsideScreen: "coordinateOutsideScreen"
  case .enterWithoutScreenInfo: "enterWithoutScreenInfo"
  case .unexpectedInState: "unexpectedInState"
  }
}

@Test func errorsAndStatesForFailuresCarryOnlyAllowlistedMetadata() throws {
  let errors: [ControlError] = [
    .invalidMaximumPayloadLength, .oversizePayload(limit: limit),
    .unknownToken(payloadByteCount: 4),
    .unexpectedDirection(token: .dinf, direction: .serverToClient),
    .invalidBodyLength(token: .cinn, bodyByteCount: 9), .unsupportedSetupOption,
    .nonZeroReservedField, .invalidScreenSize, .coordinateOutOfRange(token: .cinn),
    .coordinateOutsideScreen(token: .dinf), .enterWithoutScreenInfo,
    .unexpectedInState(token: .cout),
  ]
  // Every case is listed: errorKind is exhaustive, so a new case stops this file compiling
  // until it is added here and checked.
  #expect(Set(errors.map(errorKind)).count == 12)
  for error in errors {
    #expect(!reflectedGraphContainsSensitiveShape(error))
    #expect(!reflectedGraphContainsSensitiveShape(State.failed(error)))
  }
  // A failure triggered by real geometry drops that geometry from the state.
  var decoder = try decoderWithGoldenScreen()
  expectFailure(
    .coordinateOutOfRange(token: .cinn), payload: cinnPayload(x: 0x8000, y: 0),
    direction: .serverToClient, decoder: &decoder)
  #expect(decoder.state.screen == nil)
  #expect(!reflectedGraphContainsSensitiveShape(decoder.state))
}

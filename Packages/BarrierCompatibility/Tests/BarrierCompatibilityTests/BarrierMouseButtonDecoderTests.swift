// M1-033: Barrier DMDN/DMUP mouse button decoder.
// Contract: docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md
// (BARRIER-EVID-0006-CLAIM-002). The golden frames below are copied by hand from the M2-022
// capture fixture Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json
// and are also checked byte for byte against it, so no expected value is derived from the
// decoder under test. The wire-to-MouseButton table is the first-party table of
// BarrierServerInputEncoder, which the decoder inverts; every mapping is therefore also
// checked through that encoder.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private typealias DecoderError = BarrierMouseButtonDecoderError
private typealias DropDiagnostic = BarrierMouseButtonDropDiagnostic
private typealias Outcome = BarrierMouseButtonOutcome

// MARK: - Golden frames (BARRIER-EVID-0006)

private let dmdnToken: [UInt8] = [0x44, 0x4D, 0x44, 0x4E]
private let dmupToken: [UInt8] = [0x44, 0x4D, 0x55, 0x50]

// Whole frames: the 4-byte length (5), the token and a 1-byte button value. The digit in each
// name is the wire value, so the table under test is not baked into the names.
private let dmdn1Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x44, 0x4E, 0x01]
private let dmup1Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x55, 0x50, 0x01]
private let dmdn2Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x44, 0x4E, 0x02]
private let dmup2Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x55, 0x50, 0x02]
private let dmdn3Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x44, 0x4E, 0x03]
private let dmup3Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x55, 0x50, 0x03]
private let dmdn4Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x44, 0x4E, 0x04]
private let dmup4Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x55, 0x50, 0x04]
private let dmdn5Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x44, 0x4E, 0x05]
private let dmup5Frame: [UInt8] = [0x00, 0x00, 0x00, 0x05, 0x44, 0x4D, 0x55, 0x50, 0x05]

/// The client screen of the capture: 1600 x 900 at the origin.
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

private func event(_ button: MouseButton, _ phase: ButtonPhase) -> Outcome {
  .event(.mouseButton(button: button, phase: phase))
}

private func dropped(
  _ token: BarrierMouseButtonToken, _ reason: DropDiagnostic.Reason,
  direction: BarrierControlDirection = .serverToClient
) -> Outcome {
  .dropped(DropDiagnostic(token: token, direction: direction, bodyByteCount: 1, reason: reason))
}

/// One DMDN/DMUP frame of the capture, with the outcome the decoder owes for it.
private struct GoldenButtonFrame: Sendable {
  /// The 1-based `sequence` of the observation in the fixture.
  let sequence: Int
  let frame: [UInt8]
  let outcome: Outcome
}

/// All twelve button frames of the capture in observed order. The driver's X buttons 1, 3, 2,
/// 8 and 9 were captured as the wire values 1, 3, 2, 4 and 5, then a held wire value 1.
private let goldenButtonFrames: [GoldenButtonFrame] = [
  GoldenButtonFrame(sequence: 43, frame: dmdn1Frame, outcome: event(.left, .down)),
  GoldenButtonFrame(sequence: 44, frame: dmup1Frame, outcome: event(.left, .up)),
  GoldenButtonFrame(sequence: 47, frame: dmdn3Frame, outcome: event(.right, .down)),
  GoldenButtonFrame(sequence: 48, frame: dmup3Frame, outcome: event(.right, .up)),
  GoldenButtonFrame(sequence: 51, frame: dmdn2Frame, outcome: event(.middle, .down)),
  GoldenButtonFrame(sequence: 52, frame: dmup2Frame, outcome: event(.middle, .up)),
  GoldenButtonFrame(sequence: 55, frame: dmdn4Frame, outcome: event(.auxiliary, .down)),
  GoldenButtonFrame(sequence: 56, frame: dmup4Frame, outcome: event(.auxiliary, .up)),
  GoldenButtonFrame(
    sequence: 59, frame: dmdn5Frame, outcome: dropped(.dmdn, .unrepresentableButton)),
  GoldenButtonFrame(
    sequence: 60, frame: dmup5Frame, outcome: dropped(.dmup, .unrepresentableButton)),
  GoldenButtonFrame(sequence: 63, frame: dmdn1Frame, outcome: event(.left, .down)),
  GoldenButtonFrame(sequence: 70, frame: dmup1Frame, outcome: event(.left, .up)),
]

// MARK: - Helpers

/// The payload of a whole frame: everything after the 4-byte length prefix.
private func payload(of frame: [UInt8]) -> [UInt8] { Array(frame.dropFirst(4)) }

private func decodeServerToClient(_ payload: [UInt8]) throws -> Outcome {
  try BarrierMouseButtonDecoder.decode(payload: payload, direction: .serverToClient)
}

private func expectFailure(
  _ expected: DecoderError, payload: [UInt8],
  direction: BarrierControlDirection = .serverToClient,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: expected, sourceLocation: sourceLocation) {
    _ = try BarrierMouseButtonDecoder.decode(payload: payload, direction: direction)
  }
}

/// Exhaustive over `MouseButton`: a new case stops this file compiling until the decoder, the
/// encoder and this table agree on its wire value.
private func expectedWireValue(_ button: MouseButton) -> UInt8 {
  switch button {
  case .left: 1
  case .middle: 2
  case .right: 3
  case .auxiliary: 4
  }
}

/// Exhaustive over `KVMEvent`: a decoder that can produce any other case stops this file
/// compiling until the new case is considered.
private func eventKind(_ event: KVMEvent) -> String {
  switch event {
  case .mouseMove: "mouseMove"
  case .mouseButton: "mouseButton"
  case .scroll: "scroll"
  case .key: "key"
  case .clipboard: "clipboard"
  case .enterScreen: "enterScreen"
  case .leaveScreen: "leaveScreen"
  }
}

/// Exhaustive over `BarrierMouseButtonDecoderError`.
private func errorKind(_ error: DecoderError) -> String {
  switch error {
  case .unknownToken: "unknownToken"
  case .unexpectedDirection: "unexpectedDirection"
  case .invalidBodyLength: "invalidBodyLength"
  }
}

/// Exhaustive over the drop reasons.
private func reasonKind(_ reason: DropDiagnostic.Reason) -> String {
  switch reason {
  case .buttonOutOfContract: "buttonOutOfContract"
  case .unrepresentableButton: "unrepresentableButton"
  }
}

/// True when `value`, or any node reachable from it, is a string, a byte array, a
/// fixed-width integer (the shape of a wire field such as a button value) or a class
/// instance. Only `Int` counts and payload-free enums pass.
private func reflectedGraphContainsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
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

/// One complete server-to-client frame of the M2-022 server-input capture.
private struct CapturedFrame {
  /// The 1-based `sequence` of the observation.
  let sequence: Int
  /// The whole frame, length prefix included.
  let bytes: [UInt8]
}

/// Every server-to-client frame of the capture, in observed order.
private func capturedServerFrames() throws -> [CapturedFrame] {
  let url = repositoryRoot().appendingPathComponent(
    "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: [CapturedFrame] = []
  for observation in observations
  where observation["direction"] as? String == "server-to-client" {
    let sequence = try #require(observation["sequence"] as? Int)
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    frames.append(
      CapturedFrame(sequence: sequence, bytes: [UInt8](try #require(Data(base64Encoded: base64)))))
  }
  return frames
}

/// True when the frame's token, after the length prefix, is DMDN or DMUP. Independent of the
/// decoder under test.
private func isButtonFrame(_ frame: [UInt8]) -> Bool {
  guard frame.count >= 8 else { return false }
  let token = Array(frame[4..<8])
  return token == dmdnToken || token == dmupToken
}

/// What a client session does with each reassembled payload: route by the 4-byte token
/// prefix. Button tokens reach the decoder; every other payload is counted and left alone.
private struct RoutedPayloads {
  var outcomes: [Outcome] = []
  var elsewhere = 0

  mutating func route(_ payload: [UInt8]) throws {
    if BarrierMouseButtonToken(payloadPrefix: payload) != nil {
      outcomes.append(try decodeServerToClient(payload))
    } else {
      elsewhere += 1
    }
  }
}

/// Feeds `chunks` through the reassembler and routes every completed payload.
private func routeChunks(
  _ chunks: [[UInt8]], reassembler: inout BarrierFrameReassembler
) throws -> RoutedPayloads {
  var routed = RoutedPayloads()
  for chunk in chunks {
    try reassembler.append(chunk)
    while let payload = try reassembler.nextPayload() {
      try routed.route(payload)
    }
  }
  return routed
}

// MARK: - Tests

@Suite struct BarrierMouseButtonDecoderTests {
  // MARK: Golden bytes and tokens

  @Test func tokenBytesAreTheFrozenAsciiTokensAndPhases() {
    let expected: [BarrierMouseButtonToken: (bytes: [UInt8], phase: ButtonPhase)] = [
      .dmdn: (dmdnToken, .down),
      .dmup: (dmupToken, .up),
    ]
    #expect(BarrierMouseButtonToken.byteCount == 4)
    #expect(BarrierMouseButtonToken.allCases.count == expected.count)
    for token in BarrierMouseButtonToken.allCases {
      #expect(token.bytes == expected[token]?.bytes)
      #expect(token.phase == expected[token]?.phase)
      #expect(BarrierMouseButtonToken(payloadPrefix: token.bytes) == token)
      #expect(BarrierMouseButtonToken(payloadPrefix: token.bytes + [0x01, 0xFF]) == token)
    }
    // Case-sensitive, and nothing shorter than a token matches.
    #expect(BarrierMouseButtonToken(payloadPrefix: Array("dmdn".utf8)) == nil)
    #expect(BarrierMouseButtonToken(payloadPrefix: Array("DMD".utf8)) == nil)
    #expect(BarrierMouseButtonToken(payloadPrefix: []) == nil)
  }

  @Test func goldenButtonFramesEqualTheBarrierEvid0006FixtureBytesExactly() throws {
    let captured = try capturedServerFrames().filter { isButtonFrame($0.bytes) }
    #expect(captured.map(\.sequence) == goldenButtonFrames.map(\.sequence))
    #expect(captured.map(\.bytes) == goldenButtonFrames.map(\.frame))
    #expect(captured.count == 12)
  }

  @Test func capturedButtonFramesDecodeInOrderWithButtonFiveDropped() throws {
    let captured = try capturedServerFrames().filter { isButtonFrame($0.bytes) }
    let outcomes = try captured.map { try decodeServerToClient(payload(of: $0.bytes)) }
    #expect(outcomes == goldenButtonFrames.map(\.outcome))
    // The same sequence, spelled out: left, right, middle, auxiliary pressed and released,
    // the fifth button dropped both ways, then a left press and release.
    #expect(
      outcomes == [
        event(.left, .down), event(.left, .up), event(.right, .down), event(.right, .up),
        event(.middle, .down), event(.middle, .up), event(.auxiliary, .down),
        event(.auxiliary, .up), dropped(.dmdn, .unrepresentableButton),
        dropped(.dmup, .unrepresentableButton), event(.left, .down), event(.left, .up),
      ])
  }

  @Test func everyMouseButtonAndPhaseRoundTripsThroughTheServerEncoder() throws {
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    let cases: [(MouseButton, ButtonPhase, [UInt8])] = [
      (.left, .down, dmdn1Frame), (.left, .up, dmup1Frame),
      (.right, .down, dmdn3Frame), (.right, .up, dmup3Frame),
      (.middle, .down, dmdn2Frame), (.middle, .up, dmup2Frame),
      (.auxiliary, .down, dmdn4Frame), (.auxiliary, .up, dmup4Frame),
    ]
    #expect(Set(cases.map { expectedWireValue($0.0) }).count == 4)
    for (button, phase, golden) in cases {
      let encoded = encoder.button(button, phase: phase)
      // The encoder's frame is the captured frame, byte for byte, and ends in the wire value.
      #expect(encoded == golden, "\(button) \(phase)")
      #expect(encoded.last == expectedWireValue(button), "\(button) \(phase)")
      let outcome = try decodeServerToClient(payload(of: encoded))
      #expect(outcome == event(button, phase), "\(button) \(phase)")
    }
  }

  // MARK: Button table

  @Test func wireValuesFollowTheEncodersTableNotMouseButtonRawValues() throws {
    // The trap: MouseButton's raw values are left 1, right 2, middle 3, auxiliary 4, so
    // MouseButton(rawValue:) would swap right and middle.
    #expect(MouseButton(rawValue: 2) == .right)
    #expect(MouseButton(rawValue: 3) == .middle)
    // The wire table: 1 left, 2 middle, 3 right, 4 auxiliary.
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 1) == .left)
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 2) == .middle)
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 3) == .right)
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 4) == .auxiliary)
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 2) != MouseButton(rawValue: 2))
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 3) != MouseButton(rawValue: 3))
    // The same table through the whole decoder, for both phases.
    let table: [(UInt8, MouseButton)] = [(1, .left), (2, .middle), (3, .right), (4, .auxiliary)]
    for (wire, button) in table {
      #expect(try decodeServerToClient(dmdnToken + [wire]) == event(button, .down))
      #expect(try decodeServerToClient(dmupToken + [wire]) == event(button, .up))
      #expect(wire == expectedWireValue(button))
    }
    #expect(try decodeServerToClient(dmdnToken + [2]) != event(.right, .down))
    #expect(try decodeServerToClient(dmdnToken + [3]) != event(.middle, .down))
  }

  @Test func wireValueFiveIsDroppedAsUnrepresentableForDownAndUp() throws {
    // Wire 5 is inside the contract's 1 to 5, but MouseButton has no fifth case.
    #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: 5) == nil)
    #expect(
      try decodeServerToClient(dmdnToken + [5]) == dropped(.dmdn, .unrepresentableButton))
    #expect(
      try decodeServerToClient(dmupToken + [5]) == dropped(.dmup, .unrepresentableButton))
    // It is not reported as out of contract, and it is never mapped to a neighbor.
    #expect(
      try decodeServerToClient(dmdnToken + [5]) != dropped(.dmdn, .buttonOutOfContract))
    #expect(try decodeServerToClient(dmdnToken + [5]) != event(.auxiliary, .down))
    #expect(try decodeServerToClient(dmupToken + [5]) != event(.auxiliary, .up))
  }

  @Test func wireValuesOutsideOneToFiveAreDroppedForDownAndUp() throws {
    for value: UInt8 in [0, 6, 7, 127, 128, 255] {
      #expect(BarrierMouseButtonDecoder.mouseButton(wireValue: value) == nil, "value \(value)")
      #expect(
        try decodeServerToClient(dmdnToken + [value]) == dropped(.dmdn, .buttonOutOfContract),
        "DMDN \(value)")
      #expect(
        try decodeServerToClient(dmupToken + [value]) == dropped(.dmup, .buttonOutOfContract),
        "DMUP \(value)")
    }
  }

  @Test func everyPossibleBodyByteIsEmittedOrDroppedAndNeverThrows() throws {
    // An explicit table, independent of the decoder: wire value to button.
    let table: [UInt8: MouseButton] = [1: .left, 2: .middle, 3: .right, 4: .auxiliary]
    var emitted = 0
    var unrepresentable = 0
    var outOfContract = 0
    for value in UInt8.min...UInt8.max {
      for (token, bytes, phase) in [
        (BarrierMouseButtonToken.dmdn, dmdnToken, ButtonPhase.down),
        (.dmup, dmupToken, .up),
      ] {
        let outcome = try decodeServerToClient(bytes + [value])
        if let button = table[value] {
          #expect(outcome == event(button, phase), "\(token) \(value)")
          emitted += 1
        } else if value == 5 {
          #expect(outcome == dropped(token, .unrepresentableButton), "\(token) \(value)")
          unrepresentable += 1
        } else {
          #expect(outcome == dropped(token, .buttonOutOfContract), "\(token) \(value)")
          outOfContract += 1
        }
      }
    }
    // 256 values, two tokens: four buttons are emitted, wire value 5 is the only in-contract
    // value that is dropped, and everything else is out of contract.
    #expect(emitted == 8)
    #expect(unrepresentable == 2)
    #expect(outOfContract == 502)
  }

  @Test func aPressAndItsReleaseAreEmittedOrDroppedTogetherForEveryValue() throws {
    // Frozen Decision 7: a dropped release must never leave a button held. A DMUP is dropped
    // exactly when the DMDN with the same value is, so every press that is emitted can be
    // released by an emitted DMUP with the same value, and a dropped release never strands a
    // press of its own value.
    for value in UInt8.min...UInt8.max {
      let down = try decodeServerToClient(dmdnToken + [value])
      let up = try decodeServerToClient(dmupToken + [value])
      switch (down, up) {
      case (.event(.mouseButton(let pressed, .down)), .event(.mouseButton(let released, .up))):
        #expect(pressed == released, "value \(value)")
      case (.dropped(let pressDiagnostic), .dropped(let releaseDiagnostic)):
        #expect(pressDiagnostic.reason == releaseDiagnostic.reason, "value \(value)")
        #expect(pressDiagnostic.token == .dmdn && releaseDiagnostic.token == .dmup)
      default:
        Issue.record("value \(value): press \(down), release \(up)")
      }
    }
  }

  // MARK: Releases and the held button

  @Test func releaseWithoutAPressIsStillEmitted() throws {
    // The decoder keeps no pressed set, so a release is never dropped for lack of a press.
    for (wire, button) in [
      (UInt8(1), MouseButton.left), (2, .middle), (3, .right), (4, .auxiliary),
    ] {
      #expect(try decodeServerToClient(dmupToken + [wire]) == event(button, .up))
      #expect(try decodeServerToClient(dmupToken + [wire]) == event(button, .up))
    }
  }

  @Test func heldButtonSpansPointerMovesInTheFixtureStream() throws {
    // Observations 63 to 70 (1-based), server to client: DMDN 1, a DMMV, a CALV, DMUP 1.
    let window = try capturedServerFrames().filter { (63...70).contains($0.sequence) }
    #expect(window.map(\.sequence) == [63, 65, 67, 70])
    let tokens = window.map { Array($0.bytes[4..<8]) }
    #expect(tokens == [dmdnToken, Array("DMMV".utf8), Array("CALV".utf8), dmupToken])

    var routed = RoutedPayloads()
    for frame in window {
      try routed.route(payload(of: frame.bytes))
    }
    #expect(routed.outcomes == [event(.left, .down), event(.left, .up)])
    #expect(routed.elsewhere == 2)

    // The pointer move that falls between the press and the release is not a button payload:
    // offered to the button decoder it fails closed, so the session must route it elsewhere.
    expectFailure(
      .unknownToken(payloadByteCount: window[1].bytes.count - 4),
      payload: payload(of: window[1].bytes))
  }

  // MARK: Failures

  @Test func bodyMustBeExactlyOneByte() {
    #expect(BarrierMouseButtonDecoder.bodyByteCount == 1)
    for (token, bytes) in [(BarrierMouseButtonToken.dmdn, dmdnToken), (.dmup, dmupToken)] {
      for count in [0, 2, 3, 4, 9] {
        expectFailure(
          .invalidBodyLength(token: token, bodyByteCount: count),
          payload: bytes + [UInt8](repeating: 0x01, count: count))
      }
      // The body length is judged before the value: a wrong length with an out-of-contract
      // value is a length error, never a drop.
      expectFailure(
        .invalidBodyLength(token: token, bodyByteCount: 2), payload: bytes + [0x00, 0x00])
      expectFailure(
        .invalidBodyLength(token: token, bodyByteCount: 2), payload: bytes + [0x05, 0x05])
    }
  }

  @Test func clientToServerDirectionFailsClosedBeforeTheBody() {
    for (token, bytes) in [(BarrierMouseButtonToken.dmdn, dmdnToken), (.dmup, dmupToken)] {
      // A valid body, an unrepresentable one, an out-of-contract one and malformed lengths:
      // the direction is judged first, so none of them reaches the body rules.
      for body: [UInt8] in [[0x01], [0x05], [0x00], [], [0x01, 0x01]] {
        expectFailure(
          .unexpectedDirection(token: token, direction: .clientToServer), payload: bytes + body,
          direction: .clientToServer)
      }
    }
  }

  @Test func unknownAndShortTokensFailClosedWithOnlyAByteCount() {
    let unknown: [[UInt8]] = [
      [], [0x44], [0x44, 0x4D], [0x44, 0x4D, 0x44],  // shorter than a token
      Array("dmdn".utf8) + [0x01], Array("dmup".utf8) + [0x01],  // tokens are case-sensitive
      Array("DMDM".utf8) + [0x01],  // one letter off
      Array("DMMV".utf8) + [0x00, 0x0A, 0x01, 0xC2],  // the pointer token
      Array("DMWM".utf8) + [0x00, 0x00, 0x00, 0x78],  // the wheel token
      Array("DKDN".utf8) + [0x00, 0x61, 0x00, 0x00, 0x00, 0x26],  // a key token
      Array("CALV".utf8),  // a keepalive
      [0x00, 0x00, 0x00, 0x00],
      dmdn1Frame,  // a whole frame, length prefix included, is not a payload
    ]
    for payload in unknown {
      for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
        // The token is judged before the direction, so a foreign token never reports the
        // direction either.
        expectFailure(
          .unknownToken(payloadByteCount: payload.count), payload: payload, direction: direction)
      }
    }
  }

  // MARK: Output shape and privacy

  @Test func outcomeEventsAreAlwaysMouseButton() throws {
    var events = 0
    for value in UInt8.min...UInt8.max {
      for bytes in [dmdnToken, dmupToken] {
        if case .event(let event) = try decodeServerToClient(bytes + [value]) {
          #expect(eventKind(event) == "mouseButton", "value \(value)")
          events += 1
        }
      }
    }
    #expect(events == 8)
    // The phase follows the token: DMDN presses and DMUP releases, never the reverse.
    #expect(try decodeServerToClient(dmdnToken + [1]) == event(.left, .down))
    #expect(try decodeServerToClient(dmupToken + [1]) == event(.left, .up))
  }

  @Test func dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata() throws {
    // The walker is not vacuous: it flags each shape it exists to reject.
    struct Leak { let wireValue: UInt8 }
    #expect(reflectedGraphContainsSensitiveShape(Leak(wireValue: 1)))
    #expect(reflectedGraphContainsSensitiveShape([UInt8(1)]))
    #expect(reflectedGraphContainsSensitiveShape("1"))
    #expect(reflectedGraphContainsSensitiveShape(UInt16(1)))
    #expect(!reflectedGraphContainsSensitiveShape(1))

    var errors: [DecoderError] = [.unknownToken(payloadByteCount: 4)]
    var diagnostics: [DropDiagnostic] = []
    for token in BarrierMouseButtonToken.allCases {
      errors.append(.invalidBodyLength(token: token, bodyByteCount: 2))
      for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
        errors.append(.unexpectedDirection(token: token, direction: direction))
        for reason in [DropDiagnostic.Reason.buttonOutOfContract, .unrepresentableButton] {
          diagnostics.append(
            DropDiagnostic(token: token, direction: direction, bodyByteCount: 1, reason: reason))
        }
      }
    }
    // Every case is listed: errorKind and reasonKind are exhaustive, so a new case stops this
    // file compiling until it is added here and checked.
    #expect(Set(errors.map(errorKind)).count == 3)
    #expect(Set(diagnostics.map { reasonKind($0.reason) }).count == 2)
    for error in errors {
      #expect(!reflectedGraphContainsSensitiveShape(error), "\(errorKind(error))")
    }
    for diagnostic in diagnostics {
      #expect(!reflectedGraphContainsSensitiveShape(diagnostic))
    }
    // The diagnostics real decodes produce, for every value that is dropped.
    for value in UInt8.min...UInt8.max
    where BarrierMouseButtonDecoder.mouseButton(wireValue: value) == nil {
      for bytes in [dmdnToken, dmupToken] {
        let outcome = try decodeServerToClient(bytes + [value])
        guard case .dropped(let diagnostic) = outcome else {
          Issue.record("value \(value) was not dropped: \(outcome)")
          continue
        }
        #expect(diagnostic.bodyByteCount == 1)
        #expect(diagnostic.direction == .serverToClient)
        #expect(!reflectedGraphContainsSensitiveShape(diagnostic), "value \(value)")
      }
    }
  }

  // MARK: Fragmentation, coalescing and truncation through BarrierFrameReassembler

  @Test func fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated() throws {
    let frames = try capturedServerFrames()
    let bytes = frames.flatMap(\.bytes)
    let limit = 4096
    #expect(bytes.count < limit)
    let outcomeBySequence = Dictionary(
      uniqueKeysWithValues: goldenButtonFrames.map { ($0.sequence, $0.outcome) })
    // One optional outcome per frame: only the twelve button frames owe one.
    let perFrame: [Outcome?] = frames.map { outcomeBySequence[$0.sequence] }
    let expectedOutcomes = perFrame.compactMap { $0 }
    #expect(expectedOutcomes.count == 12)
    let others = frames.count - expectedOutcomes.count

    // Coalesced, one byte at a time, and split in two at every possible position.
    var fragmentations: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
    for cut in 1..<bytes.count {
      fragmentations.append([Array(bytes[..<cut]), Array(bytes[cut...])])
    }
    var mismatched: [Int] = []
    for (index, chunks) in fragmentations.enumerated() {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let routed = try routeChunks(chunks, reassembler: &reassembler)
      try reassembler.finish()
      if routed.outcomes != expectedOutcomes || routed.elsewhere != others {
        mismatched.append(index)
      }
    }
    #expect(mismatched.isEmpty, "fragmentations that changed the outcomes: \(mismatched.prefix(5))")

    // Truncated at every length: only complete frames reach the decoder, and a stream that
    // stops inside a frame cannot finish.
    var frameEnds: [Int] = []
    var end = 0
    for frame in frames {
      end += frame.bytes.count
      frameEnds.append(end)
    }
    var truncatedMismatches: [Int] = []
    for cut in 0..<bytes.count {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let routed = try routeChunks([Array(bytes[..<cut])], reassembler: &reassembler)
      let complete = frameEnds.filter { $0 <= cut }.count
      let expected = perFrame.prefix(complete).compactMap { $0 }
      if routed.outcomes != expected || routed.elsewhere != complete - expected.count {
        truncatedMismatches.append(cut)
      }
      if cut == 0 || frameEnds.contains(cut) {
        try reassembler.finish()
      } else {
        #expect(throws: BarrierFrameReassemblerError.self) { try reassembler.finish() }
      }
    }
    #expect(
      truncatedMismatches.isEmpty,
      "cuts that changed the outcomes: \(truncatedMismatches.prefix(5))")
  }

  // MARK: Statelessness

  @Test func decoderIsStatelessAndDeterministic() throws {
    let payloads = goldenButtonFrames.map { payload(of: $0.frame) }
    let expected = goldenButtonFrames.map(\.outcome)
    let forward = try payloads.map(decodeServerToClient)
    #expect(forward == expected)
    // Repeated passes and a reversed pass give each payload the same outcome as the first
    // pass, whatever was decoded before it.
    #expect(try payloads.map(decodeServerToClient) == forward)
    #expect(try payloads.reversed().map(decodeServerToClient) == Array(forward.reversed()))
    // There is no pressed set: a repeated press, a repeated release, a release first and a
    // release of another button all decode by their own bytes alone.
    #expect(try decodeServerToClient(dmdnToken + [1]) == event(.left, .down))
    #expect(try decodeServerToClient(dmdnToken + [1]) == event(.left, .down))
    #expect(try decodeServerToClient(dmupToken + [2]) == event(.middle, .up))
    #expect(try decodeServerToClient(dmupToken + [1]) == event(.left, .up))
    // A failure leaves nothing behind: unlike the control decoder it does not latch, and the
    // next valid payload decodes. Ending the session is the caller's job.
    expectFailure(.unknownToken(payloadByteCount: 0), payload: [])
    #expect(try decodeServerToClient(dmdnToken + [1]) == event(.left, .down))
    expectFailure(
      .unexpectedDirection(token: .dmup, direction: .clientToServer), payload: dmupToken + [1],
      direction: .clientToServer)
    #expect(try decodeServerToClient(dmupToken + [1]) == event(.left, .up))
    // The decoder is a caseless enum with static functions: no instance, no I/O, no timer, no
    // task and no resource exist, so there is nothing to cancel or clean up.
  }

  // MARK: Source boundary

  @Test func productionSourceImportsOnlyKVMContracts() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseButtonDecoder.swift"
      ),
      encoding: .utf8)
    // Comments may name other modules to document the boundary; code lines may not.
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    #expect(!code.isEmpty)
    #expect(
      code.filter { $0.hasPrefix("import ") || $0.contains(" import ") } == ["import KVMContracts"])
    for forbidden in [
      "Foundation", "KVMCore", "NativeProtocol", "CoreGraphics", "print(", "Logger", "os_log",
    ] {
      #expect(!code.contains { $0.contains(forbidden) }, "production code mentions \(forbidden)")
    }
  }

  @Test func productionSourceDeclaresNothingPublic() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseButtonDecoder.swift"
      ),
      encoding: .utf8)
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    for keyword in ["public ", "open ", "package "] {
      #expect(!code.contains { $0.hasPrefix(keyword) }, "production code declares \(keyword)")
    }
  }
}

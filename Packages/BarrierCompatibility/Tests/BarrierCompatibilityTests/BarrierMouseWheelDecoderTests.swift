// M1-034: Barrier `DMWM` wheel decoder (server-to-client wheel frame -> KVMEvent.scroll).
// Contract: docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md, "Wheel:
// DMWM" (BARRIER-EVID-0006-CLAIM-003). The four golden frames below are copied by hand from
// that ADR's notch table and are checked byte for byte against the DMWM frames of
// Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json, in the order the
// capture driver produced them: up, down, left, right.
//
// First-party convention, not a capture claim: in KVMEvent.scroll a positive deltaY scrolls up
// and a positive deltaX scrolls left, so the client rule inverts the horizontal axis:
// deltaX = -wireX / 120 and deltaY = wireY / 120, integer division toward zero. A left notch is
// (-120, 0) on the wire and decodes to deltaX = +1.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private typealias Wheel = BarrierMouseWheelDecoder
private typealias WheelError = BarrierMouseWheelDecoderError
private typealias WheelOutcome = BarrierMouseWheelOutcome

// MARK: - Golden frames (BARRIER-EVID-0006-CLAIM-003)

private let dmwmToken: [UInt8] = [0x44, 0x4D, 0x57, 0x4D]

/// Body: x delta then y delta, signed big-endian. Up (0, +120).
private let upFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x4D, 0x57, 0x4D, 0x00, 0x00, 0x00, 0x78,
]
/// Down (0, -120).
private let downFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x4D, 0x57, 0x4D, 0x00, 0x00, 0xFF, 0x88,
]
/// Left (-120, 0).
private let leftFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x4D, 0x57, 0x4D, 0xFF, 0x88, 0x00, 0x00,
]
/// Right (+120, 0).
private let rightFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x08, 0x44, 0x4D, 0x57, 0x4D, 0x00, 0x78, 0x00, 0x00,
]

/// The client screen of the capture: 1600 x 900 at the origin.
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

/// Reassembler payload limit; above the largest payload (18 bytes) of the fixture stream.
private let limit = 64

/// The largest whole-notch count one 16-bit wire value can carry: Int16.max / 120.
private let largestNotchCount: Int32 = 273

// MARK: - Helpers

private func framePayload(_ frame: [UInt8]) -> [UInt8] { Array(frame.dropFirst(4)) }

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

/// A complete `DMWM` payload (token and body) for signed wire deltas.
private func wheelPayload(wireX: Int16, wireY: Int16) -> [UInt8] {
  dmwmToken + be16(UInt16(bitPattern: wireX)) + be16(UInt16(bitPattern: wireY))
}

private func decodeWheel(wireX: Int16, wireY: Int16) throws -> WheelOutcome {
  try Wheel.decode(payload: wheelPayload(wireX: wireX, wireY: wireY), direction: .serverToClient)
}

private func scroll(_ deltaX: Int32, _ deltaY: Int32) -> WheelOutcome {
  .event(.scroll(deltaX: deltaX, deltaY: deltaY))
}

/// The drop a server-to-client `DMWM` with a four-byte body gets when no axis reaches a notch.
private let noWholeNotch = WheelOutcome.dropped(
  BarrierMouseWheelDropDiagnostic(
    token: .dmwm, direction: .serverToClient, bodyByteCount: 4, reason: .noWholeNotch))

/// Independent oracle for one axis: Double division rounded toward zero. Exact for 16-bit input
/// and free of the decoder's integer arithmetic.
private func wholeNotches(_ wire: Int16) -> Int32 {
  Int32((Double(wire) / 120).rounded(.towardZero))
}

private func thrownError(
  payload: [UInt8], direction: BarrierControlDirection = .serverToClient
) -> WheelError? {
  do throws(WheelError) {
    _ = try Wheel.decode(payload: payload, direction: direction)
    return nil
  } catch {
    return error
  }
}

/// Expects exactly `expected`, and that the thrown error holds no wire-shaped value.
private func expectFailure(
  _ expected: WheelError, payload: [UInt8],
  direction: BarrierControlDirection = .serverToClient,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let error = thrownError(payload: payload, direction: direction)
  #expect(error == expected, sourceLocation: sourceLocation)
  if let error {
    #expect(!reflectedGraphContainsSensitiveShape(error), sourceLocation: sourceLocation)
  }
}

/// True when `value`, or any node reachable from it, is a string, a byte array, a fixed-width
/// integer (the shape of a wire field such as a wheel delta) or a class instance. Only `Int`
/// counts and payload-free enums pass. Class instances end the walk without being traversed.
private func reflectedGraphContainsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
  if value is UInt8 || value is Int8 || value is UInt16 || value is Int16 { return true }
  if value is UInt32 || value is Int32 || value is UInt64 || value is Int64 { return true }
  if value is UInt { return true }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { reflectedGraphContainsSensitiveShape($0.value) }
}

/// Exhaustive over `BarrierMouseWheelDecoderError`: a new case stops this file compiling until
/// it is listed in the privacy test.
private func errorKind(_ error: WheelError) -> String {
  switch error {
  case .unknownToken: "unknownToken"
  case .unexpectedDirection: "unexpectedDirection"
  case .invalidBodyLength: "invalidBodyLength"
  }
}

/// Exhaustive over the drop reasons.
private func reasonKind(_ reason: BarrierMouseWheelDropDiagnostic.Reason) -> String {
  switch reason {
  case .noWholeNotch: "noWholeNotch"
  }
}

/// Exhaustive over `KVMEvent`: a new event case stops this file compiling until it is
/// classified.
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

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// Every complete frame of one direction of an M2-022 capture fixture, in capture order.
private func capturedFrames(
  fixture: String = "m2-022-linux-server-input/server-input-capture.json", direction: String
) throws -> [[UInt8]] {
  let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: [[UInt8]] = []
  for observation in observations where observation["direction"] as? String == direction {
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    frames.append([UInt8](try #require(Data(base64Encoded: base64))))
  }
  return frames
}

private func isWheelFrame(_ frame: [UInt8]) -> Bool {
  frame.dropFirst(4).starts(with: dmwmToken)
}

/// The `DMWM` frames of the capture's server-to-client stream, in capture order.
private func capturedWheelFrames() throws -> [[UInt8]] {
  try capturedFrames(direction: "server-to-client").filter(isWheelFrame)
}

/// Feeds `chunks` through the reassembler. Payloads are routed by their raw token bytes: a
/// `DMWM` payload reaches the decoder under test, every other token is another decoder's.
private func decodeWheelFrames(
  _ chunks: [[UInt8]], reassembler: inout BarrierFrameReassembler
) throws -> [WheelOutcome] {
  var outcomes: [WheelOutcome] = []
  for chunk in chunks {
    try reassembler.append(chunk)
    while let payload = try reassembler.nextPayload() {
      guard payload.starts(with: dmwmToken) else { continue }
      outcomes.append(try Wheel.decode(payload: payload, direction: .serverToClient))
    }
  }
  return outcomes
}

@Suite("M1-034 Barrier mouse wheel decoder")
struct BarrierMouseWheelDecoderTests {
  // MARK: - Golden bytes and named directions

  @Test func tokenBytesAreTheFrozenAsciiToken() {
    #expect(BarrierMouseWheelToken.allCases == [.dmwm])
    #expect(BarrierMouseWheelToken.dmwm.bytes == dmwmToken)
    #expect(BarrierMouseWheelToken.byteCount == 4)
    #expect(BarrierMouseWheelToken(payloadPrefix: dmwmToken) == .dmwm)
    #expect(BarrierMouseWheelToken(payloadPrefix: dmwmToken + [0, 0, 0, 0]) == .dmwm)
    #expect(BarrierMouseWheelToken(payloadPrefix: Array("DMWN".utf8)) == nil)
  }

  @Test func capturedNotchesDecodeToTheNamedDirectionsUpDownLeftRight() throws {
    // The fixture's four DMWM frames are the golden frames, in driver order.
    let captured = try capturedWheelFrames()
    #expect(captured == [upFrame, downFrame, leftFrame, rightFrame])
    // In KVMEvent.scroll a positive deltaY scrolls up and a positive deltaX scrolls left. The
    // left notch is (-120, 0) on the wire and must decode to deltaX = +1, the right notch
    // (+120, 0) to deltaX = -1: the horizontal axis is inverted, the vertical axis is not.
    let named: [(direction: String, expected: WheelOutcome)] = [
      ("up", scroll(0, 1)), ("down", scroll(0, -1)), ("left", scroll(1, 0)),
      ("right", scroll(-1, 0)),
    ]
    for (frame, notch) in zip(captured, named) {
      let outcome = try Wheel.decode(payload: framePayload(frame), direction: .serverToClient)
      #expect(outcome == notch.expected, "\(notch.direction) notch")
    }
  }

  @Test func capturedNotchFramesReEncodeByteForByteThroughTheServerEncoder() throws {
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    let captured = try capturedWheelFrames()
    #expect(captured.count == 4)
    for frame in captured {
      let outcome = try Wheel.decode(payload: framePayload(frame), direction: .serverToClient)
      guard case .event(.scroll(let deltaX, let deltaY)) = outcome else {
        Issue.record("a captured DMWM frame did not decode to a scroll: \(outcome)")
        continue
      }
      // The whole frame, length prefix included, not only the decoded deltas.
      #expect(encoder.scroll(deltaX: deltaX, deltaY: deltaY) == frame)
    }
  }

  // MARK: - Round trip with the first-party server encoder

  @Test func scrollRoundTripsThroughTheServerEncoderForEveryDeltaPairUpTo273() throws {
    // The decoder-side twin of the encoder's `scrollRoundTrip`: whatever the server sends for a
    // scroll decodes back to the same scroll. 273 is Int16.max / 120; beyond it the encoder
    // saturates, so the round trip is no longer exact (see the extremes test).
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    #expect(largestNotchCount == Int32(Int16.max) / 120)
    let deltas: [Int32] = [
      -largestNotchCount, -3, -2, -1, 0, 1, 2, 3, largestNotchCount,
    ]
    for deltaX in deltas {
      for deltaY in deltas where deltaX != 0 || deltaY != 0 {
        let frame = try #require(encoder.scroll(deltaX: deltaX, deltaY: deltaY))
        let outcome = try Wheel.decode(payload: framePayload(frame), direction: .serverToClient)
        #expect(outcome == scroll(deltaX, deltaY), "deltaX \(deltaX), deltaY \(deltaY)")
      }
    }
    // Each axis alone, over its whole exact range.
    for delta in -largestNotchCount...largestNotchCount where delta != 0 {
      let horizontal = try #require(encoder.scroll(deltaX: delta, deltaY: 0))
      let vertical = try #require(encoder.scroll(deltaX: 0, deltaY: delta))
      #expect(
        try Wheel.decode(payload: framePayload(horizontal), direction: .serverToClient)
          == scroll(delta, 0), "deltaX \(delta)")
      #expect(
        try Wheel.decode(payload: framePayload(vertical), direction: .serverToClient)
          == scroll(0, delta), "deltaY \(delta)")
    }
  }

  // MARK: - Per-axis rule

  @Test func horizontalAxisIsInvertedAndVerticalIsNot() throws {
    #expect(Wheel.unitsPerNotch == 120)
    // Horizontal: the wire sign is the opposite of the delta sign (positive deltaX scrolls left).
    #expect(Wheel.deltas(wireX: -120, wireY: 0).deltaX == 1, "left notch")
    #expect(Wheel.deltas(wireX: 120, wireY: 0).deltaX == -1, "right notch")
    #expect(Wheel.deltas(wireX: -240, wireY: 0).deltaX == 2)
    #expect(Wheel.deltas(wireX: 240, wireY: 0).deltaX == -2)
    // Vertical: the wire sign is the delta sign (positive deltaY scrolls up).
    #expect(Wheel.deltas(wireX: 0, wireY: 120).deltaY == 1, "up notch")
    #expect(Wheel.deltas(wireX: 0, wireY: -120).deltaY == -1, "down notch")
    #expect(Wheel.deltas(wireX: 0, wireY: 240).deltaY == 2)
    #expect(Wheel.deltas(wireX: 0, wireY: -240).deltaY == -2)
    // The axes are independent: a wire value on one axis never moves the other.
    #expect(Wheel.deltas(wireX: 120, wireY: 0).deltaY == 0)
    #expect(Wheel.deltas(wireX: 0, wireY: 120).deltaX == 0)
    // Both axes at once keep their own rule.
    #expect(try decodeWheel(wireX: -240, wireY: -120) == scroll(2, -1))
    #expect(try decodeWheel(wireX: 120, wireY: 360) == scroll(-1, 3))
    #expect(try decodeWheel(wireX: 240, wireY: -240) == scroll(-2, -2))
  }

  @Test func remaindersAreDroppedTowardZero() throws {
    // Wire value on one axis -> whole notches on that axis, the other axis staying 0.
    let cases: [(wire: Int16, notches: Int32)] = [
      (0, 0), (1, 0), (-1, 0), (60, 0), (-60, 0), (119, 0), (-119, 0),
      (120, 1), (-120, -1), (121, 1), (-121, -1), (239, 1), (-239, -1),
      (240, 2), (-240, -2), (241, 2), (-241, -2), (359, 2), (-359, -2), (360, 3), (-360, -3),
    ]
    for (wire, notches) in cases {
      // Vertical keeps the wire sign: -121 is -1, not -2 (floor division would give -2).
      #expect(Wheel.deltas(wireX: 0, wireY: wire).deltaY == notches, "wireY \(wire)")
      // Horizontal negates first: +121 is -1 and -121 is +1.
      #expect(Wheel.deltas(wireX: wire, wireY: 0).deltaX == -notches, "wireX \(wire)")
    }
    // A sub-notch axis is dropped while the other axis still counts.
    #expect(try decodeWheel(wireX: -119, wireY: 120) == scroll(0, 1))
    #expect(try decodeWheel(wireX: -120, wireY: 119) == scroll(1, 0))
    #expect(try decodeWheel(wireX: 121, wireY: -121) == scroll(-1, -1))
    #expect(try decodeWheel(wireX: -239, wireY: 239) == scroll(1, 1))
  }

  @Test func extremesDoNotOverflow() throws {
    // Int16.min has no Int16 negation, so the horizontal axis must widen before it negates.
    #expect(Wheel.deltas(wireX: .min, wireY: 0).deltaX == largestNotchCount)
    #expect(try decodeWheel(wireX: .min, wireY: .min) == scroll(273, -273))
    #expect(try decodeWheel(wireX: .max, wireY: .max) == scroll(-273, 273))
    #expect(try decodeWheel(wireX: .min, wireY: 0) == scroll(273, 0))
    #expect(try decodeWheel(wireX: .max, wireY: 0) == scroll(-273, 0))
    #expect(try decodeWheel(wireX: 0, wireY: .min) == scroll(0, -273))
    #expect(try decodeWheel(wireX: 0, wireY: .max) == scroll(0, 273))
    // The same bytes written out: 0x8000 is -32768 and 0x7FFF is 32767 on each axis.
    let minimum = dmwmToken + [0x80, 0x00, 0x80, 0x00]
    let maximum = dmwmToken + [0x7F, 0xFF, 0x7F, 0xFF]
    #expect(try Wheel.decode(payload: minimum, direction: .serverToClient) == scroll(273, -273))
    #expect(try Wheel.decode(payload: maximum, direction: .serverToClient) == scroll(-273, 273))
    // The first-party encoder saturates at these 16-bit bounds, so its extremes decode to them.
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    let largest = try #require(encoder.scroll(deltaX: .max, deltaY: .max))
    let smallest = try #require(encoder.scroll(deltaX: .min, deltaY: .min))
    #expect(
      try Wheel.decode(payload: framePayload(largest), direction: .serverToClient)
        == scroll(273, 273))
    #expect(
      try Wheel.decode(payload: framePayload(smallest), direction: .serverToClient)
        == scroll(-273, -273))
  }

  @Test func everyWireValueOnEachAxisMatchesAnIndependentTowardZeroOracle() throws {
    // Every Int16 on each axis with the other axis at zero: the outcome is the oracle's notch
    // count, or the drop when that count is zero.
    var mismatches: [String] = []
    for wire in Int16.min...Int16.max {
      let notches = wholeNotches(wire)
      let expectedHorizontal = notches == 0 ? noWholeNotch : scroll(-notches, 0)
      let expectedVertical = notches == 0 ? noWholeNotch : scroll(0, notches)
      if try decodeWheel(wireX: wire, wireY: 0) != expectedHorizontal {
        mismatches.append("wireX \(wire)")
      }
      if try decodeWheel(wireX: 0, wireY: wire) != expectedVertical {
        mismatches.append("wireY \(wire)")
      }
    }
    #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    // Both axes at once over the values around every boundary of the rule.
    let edges: [Int16] = [
      .min, -32767, -241, -240, -239, -121, -120, -119, -1, 0, 1, 119, 120, 121, 239, 240, 241,
      32766, .max,
    ]
    for wireX in edges {
      for wireY in edges {
        let deltaX = -wholeNotches(wireX)
        let deltaY = wholeNotches(wireY)
        let expected = deltaX == 0 && deltaY == 0 ? noWholeNotch : scroll(deltaX, deltaY)
        #expect(
          try decodeWheel(wireX: wireX, wireY: wireY) == expected, "wire (\(wireX), \(wireY))")
      }
    }
  }

  @Test func zeroOnBothAxesIsDroppedWithADiagnostic() throws {
    // Nothing reaches a whole notch: the frame is dropped with a diagnostic, and a zero scroll
    // is never emitted.
    let belowOneNotch: [(Int16, Int16)] = [
      (0, 0), (0, 60), (-60, 60), (119, -119), (0, 119), (0, -119), (-119, 0), (119, 0),
      (1, -1), (60, 60), (-119, -119),
    ]
    for (wireX, wireY) in belowOneNotch {
      #expect(
        try decodeWheel(wireX: wireX, wireY: wireY) == noWholeNotch, "wire (\(wireX), \(wireY))")
    }
    // The first notch on either axis ends the drop.
    #expect(try decodeWheel(wireX: 0, wireY: 120) == scroll(0, 1))
    #expect(try decodeWheel(wireX: 120, wireY: 0) == scroll(-1, 0))
  }

  // MARK: - Invalid input

  @Test func bodyMustBeExactlyFourBytes() {
    #expect(Wheel.bodyByteCount == 4)
    for count in [0, 1, 2, 3, 5, 6, 8, 12] {
      expectFailure(
        .invalidBodyLength(token: .dmwm, bodyByteCount: count),
        payload: dmwmToken + [UInt8](repeating: 0xA5, count: count))
    }
    #expect(thrownError(payload: dmwmToken + [0x00, 0x00, 0x00, 0x78]) == nil)
  }

  @Test func clientToServerDirectionFailsClosed() {
    expectFailure(
      .unexpectedDirection(token: .dmwm, direction: .clientToServer),
      payload: framePayload(upFrame), direction: .clientToServer)
    // Direction is checked before the body length, so a malformed body cannot mask it.
    for count in [0, 3, 5] {
      expectFailure(
        .unexpectedDirection(token: .dmwm, direction: .clientToServer),
        payload: dmwmToken + [UInt8](repeating: 0xA5, count: count), direction: .clientToServer)
    }
  }

  @Test func unknownAndShortTokensFailClosed() {
    let pointerBody: [UInt8] = [0x00, 0x0A, 0x01, 0xC2]
    let unknown: [[UInt8]] = [
      [], [0x44], [0x44, 0x4D], [0x44, 0x4D, 0x57],  // shorter than the token: "DMW"
      Array("dmwm".utf8) + pointerBody,  // tokens are case-sensitive
      Array("DMWN".utf8) + pointerBody,
      Array("DMMV".utf8) + pointerBody,  // the pointer token belongs to another decoder
      Array("DMDN".utf8) + [0x01],  // so does the button token
      Array("CINN".utf8) + pointerBody,
      upFrame,  // a whole frame, length prefix included, is not a payload
      [0x00, 0x00, 0x00, 0x00],
    ]
    for payload in unknown {
      for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
        // The token is checked before the direction.
        expectFailure(
          .unknownToken(payloadByteCount: payload.count), payload: payload, direction: direction)
      }
    }
  }

  // MARK: - Output type and privacy

  @Test func outcomeEventsAreAlwaysScroll() throws {
    var payloads = [upFrame, downFrame, leftFrame, rightFrame].map(framePayload)
    for wire: Int16 in [.min, -241, -120, -119, 0, 119, 120, 241, .max] {
      payloads.append(wheelPayload(wireX: wire, wireY: 0))
      payloads.append(wheelPayload(wireX: 0, wireY: wire))
      payloads.append(wheelPayload(wireX: wire, wireY: wire))
    }
    var events = 0
    for payload in payloads {
      switch try Wheel.decode(payload: payload, direction: .serverToClient) {
      case .event(let event):
        events += 1
        #expect(eventKind(event) == "scroll")
      case .dropped:
        break
      }
    }
    #expect(events > 0)
  }

  @Test func dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata() throws {
    let errors: [WheelError] = [
      .unknownToken(payloadByteCount: 3),
      .unexpectedDirection(token: .dmwm, direction: .clientToServer),
      .invalidBodyLength(token: .dmwm, bodyByteCount: 5),
    ]
    // Every case is listed: errorKind is exhaustive, so a new case stops this file compiling
    // until it is added here and checked.
    #expect(Set(errors.map(errorKind)).count == 3)
    for error in errors {
      #expect(!reflectedGraphContainsSensitiveShape(error))
    }
    let reasons: [BarrierMouseWheelDropDiagnostic.Reason] = [.noWholeNotch]
    #expect(Set(reasons.map(reasonKind)).count == 1)
    for reason in reasons {
      #expect(!reflectedGraphContainsSensitiveShape(reason))
    }
    // A drop caused by real wheel values carries none of them.
    let dropped = try decodeWheel(wireX: 59, wireY: -61)
    #expect(dropped == noWholeNotch)
    #expect(!reflectedGraphContainsSensitiveShape(dropped))
    // The walker detects the shapes it must reject, so the checks above are not vacuous.
    #expect(reflectedGraphContainsSensitiveShape(Int16(120)))
    #expect(reflectedGraphContainsSensitiveShape(Int32(1)))
    #expect(reflectedGraphContainsSensitiveShape("0000 0078"))
    #expect(reflectedGraphContainsSensitiveShape(wheelPayload(wireX: 0, wireY: 120)))
    #expect(reflectedGraphContainsSensitiveShape(try decodeWheel(wireX: 0, wireY: 120)))
    #expect(!reflectedGraphContainsSensitiveShape(4))
  }

  // MARK: - Fragmentation, coalescing and truncation through BarrierFrameReassembler

  @Test func fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated() throws {
    let frames = try capturedFrames(direction: "server-to-client")
    let bytes = frames.flatMap { $0 }
    let expected = [scroll(0, 1), scroll(0, -1), scroll(1, 0), scroll(-1, 0)]
    // The stream holds four wheel frames among many frames of other decoders' tokens.
    #expect(frames.filter(isWheelFrame).count == expected.count)
    #expect(frames.count > expected.count)

    // Coalesced: the whole stream in one chunk. Fragmented: one byte at a time.
    for chunks in [[bytes], bytes.map { [$0] }] {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      #expect(try decodeWheelFrames(chunks, reassembler: &reassembler) == expected)
      try reassembler.finish()
    }
    // Split in two at every byte boundary.
    for cut in 1..<bytes.count {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let outcomes = try decodeWheelFrames(
        [Array(bytes[..<cut]), Array(bytes[cut...])], reassembler: &reassembler)
      #expect(outcomes == expected, "split at \(cut)")
      try reassembler.finish()
    }

    // Truncated at every length: only the wheel frames completed before the cut are decoded,
    // and finish() reports a partial frame unless the cut falls on a frame boundary.
    var frameEnds = Set<Int>()
    var wheelFrameEnds: [Int] = []
    var end = 0
    for frame in frames {
      end += frame.count
      frameEnds.insert(end)
      if isWheelFrame(frame) { wheelFrameEnds.append(end) }
    }
    for cut in 0..<bytes.count {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let outcomes = try decodeWheelFrames([Array(bytes[..<cut])], reassembler: &reassembler)
      let completeWheelFrames = wheelFrameEnds.filter { $0 <= cut }.count
      #expect(outcomes == Array(expected.prefix(completeWheelFrames)), "truncated at \(cut)")
      if cut == 0 || frameEnds.contains(cut) {
        try reassembler.finish()
      } else {
        #expect(throws: BarrierFrameReassemblerError.self) { try reassembler.finish() }
      }
    }
  }

  // MARK: - State, determinism and architecture boundary

  @Test func decoderIsStatelessAndDeterministic() throws {
    // A caseless enum with static functions: no I/O, timer, task or resource, so there is
    // nothing to cancel or clean up. Cancellation tests do not apply; determinism and the
    // absence of state are what is checked.
    let up = framePayload(upFrame)
    let first = try Wheel.decode(payload: up, direction: .serverToClient)
    #expect(first == scroll(0, 1))
    // A rejected payload latches nothing: the same payload decodes the same way afterwards.
    expectFailure(
      .invalidBodyLength(token: .dmwm, bodyByteCount: 3), payload: dmwmToken + [0x00, 0x00, 0x78])
    expectFailure(
      .unexpectedDirection(token: .dmwm, direction: .clientToServer), payload: up,
      direction: .clientToServer)
    expectFailure(.unknownToken(payloadByteCount: 0), payload: [])
    for _ in 0..<100 {
      #expect(try Wheel.decode(payload: up, direction: .serverToClient) == first)
    }
    // The outcome of one payload does not depend on the payloads decoded before it.
    let forward = try [upFrame, downFrame, leftFrame, rightFrame].map {
      try Wheel.decode(payload: framePayload($0), direction: .serverToClient)
    }
    let backward = try [rightFrame, leftFrame, downFrame, upFrame].map {
      try Wheel.decode(payload: framePayload($0), direction: .serverToClient)
    }
    #expect(forward == backward.reversed())
  }

  @Test func productionSourceImportsOnlyKVMContracts() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseWheelDecoder.swift"
      ),
      encoding: .utf8)
    // Comments may name other modules to document the boundary; code lines may not.
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import KVMContracts"])
    let forbidden = [
      "Foundation", "KVMCore", "NativeProtocol", "MacPlatform", "print(", "Logger", "os_log",
    ]
    for name in forbidden {
      #expect(!code.contains { $0.contains(name) }, "production code mentions \(name)")
    }
  }
}

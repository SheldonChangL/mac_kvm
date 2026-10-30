// M1-032: Barrier `DMMV` pointer decoder, client pixels to `KVMEvent.mouseMove`.
// Contract: docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md
// (BARRIER-EVID-0006-CLAIM-001). The input frames are the server-to-client `DMMV` frames of
// Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json, and every pixel
// mapping is round-tripped through BarrierServerInputEncoder, the first-party inverse, so a
// sign, axis or off-by-one error in the mapping cannot ship unnoticed. Expected bytes and
// values come from the fixture, the register, hand-computed constants and the encoder, never
// from the decoder under test.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private typealias MoveError = BarrierMouseMoveDecoderError
private typealias Reason = BarrierMouseMoveDropDiagnostic.Reason

/// Reassembler limit for the fixture stream: its largest server-to-client payload is 18 bytes.
private let limit = 64

/// Floating-point slack for comparing a decoded value with its real-number bound.
private let tolerance = 1e-12

private let dmmvToken: [UInt8] = [0x44, 0x4D, 0x4D, 0x56]

/// BARRIER-EVID-0006-CLAIM-001: the seven observed positions, in capture order, and the
/// `sequence` of the observation that holds each one.
private let observedPixels: [(x: UInt16, y: UInt16)] = [
  (10, 450), (10, 460), (0, 460), (0, 450), (100, 500), (101, 501), (116, 506),
]
private let observedSequences = [28, 30, 32, 34, 39, 41, 65]

/// The client screen of the capture: 1600 x 900 at the origin (the client `DINF`).
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

/// A screen whose cursor sits on the first cell the wire can name.
private func screen(
  originX: Int16 = 0, originY: Int16 = 0, width: UInt16, height: UInt16
) -> BarrierScreenInfo {
  BarrierScreenInfo(
    originX: originX, originY: originY, width: width, height: height,
    cursorX: UInt16(max(Int(originX), 0)), cursorY: UInt16(max(Int(originY), 0)))
}

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

/// A complete frame: the 4-byte big-endian length prefix, then `payload`.
private func frame(_ payload: [UInt8]) -> [UInt8] {
  let count = UInt32(payload.count)
  return [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: count >> $0) } + payload
}

private func framePayload(_ frame: [UInt8]) -> [UInt8] { Array(frame.dropFirst(4)) }

private func dmmv(x: UInt16, y: UInt16) -> [UInt8] { dmmvToken + be16(x) + be16(y) }

private func decode(
  _ payload: [UInt8], on screen: BarrierScreenInfo = captureScreen,
  direction: BarrierControlDirection = .serverToClient
) throws -> BarrierMouseMoveOutcome {
  try BarrierMouseMoveDecoder(screen: screen).decode(payload: payload, direction: direction)
}

private func moved(x: Double, y: Double) -> BarrierMouseMoveOutcome {
  .event(.mouseMove(position: NormalizedPoint(x: x, y: y)))
}

private func dropped(_ reason: Reason) -> BarrierMouseMoveOutcome {
  .dropped(
    BarrierMouseMoveDropDiagnostic(
      token: .dmmv, direction: .serverToClient, bodyByteCount: 4, reason: reason))
}

private func position(_ outcome: BarrierMouseMoveOutcome) -> NormalizedPoint? {
  if case .event(.mouseMove(let position)) = outcome { position } else { nil }
}

private func expectFailure(
  _ expected: MoveError, payload: [UInt8],
  direction: BarrierControlDirection = .serverToClient,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(throws: expected, sourceLocation: sourceLocation) {
    _ = try decode(payload, direction: direction)
  }
}

/// The raw values the wire can carry that lie inside `origin ..< origin + extent`: raw values
/// are accepted only in `0...0x7FFF`, so negative pixels and pixels above 0x7FFF cannot be named.
private func reachable(origin: Int16, extent: UInt16) -> Range<Int> {
  let lower = max(Int(origin), 0)
  let upper = min(Int(origin) + Int(extent), 0x8000)
  return lower..<max(lower, upper)
}

/// Every pixel in `pixels` for which decode-then-encode on `screen` does not reproduce the
/// frame. Empty when the encoder is an exact inverse of the decoder over `pixels`.
private func roundTripFailures(
  on screen: BarrierScreenInfo, pixels: [(x: Int, y: Int)]
) throws -> [String] {
  let encoder = BarrierServerInputEncoder(screen: screen)
  var failures: [String] = []
  for pixel in pixels {
    let payload = dmmv(x: UInt16(pixel.x), y: UInt16(pixel.y))
    guard let point = position(try decode(payload, on: screen)) else {
      failures.append("(\(pixel.x), \(pixel.y)): not decoded to a move")
      continue
    }
    if encoder.pointer(to: point) != frame(payload) {
      failures.append("(\(pixel.x), \(pixel.y)): re-encoded to another pixel")
    }
  }
  return failures
}

/// Every complete frame (length prefix included) of one direction of an M2-022 capture
/// fixture, in capture order, with the observation's `sequence`.
private func capturedFrames(
  fixture: String = "m2-022-linux-server-input/server-input-capture.json", direction: String
) throws -> [(sequence: Int, frame: [UInt8])] {
  let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: [(sequence: Int, frame: [UInt8])] = []
  for observation in observations where observation["direction"] as? String == direction {
    let sequence = try #require(observation["sequence"] as? Int)
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    frames.append((sequence, [UInt8](try #require(Data(base64Encoded: base64)))))
  }
  return frames
}

/// The captured server-to-client `DMMV` frames.
private func capturedMoves() throws -> [(sequence: Int, frame: [UInt8])] {
  try capturedFrames(direction: "server-to-client").filter {
    framePayload($0.frame).starts(with: dmmvToken)
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

/// True when `value`, or any node reachable from it, is a string, a byte array, screen geometry,
/// a fixed-width integer or floating-point number (the shape of a wire or normalized coordinate)
/// or a class instance. Only `Int` counts and payload-free enums pass. Class instances end the
/// walk without being traversed.
private func reflectedGraphContainsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
  if value is BarrierScreenInfo || value is NormalizedPoint { return true }
  if value is UInt8 || value is Int8 || value is UInt16 || value is Int16 { return true }
  if value is UInt32 || value is Int32 || value is UInt64 || value is Int64 { return true }
  if value is UInt || value is Double || value is Float { return true }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { reflectedGraphContainsSensitiveShape($0.value) }
}

/// Exhaustive over `KVMEvent`: a new event case stops this file compiling until the decoder's
/// output type is reconsidered.
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

/// Exhaustive over `BarrierMouseMoveDecoderError`.
private func errorKind(_ error: MoveError) -> String {
  switch error {
  case .unknownToken: "unknownToken"
  case .unexpectedDirection: "unexpectedDirection"
  case .invalidBodyLength: "invalidBodyLength"
  }
}

/// Exhaustive over `BarrierMouseMoveDropDiagnostic.Reason`.
private func reasonKind(_ reason: Reason) -> String {
  switch reason {
  case .coordinateOutOfRange: "coordinateOutOfRange"
  case .coordinateOutsideScreen: "coordinateOutsideScreen"
  }
}

/// Feeds `chunks` through a reassembler and hands every payload whose token is `DMMV` to the
/// decoder. Every other payload (hello, control, button, wheel and key frames) belongs to
/// another decoder and is ignored, as the client session routes by token prefix.
private func decodeMoves(
  _ chunks: [[UInt8]], decoder: BarrierMouseMoveDecoder,
  reassembler: inout BarrierFrameReassembler
) throws -> [BarrierMouseMoveOutcome] {
  var outcomes: [BarrierMouseMoveOutcome] = []
  for chunk in chunks {
    try reassembler.append(chunk)
    while let payload = try reassembler.nextPayload() {
      guard BarrierMouseMoveToken(payloadPrefix: payload) != nil else { continue }
      outcomes.append(try decoder.decode(payload: payload, direction: .serverToClient))
    }
  }
  return outcomes
}

@Suite("M1-032 Barrier DMMV pointer decoder")
struct BarrierMouseMoveDecoderTests {
  // MARK: - Token

  @Test func tokenBytesAreTheFrozenAsciiToken() {
    #expect(BarrierMouseMoveToken.allCases == [.dmmv])
    #expect(BarrierMouseMoveToken.byteCount == 4)
    #expect(BarrierMouseMoveToken.dmmv.bytes == dmmvToken)
    #expect(BarrierMouseMoveToken.dmmv.bytes == Array("DMMV".utf8))
    #expect(BarrierMouseMoveToken(payloadPrefix: dmmvToken) == .dmmv)
    #expect(BarrierMouseMoveToken(payloadPrefix: dmmv(x: 1, y: 2)) == .dmmv)
    // Case-sensitive, and a prefix shorter than the token never matches.
    #expect(BarrierMouseMoveToken(payloadPrefix: Array("dmmv".utf8)) == nil)
    #expect(BarrierMouseMoveToken(payloadPrefix: Array("DMM".utf8)) == nil)
    #expect(BarrierMouseMoveToken(payloadPrefix: []) == nil)
  }

  // MARK: - Golden frames

  @Test func capturedDmmvFramesDecodeToTheObservedPixelsNormalizedByExtentMinusOne() throws {
    let moves = try capturedMoves()
    #expect(moves.map(\.sequence) == observedSequences)
    for (move, pixel) in zip(moves, observedPixels) {
      let payload = framePayload(move.frame)
      // The fixture holds exactly the pair the register records for this observation.
      #expect(payload == dmmv(x: pixel.x, y: pixel.y), "observation \(move.sequence)")
      // normalized = pixel / (extent - 1): 1599 columns and 899 rows on the 1600 x 900 screen.
      let expected = moved(x: Double(pixel.x) / 1599, y: Double(pixel.y) / 899)
      #expect(try decode(payload) == expected, "observation \(move.sequence)")
    }
    #expect(moves.count == observedPixels.count)
  }

  @Test func capturedDmmvFramesReEncodeByteForByteThroughTheServerEncoder() throws {
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    for move in try capturedMoves() {
      let outcome = try decode(framePayload(move.frame))
      let point = try #require(position(outcome), "observation \(move.sequence)")
      // The whole frame, length prefix included, equals the captured bytes.
      #expect(encoder.pointer(to: point) == move.frame, "observation \(move.sequence)")
    }
  }

  // MARK: - Round trips through the encoder

  @Test func everyReachablePixelRoundTripsDecodeThenEncode() throws {
    // Small screens are swept exhaustively on both axes. Width and height differ, so a decoder
    // that swaps the axes cannot round-trip. Origin -3 hides three columns that no raw value
    // can name, and origin 0x7FF9 ends exactly at the top of the raw range.
    let small: [BarrierScreenInfo] = [
      screen(width: 7, height: 5),
      screen(originX: 100, originY: 100, width: 7, height: 5),
      screen(originX: -3, originY: -3, width: 7, height: 5),
      screen(originX: 0x7FF9, originY: 0x7FF9, width: 7, height: 5),
      screen(originX: -2, originY: 3, width: 5, height: 7),
      screen(width: 1, height: 1),
      screen(originX: 0x7FFF, originY: 0x7FFF, width: 1, height: 1),
    ]
    for candidate in small {
      let columns = reachable(origin: candidate.originX, extent: candidate.width)
      let rows = reachable(origin: candidate.originY, extent: candidate.height)
      #expect(!columns.isEmpty && !rows.isEmpty)
      let pixels = rows.flatMap { y in columns.map { x in (x: x, y: y) } }
      #expect(try roundTripFailures(on: candidate, pixels: pixels).isEmpty, "\(candidate)")
    }

    // The capture screen, other common sizes, a non-zero origin and the largest extent the
    // contract allows are swept along each axis: every column on the first row, then every row
    // on the first column.
    let large: [BarrierScreenInfo] = [
      captureScreen,
      screen(width: 1920, height: 1080),
      screen(originX: 1920, originY: 40, width: 1920, height: 1080),
      screen(width: 3840, height: 2160),
      screen(width: 0x7FFF, height: 0x7FFF),
    ]
    for candidate in large {
      let columns = reachable(origin: candidate.originX, extent: candidate.width)
      let rows = reachable(origin: candidate.originY, extent: candidate.height)
      var pixels = columns.map { (x: $0, y: rows.lowerBound) }
      pixels += rows.map { (x: columns.lowerBound, y: $0) }
      let failures = try roundTripFailures(on: candidate, pixels: pixels)
      #expect(failures.isEmpty, "\(candidate): \(failures.prefix(3))")
    }
  }

  @Test func edgesAndCenterRoundTripThroughTheEncoder() throws {
    // Edges are exact both ways: 0.0 is the origin pixel and decodes to 0.0, and 1.0 is the
    // last pixel of the rectangle and decodes to 1.0, on every screen that has two or more
    // pixels per axis and lies inside 0...0x7FFF.
    let screens: [BarrierScreenInfo] = [
      captureScreen,
      screen(width: 7, height: 5),
      screen(originX: 100, originY: 200, width: 1601, height: 901),
      screen(originX: 3, originY: 4, width: 2, height: 2),
    ]
    for candidate in screens {
      let encoder = BarrierServerInputEncoder(screen: candidate)
      let first = (x: UInt16(candidate.originX), y: UInt16(candidate.originY))
      let last = (
        x: first.x + candidate.width - 1, y: first.y + candidate.height - 1
      )
      let low = encoder.pointer(to: NormalizedPoint(x: 0, y: 0))
      #expect(framePayload(low) == dmmv(x: first.x, y: first.y), "\(candidate)")
      #expect(try decode(framePayload(low), on: candidate) == moved(x: 0, y: 0), "\(candidate)")
      let high = encoder.pointer(to: NormalizedPoint(x: 1, y: 1))
      #expect(framePayload(high) == dmmv(x: last.x, y: last.y), "\(candidate)")
      #expect(try decode(framePayload(high), on: candidate) == moved(x: 1, y: 1), "\(candidate)")
    }

    // A one-pixel axis has a single position: both edges are that pixel, and it decodes to 0.
    let single = screen(originX: 5, originY: 6, width: 1, height: 1)
    let singleEncoder = BarrierServerInputEncoder(screen: single)
    for edge in [0.0, 1.0] {
      let wire = singleEncoder.pointer(to: NormalizedPoint(x: edge, y: edge))
      #expect(framePayload(wire) == dmmv(x: 5, y: 6))
      #expect(try decode(framePayload(wire), on: single) == moved(x: 0, y: 0))
    }

    // The center is exact only when extent - 1 is even. With 1601 columns and 901 rows,
    // 0.5 is pixel 800 and 450 exactly, and decodes back to exactly 0.5.
    let odd = screen(width: 1601, height: 901)
    let oddWire = BarrierServerInputEncoder(screen: odd).pointer(
      to: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(framePayload(oddWire) == dmmv(x: 800, y: 450))
    #expect(try decode(framePayload(oddWire), on: odd) == moved(x: 0.5, y: 0.5))

    // With 1600 columns and 900 rows, 0.5 * 1599 = 799.5 and 0.5 * 899 = 449.5 round to pixels
    // 800 and 450. Those decode to 800/1599 and 450/899, within 1 / (2 * (extent - 1)) of 0.5
    // but not equal to it, and re-encoding gives the same pixels again.
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    let wire = encoder.pointer(to: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(framePayload(wire) == dmmv(x: 800, y: 450))
    let decoded = try #require(position(try decode(framePayload(wire))))
    #expect(decoded.x == 800.0 / 1599.0)
    #expect(decoded.y == 450.0 / 899.0)
    #expect(decoded.x != 0.5 && decoded.y != 0.5)
    #expect(abs(decoded.x - 0.5) <= 1 / (2 * 1599) + tolerance)
    #expect(abs(decoded.y - 0.5) <= 1 / (2 * 899) + tolerance)
    #expect(encoder.pointer(to: decoded) == wire)
  }

  // MARK: - Rejection: drop and continue

  @Test func rawCoordinatesAbove0x7fffAreDroppedBeforeContainment() throws {
    let raws: [UInt16] = [0x8000, 0x8001, 0xFFFF]
    // On the capture screen these are also outside the rectangle, yet the raw bound is the
    // reason reported, because it is checked first.
    for raw in raws {
      #expect(try decode(dmmv(x: raw, y: 0)) == dropped(.coordinateOutOfRange))
      #expect(try decode(dmmv(x: 0, y: raw)) == dropped(.coordinateOutOfRange))
      #expect(try decode(dmmv(x: raw, y: raw)) == dropped(.coordinateOutOfRange))
    }
    // A rectangle that extends past 0x7FFF contains 0x8000 and 0x8001, which are still dropped
    // on either axis: only 0x0000...0x7FFF is accepted. The last accepted value is 0x7FFF.
    let high = screen(originX: 0x7FF9, originY: 0x7FF9, width: 10, height: 10)
    for raw in raws {
      #expect(try decode(dmmv(x: raw, y: 0x7FF9), on: high) == dropped(.coordinateOutOfRange))
      #expect(try decode(dmmv(x: 0x7FF9, y: raw), on: high) == dropped(.coordinateOutOfRange))
    }
    #expect(try decode(dmmv(x: 0x7FFF, y: 0x7FFF), on: high) == moved(x: 6.0 / 9, y: 6.0 / 9))
    // Signedness is not frozen: read as signed, 0x8000 would be -32768 and would fall inside a
    // rectangle that starts there. It is dropped, and 0x7FFF is outside that rectangle.
    let negative = screen(originX: -32768, originY: -32768, width: 0x7FFF, height: 0x7FFF)
    for raw in raws {
      #expect(try decode(dmmv(x: raw, y: 0), on: negative) == dropped(.coordinateOutOfRange))
      #expect(try decode(dmmv(x: 0, y: raw), on: negative) == dropped(.coordinateOutOfRange))
    }
    #expect(try decode(dmmv(x: 0x7FFF, y: 0), on: negative) == dropped(.coordinateOutsideScreen))
  }

  @Test func coordinatesOutsideTheScreenAreDroppedNotClamped() throws {
    // The rectangle is [origin, origin + size): the first and last cells are inside.
    let rectangle = screen(originX: 100, originY: 200, width: 10, height: 20)
    let inside: [(x: UInt16, y: UInt16, nx: Double, ny: Double)] = [
      (100, 200, 0, 0), (109, 219, 1, 1), (100, 219, 0, 1), (109, 200, 1, 0),
    ]
    for cell in inside {
      let outcome = try decode(dmmv(x: cell.x, y: cell.y), on: rectangle)
      #expect(outcome == moved(x: cell.nx, y: cell.ny), "(\(cell.x), \(cell.y))")
    }
    // One past each edge, a corner, and the far end of the raw range are outside: dropped, and
    // never clamped onto the nearest edge cell.
    let outside: [(x: UInt16, y: UInt16)] = [
      (99, 200), (110, 200), (100, 199), (100, 220), (110, 220), (99, 199), (0, 0),
      (0x7FFF, 0x7FFF),
    ]
    for cell in outside {
      let outcome = try decode(dmmv(x: cell.x, y: cell.y), on: rectangle)
      #expect(outcome == dropped(.coordinateOutsideScreen), "(\(cell.x), \(cell.y))")
    }
    // The capture screen: 1599 and 899 are the last cells, 1600 and 900 are outside.
    #expect(try decode(dmmv(x: 1599, y: 899)) == moved(x: 1, y: 1))
    #expect(try decode(dmmv(x: 1600, y: 899)) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 1599, y: 900)) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 1600, y: 900)) == dropped(.coordinateOutsideScreen))

    // A negative origin with a non-negative pixel: 0 is inside the M1-031 golden screen
    // (origin -1920, 3648 x 1117), at (0 + 1920) / 3647 of its width.
    let golden = BarrierScreenInfo(
      originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)
    #expect(try decode(dmmv(x: 0, y: 0), on: golden) == moved(x: 1920.0 / 3647, y: 0))
    #expect(try decode(dmmv(x: 1727, y: 1116), on: golden) == moved(x: 1, y: 1))
    #expect(try decode(dmmv(x: 1728, y: 0), on: golden) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 0, y: 1117), on: golden) == dropped(.coordinateOutsideScreen))
    let tiny = screen(originX: -1, originY: -1, width: 2, height: 2)
    #expect(try decode(dmmv(x: 0, y: 0), on: tiny) == moved(x: 1, y: 1))
    #expect(try decode(dmmv(x: 1, y: 0), on: tiny) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 0, y: 1), on: tiny) == dropped(.coordinateOutsideScreen))

    // The last raw value, as a one-pixel screen: its neighbors are outside, and 0x8000 is out of
    // range rather than outside.
    let last = screen(originX: 0x7FFF, originY: 0x7FFF, width: 1, height: 1)
    #expect(try decode(dmmv(x: 0x7FFF, y: 0x7FFF), on: last) == moved(x: 0, y: 0))
    #expect(try decode(dmmv(x: 0x7FFE, y: 0x7FFF), on: last) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 0x7FFF, y: 0x7FFE), on: last) == dropped(.coordinateOutsideScreen))
    #expect(try decode(dmmv(x: 0x8000, y: 0x7FFF), on: last) == dropped(.coordinateOutOfRange))
  }

  // MARK: - Rejection: fail closed

  @Test func bodyMustBeExactlyFourBytes() {
    #expect(BarrierMouseMoveDecoder.bodyByteCount == 4)
    for count in [0, 1, 2, 3, 5, 6, 7, 8, 12] {
      // The length is checked before any field: these bodies would otherwise decode or drop.
      let zeros = [UInt8](repeating: 0, count: count)
      let ones = [UInt8](repeating: 0xFF, count: count)
      for body in [zeros, ones] {
        expectFailure(
          .invalidBodyLength(token: .dmmv, bodyByteCount: count), payload: dmmvToken + body)
      }
    }
    // Trailing bytes after a complete x and y are not ignored.
    expectFailure(
      .invalidBodyLength(token: .dmmv, bodyByteCount: 8),
      payload: dmmv(x: 10, y: 450) + [0x00, 0x00, 0x00, 0x00])
    expectFailure(
      .invalidBodyLength(token: .dmmv, bodyByteCount: 5), payload: dmmv(x: 10, y: 450) + [0x00])
    expectFailure(
      .invalidBodyLength(token: .dmmv, bodyByteCount: 3),
      payload: Array(dmmv(x: 10, y: 450).dropLast()))
  }

  @Test func clientToServerDirectionFailsClosedBeforeTheBody() {
    let expected = MoveError.unexpectedDirection(token: .dmmv, direction: .clientToServer)
    let payloads: [[UInt8]] = [
      dmmv(x: 10, y: 450),  // a valid body
      dmmv(x: 0x8000, y: 0),  // would be dropped, not decoded
      dmmv(x: 5000, y: 5000),  // would be dropped as outside the screen
      dmmvToken,  // no body
      dmmvToken + [0, 1, 2, 3, 4],  // a body of the wrong length
    ]
    for payload in payloads {
      expectFailure(expected, payload: payload, direction: .clientToServer)
    }
  }

  @Test func unknownAndShortTokensFailClosedWithOnlyAByteCount() {
    let body: [UInt8] = [0x00, 0x0A, 0x01, 0xC2]
    let unknown: [[UInt8]] = [
      [], [0x44], [0x44, 0x4D], [0x44, 0x4D, 0x4D],  // shorter than the token
      Array("dmmv".utf8) + body,  // tokens are case-sensitive
      Array("DMDN".utf8) + [0x01],
      Array("DMUP".utf8) + [0x01],
      Array("DMWM".utf8) + body,
      Array("CINN".utf8) + body,
      Array("DKDN".utf8) + [0x00, 0x41, 0x00, 0x01, 0x00, 0x26],
      [0x00, 0x00, 0x00, 0x00],
      frame(dmmv(x: 10, y: 450)),  // a whole frame is not a payload: its prefix is the length
    ]
    for payload in unknown {
      // The token is checked before the direction, so the direction does not matter.
      for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
        expectFailure(
          .unknownToken(payloadByteCount: payload.count), payload: payload, direction: direction)
      }
    }
  }

  // MARK: - Output type and privacy

  @Test func outcomeEventsAreAlwaysMouseMove() throws {
    let payloads: [[UInt8]] = [
      dmmv(x: 0, y: 0), dmmv(x: 1599, y: 899), dmmv(x: 800, y: 450),  // events
      dmmv(x: 1600, y: 0), dmmv(x: 0, y: 900), dmmv(x: 0x8000, y: 0),  // dropped
    ]
    var events = 0
    var drops = 0
    for payload in payloads {
      switch try decode(payload) {
      case .event(let event):
        events += 1
        #expect(eventKind(event) == "mouseMove")
      case .dropped:
        drops += 1
      }
    }
    #expect(events == 3 && drops == 3)
    for move in try capturedMoves() {
      guard case .event(let event) = try decode(framePayload(move.frame)) else {
        Issue.record("observation \(move.sequence) did not decode to an event")
        continue
      }
      #expect(eventKind(event) == "mouseMove")
    }
  }

  @Test func dropDiagnosticsAndErrorsCarryOnlyAllowlistedMetadata() throws {
    // The check is not vacuous: each shape it forbids is detected.
    struct Leaky {
      let reason: Reason
      let coordinate: UInt16
    }
    #expect(
      reflectedGraphContainsSensitiveShape(Leaky(reason: .coordinateOutOfRange, coordinate: 5)))
    #expect(reflectedGraphContainsSensitiveShape(captureScreen))
    #expect(reflectedGraphContainsSensitiveShape(dmmv(x: 1, y: 2)))
    #expect(reflectedGraphContainsSensitiveShape(NormalizedPoint(x: 0.5, y: 0.5)))
    #expect(!reflectedGraphContainsSensitiveShape(Reason.coordinateOutsideScreen))

    let errors: [MoveError] = [
      .unknownToken(payloadByteCount: 4),
      .unexpectedDirection(token: .dmmv, direction: .clientToServer),
      .invalidBodyLength(token: .dmmv, bodyByteCount: 5),
    ]
    // Every case is listed: errorKind is exhaustive, so a new case stops this file compiling
    // until it is added here and checked.
    #expect(Set(errors.map(errorKind)).count == 3)
    for error in errors {
      #expect(!reflectedGraphContainsSensitiveShape(error))
    }

    let reasons: [Reason] = [.coordinateOutOfRange, .coordinateOutsideScreen]
    #expect(Set(reasons.map(reasonKind)).count == 2)
    for reason in reasons {
      let diagnostic = BarrierMouseMoveDropDiagnostic(
        token: .dmmv, direction: .serverToClient, bodyByteCount: 4, reason: reason)
      #expect(!reflectedGraphContainsSensitiveShape(diagnostic))
    }

    // The diagnostics a real decode builds from distinctive raw values hold none of them.
    for payload in [dmmv(x: 0xBEEF, y: 0xCAFE), dmmv(x: 1600, y: 900), dmmv(x: 4321, y: 8765)] {
      guard case .dropped(let diagnostic) = try decode(payload) else {
        Issue.record("expected a drop for \(payload.count) payload bytes")
        continue
      }
      #expect(!reflectedGraphContainsSensitiveShape(diagnostic))
      #expect(diagnostic.token == .dmmv)
      #expect(diagnostic.direction == .serverToClient)
      #expect(diagnostic.bodyByteCount == 4)
    }
  }

  // MARK: - Fragmentation, coalescing and truncation through BarrierFrameReassembler

  @Test func fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated() throws {
    let frames = try capturedFrames(direction: "server-to-client").map(\.frame)
    #expect(frames.allSatisfy { $0.count - 4 <= limit })
    let bytes = frames.flatMap { $0 }
    let expected = observedPixels.map { moved(x: Double($0.x) / 1599, y: Double($0.y) / 899) }

    // Where each frame ends, and which frames are moves.
    var frameEnds: [Int] = []
    var moveEnds: [Int] = []
    var end = 0
    for frameBytes in frames {
      end += frameBytes.count
      frameEnds.append(end)
      if framePayload(frameBytes).starts(with: dmmvToken) { moveEnds.append(end) }
    }
    #expect(moveEnds.count == observedPixels.count)

    let decoder = BarrierMouseMoveDecoder(screen: captureScreen)
    var fragmentations: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
    for cut in 1..<bytes.count {
      fragmentations.append([Array(bytes[..<cut]), Array(bytes[cut...])])
    }
    for chunks in fragmentations {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let outcomes = try decodeMoves(chunks, decoder: decoder, reassembler: &reassembler)
      #expect(outcomes == expected)
      try reassembler.finish()
    }

    // A stream cut at any byte hands the decoder only complete frames.
    for cut in 0..<bytes.count {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      let outcomes = try decodeMoves(
        [Array(bytes[..<cut])], decoder: decoder, reassembler: &reassembler)
      let completeMoves = moveEnds.filter { $0 <= cut }.count
      #expect(outcomes == Array(expected.prefix(completeMoves)), "cut at \(cut)")
      if frameEnds.contains(cut) || cut == 0 {
        try reassembler.finish()
      } else {
        #expect(throws: BarrierFrameReassemblerError.self, "cut at \(cut)") {
          try reassembler.finish()
        }
      }
    }
  }

  // MARK: - Purity

  @Test func decoderIsPureAndScreensAreIndependent() throws {
    // The decoder owns no I/O, timer, task, lock or other resource, so there is nothing to
    // cancel or clean up. What applies is determinism and the absence of latched state.
    let decoder = BarrierMouseMoveDecoder(screen: captureScreen)
    let payload = dmmv(x: 100, y: 500)
    let first = try decoder.decode(payload: payload, direction: .serverToClient)
    #expect(first == moved(x: 100.0 / 1599, y: 500.0 / 899))
    #expect(try decoder.decode(payload: payload, direction: .serverToClient) == first)

    // A failure or a drop does not latch: later payloads decode exactly as on a fresh decoder.
    let others: [[UInt8]] = [
      [], dmmvToken + [0x01], dmmv(x: 0x9000, y: 1), dmmv(x: 5000, y: 5000),
      dmmv(x: 1, y: 1),
    ]
    for other in others {
      _ = try? decoder.decode(payload: other, direction: .serverToClient)
      #expect(try decoder.decode(payload: payload, direction: .serverToClient) == first)
    }
    _ = try? decoder.decode(payload: payload, direction: .clientToServer)
    #expect(try decoder.decode(payload: payload, direction: .serverToClient) == first)

    // Another screen changes the result only through the formula, and decoders do not share
    // state: the same raw point is inside one screen and outside the other.
    let narrow = screen(originX: 50, originY: 100, width: 800, height: 600)
    #expect(try decode(payload, on: narrow) == moved(x: 50.0 / 799, y: 400.0 / 599))
    let beyond = dmmv(x: 1000, y: 500)
    #expect(try decode(beyond, on: narrow) == dropped(.coordinateOutsideScreen))
    #expect(try decode(beyond) == moved(x: 1000.0 / 1599, y: 500.0 / 899))
    #expect(try decoder.decode(payload: payload, direction: .serverToClient) == first)

    // Only the rectangle is an input: the DINF cursor is not read.
    let elsewhere = BarrierScreenInfo(
      originX: 0, originY: 0, width: 1600, height: 900, cursorX: 1, cursorY: 2)
    #expect(try decode(payload, on: elsewhere) == first)
  }

  @Test func normalizedIsThePixelOffsetOverExtentMinusOneAndZeroForASinglePixel() {
    typealias Decoder = BarrierMouseMoveDecoder
    #expect(Decoder.normalized(pixel: 0, origin: 0, extent: 1600) == 0)
    #expect(Decoder.normalized(pixel: 1599, origin: 0, extent: 1600) == 1)
    #expect(Decoder.normalized(pixel: 800, origin: 0, extent: 1600) == 800.0 / 1599.0)
    #expect(Decoder.normalized(pixel: 450, origin: 0, extent: 901) == 0.5)
    #expect(Decoder.normalized(pixel: 0, origin: -3, extent: 7) == 0.5)
    #expect(Decoder.normalized(pixel: 0, origin: -1920, extent: 3648) == 1920.0 / 3647.0)
    #expect(Decoder.normalized(pixel: 0x7FFF, origin: 0x7FF9, extent: 7) == 1)
    #expect(Decoder.normalized(pixel: 11, origin: 10, extent: 2) == 1)
    // A one-pixel axis has one position, and no division by zero is attempted.
    #expect(Decoder.normalized(pixel: 0, origin: 0, extent: 1) == 0)
    #expect(Decoder.normalized(pixel: 0x7FFF, origin: 0x7FFF, extent: 1) == 0)
  }

  // MARK: - Architecture boundary

  @Test func productionSourceImportsOnlyKVMContracts() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseMoveDecoder.swift"),
      encoding: .utf8)
    // Comments may describe the boundary; code lines may not cross it.
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import KVMContracts"])
    for forbidden in [
      "Foundation", "KVMCore", "NativeProtocol", "print(", "debugPrint(", "dump(", "NSLog",
      "Logger", "os_log",
    ] {
      #expect(!code.contains { $0.contains(forbidden) }, "production code mentions \(forbidden)")
    }
  }
}

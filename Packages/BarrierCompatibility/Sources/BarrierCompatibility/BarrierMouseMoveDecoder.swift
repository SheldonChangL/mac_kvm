// Pointer-move (`DMMV`) decoder for the Barrier protocol adapter. The token, the body layout and
// the rejection rules come only from
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md
// (BARRIER-EVID-0006-CLAIM-001): a 4-byte ASCII token, then a 4-byte body of two big-endian
// 16-bit fields, x then y, holding an absolute pointer position in client pixels. Signedness is
// not frozen, so a raw value is accepted only in 0x0000...0x7FFF, and a value outside that range
// or outside the client's own DINF rectangle is dropped, never clamped. The decoder consumes one
// complete payload produced by BarrierFrameReassembler (M1-022); stream fragmentation is handled
// there.
//
// The conversion from client pixels to a NormalizedPoint is a first-party convention, not a
// Barrier claim. It is the exact inverse of BarrierServerInputEncoder's pixel mapping, so a
// pointer position survives the round trip Mac server to Linux client.

import KVMContracts

/// The token M1-032 recognizes. The name is the frozen ASCII token.
enum BarrierMouseMoveToken: CaseIterable, Hashable, Sendable {
  case dmmv

  static let byteCount = 4

  var bytes: [UInt8] {
    switch self {
    case .dmmv: Array("DMMV".utf8)
    }
  }

  init?(payloadPrefix payload: [UInt8]) {
    guard
      let token = Self.allCases.first(where: {
        payload.prefix(Self.byteCount).elementsEqual($0.bytes)
      })
    else { return nil }
    self = token
  }
}

/// Typed fail-closed failure. The session ends with a protocol-violation error and its cleanup
/// runs. Carries only allowlisted metadata (token, direction, counts); never payload bytes, body
/// bytes or coordinates.
enum BarrierMouseMoveDecoderError: Error, Equatable, Sendable {
  /// The payload is shorter than a token or starts with a token this decoder does not recognize.
  case unknownToken(payloadByteCount: Int)
  /// `DMMV` is server-to-client only.
  case unexpectedDirection(token: BarrierMouseMoveToken, direction: BarrierControlDirection)
  /// The body is not exactly 4 bytes (truncated or trailing bytes).
  case invalidBodyLength(token: BarrierMouseMoveToken, bodyByteCount: Int)
}

/// Allowlisted metadata for a dropped `DMMV`: the token, direction, body length and reason the
/// contract names. Never holds a coordinate or any body byte.
struct BarrierMouseMoveDropDiagnostic: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    /// A raw coordinate is above 0x7FFF, where signed and unsigned readings disagree.
    case coordinateOutOfRange
    /// Both raw coordinates are in range, but the point is outside `[origin, origin + size)`
    /// of the client screen on at least one axis.
    case coordinateOutsideScreen
  }

  let token: BarrierMouseMoveToken
  let direction: BarrierControlDirection
  let bodyByteCount: Int
  let reason: Reason
}

/// Outcome of decoding one `DMMV` payload.
enum BarrierMouseMoveOutcome: Equatable, Sendable {
  /// Always `KVMEvent.mouseMove`.
  case event(KVMEvent)
  /// Dropped by contract; the session continues and counts the drop by reason.
  case dropped(BarrierMouseMoveDropDiagnostic)
}

/// Decodes `DMMV` payloads against one client screen. A pure value: no I/O, no state, no
/// logging, so there is nothing to cancel, latch or clean up.
///
/// The caller passes every complete server-to-client `DMMV` payload with its direction, and
/// builds a new decoder when a DINF replaces the client screen. Checks, in order: token,
/// direction, body length, the raw coordinate bound, then the client rectangle.
struct BarrierMouseMoveDecoder: Sendable {
  static let bodyByteCount = 4
  private static let maximumRawCoordinate: UInt16 = 0x7FFF

  /// The client's own DINF rectangle. Its cursor is not read.
  let screen: BarrierScreenInfo

  func decode(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierMouseMoveDecoderError) -> BarrierMouseMoveOutcome {
    guard let token = BarrierMouseMoveToken(payloadPrefix: payload) else {
      throw .unknownToken(payloadByteCount: payload.count)
    }
    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierMouseMoveToken.byteCount)
    guard body.count == Self.bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
    let x = Self.uint16(body, at: 0)
    let y = Self.uint16(body, at: 2)
    guard x <= Self.maximumRawCoordinate, y <= Self.maximumRawCoordinate else {
      return Self.drop(.coordinateOutOfRange, token: token, direction: direction, body: body)
    }
    guard screen.contains(x: x, y: y) else {
      return Self.drop(.coordinateOutsideScreen, token: token, direction: direction, body: body)
    }
    return .event(
      .mouseMove(
        position: NormalizedPoint(
          x: Self.normalized(pixel: x, origin: screen.originX, extent: screen.width),
          y: Self.normalized(pixel: y, origin: screen.originY, extent: screen.height))))
  }

  /// First-party convention: the inverse of `BarrierServerInputEncoder`'s pixel mapping,
  /// `(pixel - origin) / (extent - 1)`. The first pixel is 0 and the last is 1, so the edges
  /// round-trip exactly. A one-pixel axis has a single position and gives 0, not 0 / 0.
  static func normalized(pixel: UInt16, origin: Int16, extent: UInt16) -> Double {
    guard extent > 1 else { return 0 }
    return Double(Int(pixel) - Int(origin)) / Double(Int(extent) - 1)
  }

  private static func drop(
    _ reason: BarrierMouseMoveDropDiagnostic.Reason, token: BarrierMouseMoveToken,
    direction: BarrierControlDirection, body: ArraySlice<UInt8>
  ) -> BarrierMouseMoveOutcome {
    .dropped(
      BarrierMouseMoveDropDiagnostic(
        token: token, direction: direction, bodyByteCount: body.count, reason: reason))
  }

  /// Big-endian 16-bit read; the caller has already checked the exact body length.
  private static func uint16(_ body: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
    let index = body.startIndex + offset
    return UInt16(body[index]) << 8 | UInt16(body[index + 1])
  }
}

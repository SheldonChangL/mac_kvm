// Mouse-wheel (`DMWM`) decoder for the Barrier protocol adapter. The layout and the notch
// table come only from docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md
// (BARRIER-EVID-0006-CLAIM-003): a 4-byte ASCII token, then two signed 16-bit big-endian
// deltas, x then y, with one captured notch per direction at 120 wire units. The conversion
// to `KVMEvent.scroll` below is that ADR's first-party convention, not a capture claim.
// The decoder consumes one complete payload produced by BarrierFrameReassembler (M1-022);
// stream fragmentation is handled there. Output is a `KVMEvent` and nothing else.

import KVMContracts

/// The token M1-034 recognizes. The name is the frozen ASCII token.
enum BarrierMouseWheelToken: CaseIterable, Hashable, Sendable {
  case dmwm

  static let byteCount = 4

  var bytes: [UInt8] {
    switch self {
    case .dmwm: Array("DMWM".utf8)
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

/// Typed wheel failure; the session ends with a protocol violation. Carries only allowlisted
/// metadata (token, direction, counts); never body bytes or wheel values.
enum BarrierMouseWheelDecoderError: Error, Equatable, Sendable {
  /// The payload is shorter than a token or does not start with `DMWM`.
  case unknownToken(payloadByteCount: Int)
  /// `DMWM` is a server-to-client token; the payload came from another direction.
  case unexpectedDirection(token: BarrierMouseWheelToken, direction: BarrierControlDirection)
  /// The body is not exactly four bytes (truncated or trailing bytes).
  case invalidBodyLength(token: BarrierMouseWheelToken, bodyByteCount: Int)
}

/// Allowlisted metadata for a dropped frame: the token, the direction, the body length and
/// the reason, as M1-PROTOCOL-003 "Rejection semantics" names them. Never holds body bytes or
/// wheel values.
struct BarrierMouseWheelDropDiagnostic: Equatable, Sendable {
  enum Reason: Equatable, Sendable {
    /// Both axes divide to zero (|wire| < 120 on both, including (0, 0)). First-party policy:
    /// a zero scroll is never emitted.
    case noWholeNotch
  }

  let token: BarrierMouseWheelToken
  let direction: BarrierControlDirection
  /// The body length, not the payload length.
  let bodyByteCount: Int
  let reason: Reason
}

/// Outcome of decoding one `DMWM` payload.
enum BarrierMouseWheelOutcome: Equatable, Sendable {
  /// Always `KVMEvent.scroll(deltaX:deltaY:)`, with at least one non-zero delta.
  case event(KVMEvent)
  case dropped(BarrierMouseWheelDropDiagnostic)
}

/// Stateless `DMWM` decoder: the inverse of `BarrierServerInputEncoder.scroll`.
///
/// First-party convention (M1-PROTOCOL-003, "Wheel: DMWM"): in `KVMEvent.scroll` a positive
/// `deltaY` scrolls up and a positive `deltaX` scrolls left, so the horizontal axis is
/// inverted on the wire:
///
/// - `deltaX = -wireX / 120` and `deltaY = wireY / 120`, by integer division toward zero;
/// - the remainder is dropped, so one frame can carry several notches;
/// - a left notch, `(-120, 0)`, decodes to `deltaX = +1`; an up notch, `(0, +120)`, to
///   `deltaY = +1`.
///
/// Checks, in order: token, direction, body length. A frame whose axes both divide to zero is
/// dropped with a diagnostic. There is no I/O, timer, task or state, so there is nothing to
/// cancel, and no failure is latched; the session ends on a thrown error.
enum BarrierMouseWheelDecoder {
  static let bodyByteCount = 4
  /// Wire units per notch (BARRIER-EVID-0006-CLAIM-003).
  static let unitsPerNotch: Int32 = 120

  /// Whole notches per axis, toward zero. The wire values are widened to `Int32` before the
  /// horizontal negation, because `Int16.min` has no negation in `Int16`.
  static func deltas(wireX: Int16, wireY: Int16) -> (deltaX: Int32, deltaY: Int32) {
    (deltaX: -Int32(wireX) / unitsPerNotch, deltaY: Int32(wireY) / unitsPerNotch)
  }

  /// Decodes one complete payload (token and body), as returned by the frame reassembler.
  static func decode(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierMouseWheelDecoderError) -> BarrierMouseWheelOutcome {
    guard let token = BarrierMouseWheelToken(payloadPrefix: payload) else {
      throw .unknownToken(payloadByteCount: payload.count)
    }
    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierMouseWheelToken.byteCount)
    guard body.count == bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
    let wireX = Int16(bitPattern: uint16(body, at: 0))
    let wireY = Int16(bitPattern: uint16(body, at: 2))
    let (deltaX, deltaY) = deltas(wireX: wireX, wireY: wireY)
    guard deltaX != 0 || deltaY != 0 else {
      return .dropped(
        BarrierMouseWheelDropDiagnostic(
          token: token, direction: direction, bodyByteCount: body.count, reason: .noWholeNotch))
    }
    return .event(.scroll(deltaX: deltaX, deltaY: deltaY))
  }

  /// Big-endian 16-bit read; the caller has already checked the exact body length.
  private static func uint16(_ body: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
    let index = body.startIndex + offset
    return UInt16(body[index]) << 8 | UInt16(body[index + 1])
  }
}

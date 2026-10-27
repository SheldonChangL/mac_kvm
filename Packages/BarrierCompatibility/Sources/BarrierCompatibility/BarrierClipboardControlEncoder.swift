// Server-role control and clipboard encoder for the Barrier protocol adapter (M2-028).
// Emits only the frames listed in the proposed docs/adr/M2-023: CINN with the observed
// sequence 1 and opaque mask 0x2000 once per session, token-only COUT and CALV, all
// from the accepted BARRIER-EVID-0005 contract. Clipboard has no frozen wire encoding
// and always fails closed without emitting bytes.

import KVMContracts

/// Typed encoder failure. Carries no coordinates, text or payload bytes.
enum BarrierClipboardControlEncoderError: Error, Equatable, Sendable {
  /// A raw coordinate is outside `0...0x7fff`, where signedness is unambiguous.
  case coordinateOutOfRange
  /// A coordinate is outside the client's `DINF` rectangle.
  case coordinateOutsideScreen
  /// Only the single observed `CINN` (sequence 1) is frozen for one session.
  case repeatedEnterUnsupported
  /// The clipboard payload exceeds the caller's byte limit.
  case clipboardOversized
  /// No clipboard wire encoding is frozen (M2-023); nothing is emitted.
  case clipboardWireContractNotFrozen
}

/// Encodes server-to-client control frames for one client session.
struct BarrierClipboardControlEncoder: Sendable {
  private static let maximumRawCoordinate: UInt16 = 0x7FFF
  private static let observedSequence: UInt32 = 1
  private static let observedModifierMask: UInt16 = 0x2000

  let screen: BarrierScreenInfo
  private var enterSent = false

  init(screen: BarrierScreenInfo) {
    self.screen = screen
  }

  /// Encodes `CINN` at a normalized position inside the client rectangle.
  mutating func enter(position: NormalizedPoint) throws(BarrierClipboardControlEncoderError)
    -> [UInt8]
  {
    let x = Int(screen.originX) + Int((position.x * Double(Int(screen.width) - 1)).rounded())
    let y = Int(screen.originY) + Int((position.y * Double(Int(screen.height) - 1)).rounded())
    let range = 0...Int(Self.maximumRawCoordinate)
    guard range.contains(x), range.contains(y) else { throw .coordinateOutOfRange }
    return try enter(x: UInt16(x), y: UInt16(y))
  }

  /// Encodes `CINN` at a raw client coordinate. A failed call does not consume
  /// the single supported enter.
  mutating func enter(x: UInt16, y: UInt16) throws(BarrierClipboardControlEncoderError) -> [UInt8] {
    guard !enterSent else { throw .repeatedEnterUnsupported }
    guard x <= Self.maximumRawCoordinate, y <= Self.maximumRawCoordinate else {
      throw .coordinateOutOfRange
    }
    guard screen.contains(x: x, y: y) else { throw .coordinateOutsideScreen }
    enterSent = true
    let body =
      Self.bigEndian(x) + Self.bigEndian(y)
      + Self.bigEndian(UInt16(Self.observedSequence >> 16))
      + Self.bigEndian(UInt16(Self.observedSequence & 0xFFFF))
      + Self.bigEndian(Self.observedModifierMask)
    return Self.frame(BarrierControlToken.cinn.bytes + body)
  }

  /// Encodes token-only `COUT`.
  func leave() -> [UInt8] {
    Self.frame(BarrierControlToken.cout.bytes)
  }

  /// Encodes token-only `CALV`.
  func keepalive() -> [UInt8] {
    Self.frame(BarrierControlToken.calv.bytes)
  }

  /// Always fails: size is checked first, then the unfrozen wire contract.
  func clipboard(_ payload: ClipboardPayload, limit: ClipboardByteLimit)
    throws(BarrierClipboardControlEncoderError)
  {
    guard payload.utf8Text.utf8.count <= limit.byteCount else { throw .clipboardOversized }
    throw .clipboardWireContractNotFrozen
  }

  private static func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
  }

  private static func frame(_ payload: [UInt8]) -> [UInt8] {
    let count = UInt32(payload.count)
    return [
      UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF),
      UInt8(count & 0xFF),
    ]
      + payload
  }
}

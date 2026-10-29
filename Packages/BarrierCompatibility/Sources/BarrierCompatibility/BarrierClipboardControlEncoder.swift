// Server-role control and clipboard encoder for the Barrier protocol adapter (M2-028).
// Token-only COUT and CALV come from the accepted BARRIER-EVID-0005 contract. CINN
// follows the M2-022 server-role capture (evidence/e2e/M2-022/README.md): a client
// can be entered any number of times; the observed sequences were 1, then 3 for the
// enter after one leave, which the encoder reproduces by advancing on every enter and
// every leave (the rule itself is not established); and the mask is 0 because lock
// state is not synchronized. Clipboard text is sent as the M2-022 punctuation and clipboard
// addendum captured it: clipboard 0, sequence 0 (evidence/e2e/M2-022/punctuation-clipboard.md).

import KVMContracts

/// Typed encoder failure. Carries no coordinates, text or payload bytes.
enum BarrierClipboardControlEncoderError: Error, Equatable, Sendable {
  /// A raw coordinate is outside `0...0x7fff`, where signedness is unambiguous.
  case coordinateOutOfRange
  /// A coordinate is outside the client's `DINF` rectangle.
  case coordinateOutsideScreen
  /// The clipboard payload exceeds the caller's byte limit.
  case clipboardOversized
}

/// Encodes server-to-client control frames for one client session.
struct BarrierClipboardControlEncoder: Sendable {
  private static let maximumRawCoordinate: UInt16 = 0x7FFF
  private static let enterModifierMask: UInt16 = 0

  /// The client screen; replaced when the client reports new screen info.
  var screen: BarrierScreenInfo
  /// Advanced on every enter and every leave; the next `CINN` carries it.
  private var sequence: UInt32 = 0

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

  /// Encodes `CINN` at a raw client coordinate. A failed call does not advance
  /// the sequence.
  mutating func enter(x: UInt16, y: UInt16) throws(BarrierClipboardControlEncoderError) -> [UInt8] {
    guard x <= Self.maximumRawCoordinate, y <= Self.maximumRawCoordinate else {
      throw .coordinateOutOfRange
    }
    guard screen.contains(x: x, y: y) else { throw .coordinateOutsideScreen }
    sequence &+= 1
    let body =
      Self.bigEndian(x) + Self.bigEndian(y)
      + Self.bigEndian(UInt16(sequence >> 16))
      + Self.bigEndian(UInt16(sequence & 0xFFFF))
      + Self.bigEndian(Self.enterModifierMask)
    return Self.frame(BarrierControlToken.cinn.bytes + body)
  }

  /// Encodes token-only `COUT` and advances the sequence.
  mutating func leave() -> [UInt8] {
    sequence &+= 1
    return Self.frame(BarrierControlToken.cout.bytes)
  }

  /// Encodes token-only `CALV`.
  func keepalive() -> [UInt8] {
    Self.frame(BarrierControlToken.calv.bytes)
  }

  /// Encodes the `DCLP` transfer of `payload` as the client's clipboard 0.
  /// Oversized text fails before any byte is produced.
  func clipboard(_ payload: ClipboardPayload, limit: ClipboardByteLimit)
    throws(BarrierClipboardControlEncoderError) -> [UInt8]
  {
    guard payload.utf8ByteCount <= limit.byteCount else { throw .clipboardOversized }
    let data = BarrierClipboard.marshal(text: payload.utf8Text)
    return BarrierClipboard.frames(id: 0, sequence: 0, data: data).flatMap { $0 }
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

// Client-role control encoder for the Barrier protocol adapter (M1-029-FOLLOWUP-001). DINF and
// CALV follow docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md
// (BARRIER-EVID-0005): DINF is the exact inverse of BarrierControlDecoder's screen-info parse,
// CALV is token-only. CCLP and the client clipboard transfer follow
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md (BARRIER-EVID-0007,
// BARRIER-EVID-0008): CCLP carries the clipboard id and the sequence of the CINN in force, and
// the client's DCLP frames carry that same sequence. Every multi-byte field is big-endian.

/// Encodes the frames a Barrier client writes after HelloBack. A namespace of pure functions:
/// no state, no I/O, no logging.
enum BarrierClientControlEncoder {
  /// The `CCLP` token (BARRIER-EVID-0007-CLAIM-001).
  static let clipboardOwnershipToken: [UInt8] = Array("CCLP".utf8)
  /// The clipboard the first-party peers share (M1-PROTOCOL-003 first-party convention).
  static let sharedClipboardID: UInt8 = 0
  /// The DINF reserved field; its meaning is unknown and writers emit 0 (M1-PROTOCOL-002).
  private static let reservedField: UInt16 = 0

  /// `DINF`: origin x and y (signed), width, height, the reserved field, cursor x and y, each
  /// 16 bits.
  static func screenInfo(_ screen: BarrierScreenInfo) -> [UInt8] {
    var payload = BarrierControlToken.dinf.bytes
    payload += bigEndian(UInt16(bitPattern: screen.originX))
    payload += bigEndian(UInt16(bitPattern: screen.originY))
    payload += bigEndian(screen.width)
    payload += bigEndian(screen.height)
    payload += bigEndian(reservedField)
    payload += bigEndian(screen.cursorX)
    payload += bigEndian(screen.cursorY)
    return frame(payload)
  }

  /// `CALV`: no body.
  static func keepalive() -> [UInt8] {
    frame(BarrierControlToken.calv.bytes)
  }

  /// `CCLP`: a 5-byte body, the clipboard id and the 4-byte sequence.
  static func clipboardOwnership(id: UInt8, sequence: UInt32) -> [UInt8] {
    var payload = clipboardOwnershipToken
    payload.append(id)
    payload += bigEndian(sequence)
    return frame(payload)
  }

  /// `CCLP` for the shared clipboard, then the `DCLP` transfer of `data` (a marshalled
  /// clipboard) with the same sequence, in chunks of at most 32 KiB (M2-028).
  static func clipboard(marshalled data: [UInt8], sequence: UInt32) -> [UInt8] {
    var bytes = clipboardOwnership(id: sharedClipboardID, sequence: sequence)
    for transferFrame in BarrierClipboard.frames(
      id: sharedClipboardID, sequence: sequence, data: data)
    {
      bytes += transferFrame
    }
    return bytes
  }

  private static func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
  }

  private static func bigEndian(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
  }

  private static func frame(_ payload: [UInt8]) -> [UInt8] {
    bigEndian(UInt32(payload.count)) + payload
  }
}

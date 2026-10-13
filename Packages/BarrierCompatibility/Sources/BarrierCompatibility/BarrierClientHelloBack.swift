// Client HelloBack writer for the Barrier protocol adapter.
// docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md (BARRIER-EVID-0004) freezes the
// frame: a 4-byte unsigned big-endian payload length, the ASCII marker bytes
// `42 61 72 72 69 65 72`, the opaque version bytes `00 01 00 06`, a 4-byte unsigned
// big-endian screen-name UTF-8 byte count, then exactly that many screen-name bytes.
// Screen names follow the conservative M1 support policy from that ADR: non-empty ASCII
// identifiers (letters, digits, `-`, `_`) within a caller-configured byte bound. The bound
// is a MacKVM fail-closed policy, not an observed Barrier maximum. All integers are
// written through BarrierBinaryWriter (M1-021), which emits explicit big-endian bytes.
// Handshake sequencing belongs to the M1-029 state machine.

/// Typed HelloBack failure. Carries only counts and limits, never screen-name bytes.
enum BarrierClientHelloBackError: Error, Equatable, Sendable {
  /// The configured bound is not positive, or the largest frame would not fit the 4-byte
  /// unsigned length prefix.
  case invalidMaximumScreenNameByteCount
  /// The screen name has no bytes.
  case emptyScreenName
  /// The screen name's UTF-8 byte count exceeds the configured bound.
  case screenNameTooLong(byteCount: Int, limit: Int)
  /// The screen name contains a byte outside the M1 ASCII identifier set.
  case unsupportedScreenNameCharacter
  /// The binary writer rejected a validated size. Defensive only: the bound checks keep
  /// every count within the writer limits and the 4-byte prefix.
  case frameEncodingFailed
}

/// Writes complete length-prefixed HelloBack frames. Holds only its configured bound, so
/// writing is a pure function of the screen name.
struct BarrierClientHelloBackWriter: Sendable {
  static let markerBytes: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
  /// Opaque: M1-PROTOCOL-001 does not freeze whether these bytes form one or more integers.
  static let versionBytes: [UInt8] = [0x00, 0x01, 0x00, 0x06]
  /// Payload bytes before the screen name: marker, version and screen-name length.
  private static let fixedPayloadByteCount = markerBytes.count + versionBytes.count + 4
  /// Largest bound whose payload still fits the 4-byte unsigned length prefix.
  static let largestSupportedMaximumScreenNameByteCount =
    Int(UInt32.max) - fixedPayloadByteCount

  let maximumScreenNameByteCount: Int

  init(maximumScreenNameByteCount: Int) throws(BarrierClientHelloBackError) {
    guard
      maximumScreenNameByteCount > 0,
      maximumScreenNameByteCount <= Self.largestSupportedMaximumScreenNameByteCount
    else { throw .invalidMaximumScreenNameByteCount }
    self.maximumScreenNameByteCount = maximumScreenNameByteCount
  }

  /// Validates the screen name, then returns the full frame. Validation runs in order:
  /// empty, byte count against the bound, then each byte against the identifier set.
  func frame(screenName: String) throws(BarrierClientHelloBackError) -> [UInt8] {
    let nameByteCount = screenName.utf8.count
    guard nameByteCount > 0 else { throw .emptyScreenName }
    guard nameByteCount <= maximumScreenNameByteCount else {
      throw .screenNameTooLong(byteCount: nameByteCount, limit: maximumScreenNameByteCount)
    }
    guard screenName.utf8.allSatisfy(Self.isIdentifierByte) else {
      throw .unsupportedScreenNameCharacter
    }

    let payloadByteCount = Self.fixedPayloadByteCount + nameByteCount
    do throws(BarrierBinaryCodecError) {
      var payload = try BarrierBinaryWriter(maximumByteCount: payloadByteCount)
      try payload.writeBytes(Self.markerBytes)
      try payload.writeBytes(Self.versionBytes)
      try payload.writeUInt32(BarrierBinaryWriter.lengthPrefix(for: nameByteCount))
      try payload.writeBytes(Array(screenName.utf8))
      var frame = try BarrierBinaryWriter(maximumByteCount: 4 + payloadByteCount)
      try frame.writeLengthPrefixedPayload(
        payload.bytes, maximumPayloadLength: payloadByteCount)
      return frame.bytes
    } catch {
      throw .frameEncodingFailed
    }
  }

  private static func isIdentifierByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
      true
    default:
      false
    }
  }
}

// Bounded big-endian binary reader/writer for the Barrier protocol adapter.
// Frame envelope per docs/adr/M1-025-barrier-client-wire-contract.md: a 4-byte
// unsigned big-endian length prefix followed by exactly that many payload bytes.
// Payload and buffer limits are caller-supplied product safety bounds, not observed
// Barrier compatibility limits. Message codes and payload layouts are out of scope.

/// Typed codec failure. Carries only counts and limits, never input bytes.
enum BarrierBinaryCodecError: Error, Equatable, Sendable {
  /// Fewer bytes remain than the read requires.
  case truncated(requested: Int, remaining: Int)
  /// A payload or buffer would exceed the caller-supplied limit. Both limits share this
  /// case; callers that need to distinguish them should pass different values.
  case oversize(limit: Int)
  /// A count (including a negative one) does not fit the 4-byte unsigned length prefix.
  case integerOverflow
  /// A read count, payload limit or buffer capacity is negative.
  case invalidCount
}

/// Reads from a complete in-memory byte buffer. A failed read never advances the cursor.
struct BarrierBinaryReader: Sendable {
  private let bytes: [UInt8]
  private var offset = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  var remainingCount: Int { bytes.count - offset }

  mutating func readUInt8() throws(BarrierBinaryCodecError) -> UInt8 {
    try readBytes(count: 1)[0]
  }

  mutating func readUInt16() throws(BarrierBinaryCodecError) -> UInt16 {
    let value = try peekBigEndian(count: 2)
    offset += 2
    return UInt16(value)
  }

  mutating func readUInt32() throws(BarrierBinaryCodecError) -> UInt32 {
    let value = try peekBigEndian(count: 4)
    offset += 4
    return value
  }

  mutating func readBytes(count: Int) throws(BarrierBinaryCodecError) -> [UInt8] {
    guard count >= 0 else { throw .invalidCount }
    try requireRemaining(count, from: offset)
    let start = offset
    offset += count
    return Array(bytes[start..<offset])
  }

  /// Reads one M1-025 frame envelope and returns its payload.
  mutating func readLengthPrefixedPayload(
    maximumPayloadLength: Int
  ) throws(BarrierBinaryCodecError) -> [UInt8] {
    guard maximumPayloadLength >= 0 else { throw .invalidCount }
    let prefix = try peekBigEndian(count: 4)
    // Only reachable where Int is 32 bits; macOS targets are 64-bit.
    guard let length = Int(exactly: prefix) else { throw .integerOverflow }
    guard length <= maximumPayloadLength else { throw .oversize(limit: maximumPayloadLength) }
    let payloadStart = offset + 4
    guard length <= bytes.count - payloadStart else {
      throw .truncated(requested: 4 + length, remaining: remainingCount)
    }
    offset = payloadStart + length
    return Array(bytes[payloadStart..<offset])
  }

  private func requireRemaining(_ count: Int, from start: Int) throws(BarrierBinaryCodecError) {
    // Compare against the remainder so a huge count cannot overflow `start + count`.
    guard count <= bytes.count - start else {
      throw .truncated(requested: count, remaining: bytes.count - start)
    }
  }

  private func peekBigEndian(count: Int) throws(BarrierBinaryCodecError) -> UInt32 {
    try requireRemaining(count, from: offset)
    var value: UInt32 = 0
    for byte in bytes[offset..<(offset + count)] {
      value = value << 8 | UInt32(byte)
    }
    return value
  }
}

/// Appends to a buffer capped at `maximumByteCount`. A failed write leaves `bytes` unchanged.
struct BarrierBinaryWriter: Sendable {
  private(set) var bytes: [UInt8] = []
  let maximumByteCount: Int

  init(maximumByteCount: Int) throws(BarrierBinaryCodecError) {
    guard maximumByteCount >= 0 else { throw .invalidCount }
    self.maximumByteCount = maximumByteCount
  }

  static func lengthPrefix(for count: Int) throws(BarrierBinaryCodecError) -> UInt32 {
    guard let prefix = UInt32(exactly: count) else { throw .integerOverflow }
    return prefix
  }

  mutating func writeUInt8(_ value: UInt8) throws(BarrierBinaryCodecError) {
    try writeBytes([value])
  }

  mutating func writeUInt16(_ value: UInt16) throws(BarrierBinaryCodecError) {
    try writeBytes([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
  }

  mutating func writeUInt32(_ value: UInt32) throws(BarrierBinaryCodecError) {
    try writeBytes(Self.bigEndianBytes(value))
  }

  mutating func writeBytes(_ newBytes: [UInt8]) throws(BarrierBinaryCodecError) {
    try requireCapacity(newBytes.count)
    bytes.append(contentsOf: newBytes)
  }

  /// Writes one M1-025 frame envelope: 4-byte big-endian length, then the payload.
  mutating func writeLengthPrefixedPayload(
    _ payload: [UInt8],
    maximumPayloadLength: Int
  ) throws(BarrierBinaryCodecError) {
    guard maximumPayloadLength >= 0 else { throw .invalidCount }
    guard payload.count <= maximumPayloadLength else {
      throw .oversize(limit: maximumPayloadLength)
    }
    let prefix = try Self.lengthPrefix(for: payload.count)
    try requireCapacity(4 + payload.count)
    bytes.append(contentsOf: Self.bigEndianBytes(prefix))
    bytes.append(contentsOf: payload)
  }

  private func requireCapacity(_ count: Int) throws(BarrierBinaryCodecError) {
    guard count <= maximumByteCount - bytes.count else {
      throw .oversize(limit: maximumByteCount)
    }
  }

  private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
  }
}

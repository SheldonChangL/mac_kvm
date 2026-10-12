import Testing
@testable import BarrierCompatibility

// Golden frame: the first server-to-client frame of BARRIER-EVID-0002.
// Source: evidence/issues/M1-WIRE-001/barrier-frame-conformance.json
// /derived/runs/0 (byteLength 15; frames/0 lengthPrefixHex 0000000b, payloadOffset 4,
// payloadEndOffset 15). Payload = M1-025 marker `42 61 72 72 69 65 72` + version
// `00 01 00 06` (docs/adr/M1-025-barrier-client-wire-contract.md). Copied by hand;
// if that evidence is superseded, update these bytes from the superseding artifact.
private let goldenPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let goldenFrame: [UInt8] = [0x00, 0x00, 0x00, 0x0B] + goldenPayload

// MARK: - Reader happy path

@Test func readerDecodesUnsignedIntegersBigEndian() throws {
  var reader = BarrierBinaryReader(bytes: [0xAB, 0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF])
  #expect(try reader.readUInt8() == 0xAB)
  #expect(try reader.readUInt16() == 0x1234)
  #expect(try reader.readUInt32() == 0xDEAD_BEEF)
  #expect(reader.remainingCount == 0)
}

@Test func readerReadsGoldenLengthPrefixedFrame() throws {
  var reader = BarrierBinaryReader(bytes: goldenFrame)
  let payload = try reader.readLengthPrefixedPayload(maximumPayloadLength: 64)
  #expect(payload == goldenPayload)
  #expect(reader.remainingCount == 0)
}

@Test func readerReadsCoalescedFramesInOrder() throws {
  let second: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB]
  var reader = BarrierBinaryReader(bytes: goldenFrame + second)
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 64) == goldenPayload)
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 64) == [0xAA, 0xBB])
  #expect(reader.remainingCount == 0)
}

@Test func readerReadsRawBytes() throws {
  var reader = BarrierBinaryReader(bytes: [1, 2, 3, 4])
  #expect(try reader.readBytes(count: 3) == [1, 2, 3])
  #expect(reader.remainingCount == 1)
}

// MARK: - Reader boundary

@Test func readerAcceptsEmptyPayloadFrame() throws {
  var reader = BarrierBinaryReader(bytes: [0x00, 0x00, 0x00, 0x00])
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 0) == [])
  #expect(reader.remainingCount == 0)
}

@Test func readerAcceptsPayloadExactlyAtLimit() throws {
  var reader = BarrierBinaryReader(bytes: goldenFrame)
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 11) == goldenPayload)
}

@Test func readerAcceptsZeroCountReadOnEmptyInput() throws {
  var reader = BarrierBinaryReader(bytes: [])
  #expect(try reader.readBytes(count: 0) == [])
  #expect(reader.remainingCount == 0)
}

@Test func readerDecodesMaximumUInt32Prefix() throws {
  var reader = BarrierBinaryReader(bytes: [0xFF, 0xFF, 0xFF, 0xFF])
  #expect(try reader.readUInt32() == UInt32.max)
}

// MARK: - Reader invalid input / failure

@Test func readerRejectsPayloadOneByteOverLimit() {
  var reader = BarrierBinaryReader(bytes: goldenFrame)
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 10)) {
    try reader.readLengthPrefixedPayload(maximumPayloadLength: 10)
  }
}

@Test func readerRejectsMaximumPrefixBeforeReadingPayload() {
  var reader = BarrierBinaryReader(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0x00])
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 1024)) {
    try reader.readLengthPrefixedPayload(maximumPayloadLength: 1024)
  }
}

@Test func readerRejectsTruncatedIntegers() {
  var reader = BarrierBinaryReader(bytes: [0x01, 0x02, 0x03])
  #expect(throws: BarrierBinaryCodecError.truncated(requested: 4, remaining: 3)) {
    try reader.readUInt32()
  }
  #expect(reader.remainingCount == 3)
  var short = BarrierBinaryReader(bytes: [0x01])
  #expect(throws: BarrierBinaryCodecError.truncated(requested: 2, remaining: 1)) {
    try short.readUInt16()
  }
  #expect(short.remainingCount == 1)
  var empty = BarrierBinaryReader(bytes: [])
  #expect(throws: BarrierBinaryCodecError.truncated(requested: 1, remaining: 0)) {
    try empty.readUInt8()
  }
  #expect(empty.remainingCount == 0)
}

@Test func readerReportsTruncationForMaximumPrefixWithinUnboundedLimit() {
  var reader = BarrierBinaryReader(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0x00])
  #expect(throws: BarrierBinaryCodecError.truncated(requested: 4 + Int(UInt32.max), remaining: 5)) {
    try reader.readLengthPrefixedPayload(maximumPayloadLength: Int.max)
  }
  #expect(reader.remainingCount == 5)
}

@Test func readerRejectsTruncatedPrefixAtEveryLength() {
  for count in 0..<4 {
    var reader = BarrierBinaryReader(bytes: Array(goldenFrame.prefix(count)))
    #expect(throws: BarrierBinaryCodecError.truncated(requested: 4, remaining: count)) {
      try reader.readLengthPrefixedPayload(maximumPayloadLength: 64)
    }
  }
}

@Test func readerRejectsTruncatedPayloadAtEveryLength() {
  for count in 4..<goldenFrame.count {
    var reader = BarrierBinaryReader(bytes: Array(goldenFrame.prefix(count)))
    #expect(throws: BarrierBinaryCodecError.truncated(requested: 15, remaining: count)) {
      try reader.readLengthPrefixedPayload(maximumPayloadLength: 64)
    }
  }
}

@Test func readerRejectsHugeCountWithoutArithmeticOverflow() {
  var reader = BarrierBinaryReader(bytes: [1, 2])
  _ = try? reader.readUInt8()
  #expect(throws: BarrierBinaryCodecError.truncated(requested: Int.max, remaining: 1)) {
    try reader.readBytes(count: Int.max)
  }
}

@Test func readerRejectsNegativeCountAndLimit() {
  var reader = BarrierBinaryReader(bytes: goldenFrame)
  #expect(throws: BarrierBinaryCodecError.invalidCount) {
    try reader.readBytes(count: -1)
  }
  #expect(throws: BarrierBinaryCodecError.invalidCount) {
    try reader.readLengthPrefixedPayload(maximumPayloadLength: -1)
  }
}

// MARK: - Reader cleanup / idempotency

@Test func failedReadsDoNotAdvanceCursor() throws {
  var reader = BarrierBinaryReader(bytes: Array(goldenFrame.prefix(9)))
  for _ in 0..<2 {
    #expect(throws: BarrierBinaryCodecError.truncated(requested: 15, remaining: 9)) {
      try reader.readLengthPrefixedPayload(maximumPayloadLength: 64)
    }
    #expect(reader.remainingCount == 9)
  }
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 1)) {
    try reader.readLengthPrefixedPayload(maximumPayloadLength: 1)
  }
  #expect(reader.remainingCount == 9)
  #expect(try reader.readBytes(count: 9) == Array(goldenFrame.prefix(9)))
}

// MARK: - Writer happy path / golden bytes

@Test func writerEncodesUnsignedIntegersBigEndian() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 7)
  try writer.writeUInt8(0xAB)
  try writer.writeUInt16(0x1234)
  try writer.writeUInt32(0xDEAD_BEEF)
  #expect(writer.bytes == [0xAB, 0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF])
}

@Test func writerProducesGoldenFrameBytes() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 64)
  try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 64)
  #expect(writer.bytes == goldenFrame)
}

@Test func writerOutputRoundTripsThroughReader() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 64)
  try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 64)
  try writer.writeLengthPrefixedPayload([], maximumPayloadLength: 64)
  var reader = BarrierBinaryReader(bytes: writer.bytes)
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 64) == goldenPayload)
  #expect(try reader.readLengthPrefixedPayload(maximumPayloadLength: 64) == [])
  #expect(reader.remainingCount == 0)
}

// MARK: - Writer boundary

@Test func writerFillsCapacityExactly() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 15)
  try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 11)
  #expect(writer.bytes == goldenFrame)
}

@Test func writerWithZeroCapacityAcceptsEmptyWrite() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 0)
  try writer.writeBytes([])
  #expect(writer.bytes == [])
}

@Test func lengthPrefixAcceptsUInt32Range() throws {
  #expect(try BarrierBinaryWriter.lengthPrefix(for: 0) == 0)
  #expect(try BarrierBinaryWriter.lengthPrefix(for: Int(UInt32.max)) == UInt32.max)
}

// MARK: - Writer invalid input / failure

@Test func writerRejectsCapacityOverflow() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 14)
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 14)) {
    try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 64)
  }
  var full = try BarrierBinaryWriter(maximumByteCount: 1)
  try full.writeUInt8(0x01)
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 1)) {
    try full.writeUInt8(0x02)
  }
}

@Test func writerRejectsPayloadOverLimit() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 64)
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 10)) {
    try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 10)
  }
}

@Test func writerRejectsNegativeLimits() throws {
  #expect(throws: BarrierBinaryCodecError.invalidCount) {
    _ = try BarrierBinaryWriter(maximumByteCount: -1)
  }
  var writer = try BarrierBinaryWriter(maximumByteCount: 64)
  #expect(throws: BarrierBinaryCodecError.invalidCount) {
    try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: -1)
  }
}

@Test func lengthPrefixRejectsValuesOutsideUInt32() {
  #expect(throws: BarrierBinaryCodecError.integerOverflow) {
    try BarrierBinaryWriter.lengthPrefix(for: Int(UInt32.max) + 1)
  }
  #expect(throws: BarrierBinaryCodecError.integerOverflow) {
    try BarrierBinaryWriter.lengthPrefix(for: -1)
  }
}

// MARK: - Writer cleanup / idempotency

@Test func failedWritesLeaveBufferUnchanged() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 16)
  try writer.writeUInt8(0x7F)
  for _ in 0..<2 {
    #expect(throws: BarrierBinaryCodecError.oversize(limit: 16)) {
      try writer.writeLengthPrefixedPayload(goldenPayload + [0x00, 0x00], maximumPayloadLength: 64)
    }
    #expect(writer.bytes == [0x7F])
  }
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 1)) {
    try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 1)
  }
  #expect(writer.bytes == [0x7F])
  try writer.writeLengthPrefixedPayload(goldenPayload, maximumPayloadLength: 11)
  #expect(writer.bytes == [0x7F] + goldenFrame)
}

@Test func failedPrimitiveWritesLeaveBufferUnchanged() throws {
  var writer = try BarrierBinaryWriter(maximumByteCount: 3)
  try writer.writeUInt8(0x01)
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 3)) {
    try writer.writeUInt32(0xDEAD_BEEF)
  }
  #expect(throws: BarrierBinaryCodecError.oversize(limit: 3)) {
    try writer.writeBytes([0xAA, 0xBB, 0xCC])
  }
  #expect(writer.bytes == [0x01])
  try writer.writeUInt16(0x0203)
  #expect(writer.bytes == [0x01, 0x02, 0x03])
}

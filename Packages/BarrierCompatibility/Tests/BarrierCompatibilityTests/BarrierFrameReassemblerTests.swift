import Testing
@testable import BarrierCompatibility

private typealias ReassemblyError = BarrierFrameReassemblerError

// Golden frame: the first server-to-client frame of BARRIER-EVID-0002, the same bytes
// used by BarrierBinaryCodecTests (M1-021).
// Source: evidence/issues/M1-WIRE-001/barrier-frame-conformance.json
// /derived/runs/0 (byteLength 15; frames/0 lengthPrefixHex 0000000b, payloadOffset 4,
// payloadEndOffset 15). Payload = M1-025 marker `42 61 72 72 69 65 72` + version
// `00 01 00 06` (docs/adr/M1-025-barrier-client-wire-contract.md). Copied by hand;
// if that evidence is superseded, update these bytes from the superseding artifact.
private let goldenPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let goldenFrame: [UInt8] = [0x00, 0x00, 0x00, 0x0B] + goldenPayload

// Synthetic frames for coalescing tests; the payload bytes carry no Barrier meaning.
private let emptyFrame: [UInt8] = [0x00, 0x00, 0x00, 0x00]
private let shortFrame: [UInt8] = [0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB]
private let coalescedStream = goldenFrame + emptyFrame + shortFrame
private let coalescedPayloads: [[UInt8]] = [goldenPayload, [], [0xAA, 0xBB]]

extension BarrierFrameReassembler {
  /// Drains every payload that is ready now.
  fileprivate mutating func drainReadyPayloads() throws(ReassemblyError) -> [[UInt8]] {
    var payloads: [[UInt8]] = []
    while let payload = try nextPayload() {
      payloads.append(payload)
    }
    return payloads
  }
}

// MARK: - Happy path

@Test func reassemblesGoldenFrameFromSingleAppend() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(goldenFrame)
  #expect(try reassembler.nextPayload() == goldenPayload)
  #expect(try reassembler.nextPayload() == nil)
  #expect(reassembler.pendingByteCount == 0)
  try reassembler.finish()
  #expect(try reassembler.nextPayload() == nil)
}

@Test func reassemblesGoldenFrameSplitAtEveryOffset() throws {
  // Offsets 1...3 split the prefix, 4 is the prefix/payload boundary and 5...14 split
  // the payload; 0 and 15 put an empty chunk on one side.
  for split in 0...goldenFrame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    try reassembler.append(Array(goldenFrame[..<split]))
    if split < goldenFrame.count {
      #expect(try reassembler.nextPayload() == nil)
      #expect(reassembler.pendingByteCount == split)
    }
    try reassembler.append(Array(goldenFrame[split...]))
    #expect(try reassembler.drainReadyPayloads() == [goldenPayload])
    #expect(reassembler.pendingByteCount == 0)
    try reassembler.finish()
  }
}

@Test func reassemblesGoldenFrameOneByteAtATime() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  for (index, byte) in goldenFrame.enumerated() {
    try reassembler.append([byte])
    if index < goldenFrame.count - 1 {
      #expect(try reassembler.nextPayload() == nil)
      #expect(reassembler.pendingByteCount == index + 1)
    }
  }
  #expect(try reassembler.drainReadyPayloads() == [goldenPayload])
  try reassembler.finish()
}

@Test func reassemblesCoalescedFramesFromSingleAppend() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(coalescedStream)
  #expect(try reassembler.drainReadyPayloads() == coalescedPayloads)
  #expect(reassembler.pendingByteCount == 0)
  try reassembler.finish()
}

@Test func reassemblesCoalescedFramesAcrossEveryChunkSize() throws {
  // Each chunk size mixes split and coalesced frames: chunks end inside prefixes,
  // inside payloads and on frame boundaries.
  for chunkSize in 1...coalescedStream.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    var payloads: [[UInt8]] = []
    var start = 0
    while start < coalescedStream.count {
      let end = min(start + chunkSize, coalescedStream.count)
      try reassembler.append(Array(coalescedStream[start..<end]))
      payloads += try reassembler.drainReadyPayloads()
      start = end
    }
    #expect(payloads == coalescedPayloads)
    #expect(reassembler.pendingByteCount == 0)
    try reassembler.finish()
  }
}

@Test func reassemblesCoalescedFramesWithoutInterleavedDraining() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  for byte in coalescedStream {
    try reassembler.append([byte])
  }
  try reassembler.finish()
  #expect(try reassembler.drainReadyPayloads() == coalescedPayloads)
}

// MARK: - Golden / conformance bytes

@Test func reassembledGoldenPayloadReencodesToExactGoldenBytes() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(Array(goldenFrame[..<2]))
  try reassembler.append(Array(goldenFrame[2..<9]))
  try reassembler.append(Array(goldenFrame[9...]))
  let payload = try reassembler.nextPayload()
  #expect(payload == goldenPayload)
  var writer = try BarrierBinaryWriter(maximumByteCount: 64)
  try writer.writeLengthPrefixedPayload(payload ?? [], maximumPayloadLength: 64)
  #expect(writer.bytes == goldenFrame)
}

// MARK: - Boundary / limit

@Test func emptyPayloadFrameCompletesWithoutFurtherBytes() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 0)
  try reassembler.append(Array(emptyFrame[..<3]))
  #expect(try reassembler.nextPayload() == nil)
  try reassembler.append(Array(emptyFrame[3...]))
  #expect(try reassembler.nextPayload() == [])
  #expect(try reassembler.nextPayload() == nil)
  #expect(reassembler.pendingByteCount == 0)
  try reassembler.finish()
}

@Test func acceptsFrameExactlyAtLimit() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 11)
  try reassembler.append(goldenFrame)
  #expect(try reassembler.nextPayload() == goldenPayload)
}

@Test func rejectsFrameOneByteOverLimit() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 10)
  #expect(throws: ReassemblyError.oversize(limit: 10)) {
    try reassembler.append(goldenFrame)
  }
  #expect(throws: ReassemblyError.oversize(limit: 10)) {
    try reassembler.nextPayload()
  }
}

@Test func emptyAppendIsNoOp() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append([])
  #expect(try reassembler.nextPayload() == nil)
  #expect(reassembler.pendingByteCount == 0)
  try reassembler.finish()
}

@Test func finishWithoutBytesSucceeds() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.finish()
  #expect(try reassembler.nextPayload() == nil)
}

// MARK: - Invalid input / failure

@Test func rejectsNegativeMaximumPayloadLength() {
  #expect(throws: ReassemblyError.invalidMaximumPayloadLength) {
    _ = try BarrierFrameReassembler(maximumPayloadLength: -1)
  }
}

@Test func rejectsMaximumPrefixBeforeBufferingPayload() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 1024)
  #expect(throws: ReassemblyError.oversize(limit: 1024)) {
    try reassembler.append([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01])
  }
  #expect(reassembler.pendingByteCount == 0)
}

@Test func rejectsOversizePrefixSplitAcrossChunksWhenLastPrefixByteArrives() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 10)
  try reassembler.append([0x00, 0x00, 0x00])
  #expect(throws: ReassemblyError.oversize(limit: 10)) {
    try reassembler.append([0x0B])
  }
}

@Test func finishReportsTruncatedPrefixAtEveryLength() throws {
  for count in 1..<4 {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    try reassembler.append(Array(goldenFrame[..<count]))
    #expect(throws: ReassemblyError.truncatedPrefix(received: count)) {
      try reassembler.finish()
    }
  }
}

@Test func finishReportsTruncatedPayloadAtEveryLength() throws {
  for count in 4..<goldenFrame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    try reassembler.append(Array(goldenFrame[..<count]))
    #expect(throws: ReassemblyError.truncatedPayload(expected: 11, received: count - 4)) {
      try reassembler.finish()
    }
  }
}

@Test func finishReportsTruncationForMaximumPrefixWithinUnboundedLimit() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: Int.max)
  try reassembler.append([0xFF, 0xFF, 0xFF, 0xFF, 0x00])
  #expect(try reassembler.nextPayload() == nil)
  #expect(throws: ReassemblyError.truncatedPayload(expected: Int(UInt32.max), received: 1)) {
    try reassembler.finish()
  }
}

@Test func appendAfterFinishFails() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(goldenFrame)
  try reassembler.finish()
  for _ in 0..<2 {
    #expect(throws: ReassemblyError.appendAfterFinish) {
      try reassembler.append(goldenFrame)
    }
  }
  #expect(try reassembler.drainReadyPayloads() == [goldenPayload])
}

// MARK: - Cleanup / idempotency

@Test func framesCompletedBeforeOversizeRemainAvailable() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 11)
  #expect(throws: ReassemblyError.oversize(limit: 11)) {
    try reassembler.append(goldenFrame + emptyFrame + [0x00, 0x00, 0x00, 0x0C, 0x01])
  }
  #expect(try reassembler.nextPayload() == goldenPayload)
  #expect(try reassembler.nextPayload() == [])
  for _ in 0..<2 {
    #expect(throws: ReassemblyError.oversize(limit: 11)) {
      try reassembler.nextPayload()
    }
  }
}

@Test func framesCompletedBeforeTruncationRemainAvailable() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(goldenFrame + Array(shortFrame[..<5]))
  #expect(throws: ReassemblyError.truncatedPayload(expected: 2, received: 1)) {
    try reassembler.finish()
  }
  #expect(try reassembler.nextPayload() == goldenPayload)
  #expect(throws: ReassemblyError.truncatedPayload(expected: 2, received: 1)) {
    try reassembler.nextPayload()
  }
}

@Test func failureIsStickyAndReleasesPartialBytes() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 4)
  try reassembler.append([0x00, 0x00])
  #expect(throws: ReassemblyError.oversize(limit: 4)) {
    try reassembler.append([0x00, 0x05, 0x01])
  }
  #expect(reassembler.pendingByteCount == 0)
  for _ in 0..<2 {
    #expect(throws: ReassemblyError.oversize(limit: 4)) {
      try reassembler.append(emptyFrame)
    }
    #expect(throws: ReassemblyError.oversize(limit: 4)) {
      try reassembler.finish()
    }
    #expect(throws: ReassemblyError.oversize(limit: 4)) {
      try reassembler.nextPayload()
    }
    #expect(reassembler.pendingByteCount == 0)
  }
}

@Test func truncationAtFinishIsStableAndReleasesPartialBytes() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(Array(goldenFrame[..<2]))
  for _ in 0..<2 {
    #expect(throws: ReassemblyError.truncatedPrefix(received: 2)) {
      try reassembler.finish()
    }
    #expect(throws: ReassemblyError.truncatedPrefix(received: 2)) {
      try reassembler.append(Array(goldenFrame[2...]))
    }
    #expect(throws: ReassemblyError.truncatedPrefix(received: 2)) {
      try reassembler.nextPayload()
    }
    #expect(reassembler.pendingByteCount == 0)
  }
}

@Test func cleanFinishIsIdempotent() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(coalescedStream)
  try reassembler.finish()
  try reassembler.finish()
  #expect(try reassembler.drainReadyPayloads() == coalescedPayloads)
  #expect(try reassembler.nextPayload() == nil)
  try reassembler.finish()
}

@Test func drainedPayloadsAreNotReturnedTwice() throws {
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  try reassembler.append(goldenFrame)
  #expect(try reassembler.drainReadyPayloads() == [goldenPayload])
  try reassembler.append(shortFrame)
  #expect(try reassembler.drainReadyPayloads() == [[0xAA, 0xBB]])
  #expect(try reassembler.nextPayload() == nil)
}

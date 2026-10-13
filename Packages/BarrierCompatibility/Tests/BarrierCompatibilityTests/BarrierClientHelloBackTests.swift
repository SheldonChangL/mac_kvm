import Testing
@testable import BarrierCompatibility

private typealias HelloBackError = BarrierClientHelloBackError

// Golden frames: the client-to-server run of each BARRIER-EVID-0004 attempt.
// Source: Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json
// /attempts/0 and /attempts/1, connections/0 streams/1 runs/0, decoded from base64, and the
// HelloBack table in docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md. Frame = 4-byte
// big-endian payload length + marker `42 61 72 72 69 65 72` + opaque version `00 01 00 06`
// + 4-byte big-endian screen-name byte count + screen-name UTF-8 bytes. Copied by hand; if
// that evidence is superseded, update these bytes from the superseding artifact.
private let markerBytes: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
private let versionBytes: [UInt8] = [0x00, 0x01, 0x00, 0x06]
private let goldenM1ClientFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x18, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00,
  0x06, 0x00, 0x00, 0x00, 0x09, 0x6D, 0x31, 0x2D, 0x63, 0x6C, 0x69, 0x65, 0x6E, 0x74,
]
private let goldenM1xFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00,
  0x06, 0x00, 0x00, 0x00, 0x03, 0x6D, 0x31, 0x78,
]

private func makeWriter(limit: Int = 64) throws -> BarrierClientHelloBackWriter {
  try BarrierClientHelloBackWriter(maximumScreenNameByteCount: limit)
}

private func caughtError(
  _ body: () throws(HelloBackError) -> [UInt8]
) -> HelloBackError? {
  do throws(HelloBackError) {
    _ = try body()
    return nil
  } catch {
    return error
  }
}

// MARK: - Happy path

@Test func writesGoldenFrameForM1ClientExactly() throws {
  #expect(try makeWriter().frame(screenName: "m1-client") == goldenM1ClientFrame)
}

@Test func writesGoldenFrameForM1xExactly() throws {
  #expect(try makeWriter().frame(screenName: "m1x") == goldenM1xFrame)
}

@Test func helloBackConstantsEqualGoldenBytesExactly() {
  #expect(BarrierClientHelloBackWriter.markerBytes == markerBytes)
  #expect(BarrierClientHelloBackWriter.versionBytes == versionBytes)
  #expect(Array(goldenM1ClientFrame[4..<11]) == markerBytes)
  #expect(Array(goldenM1ClientFrame[11..<15]) == versionBytes)
}

@Test func goldenFramesDifferOnlyByScreenNameDelta() throws {
  // ADR: the payload length and screen-name length change by the same six-byte delta.
  let writer = try makeWriter()
  let long = try writer.frame(screenName: "m1-client")
  let short = try writer.frame(screenName: "m1x")
  #expect(long.count - short.count == 6)
  #expect(Array(long[..<4]) == [0x00, 0x00, 0x00, 0x18])
  #expect(Array(short[..<4]) == [0x00, 0x00, 0x00, 0x12])
  #expect(Array(long[15..<19]) == [0x00, 0x00, 0x00, 0x09])
  #expect(Array(short[15..<19]) == [0x00, 0x00, 0x00, 0x03])
}

@Test func reassemblerYieldsGoldenPayloadsFromFragmentedAndCoalescedFrames() throws {
  // Stream fragmentation belongs to M1-022; this pins the hand-off: the written frames,
  // coalesced into one stream and fed back one byte at a time, reassemble into exactly
  // the golden payloads.
  let writer = try makeWriter()
  let stream = try writer.frame(screenName: "m1-client") + writer.frame(screenName: "m1x")
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var payloads: [[UInt8]] = []
  for byte in stream {
    try reassembler.append([byte])
    while let payload = try reassembler.nextPayload() {
      payloads.append(payload)
    }
  }
  try reassembler.finish()
  let expected: [[UInt8]] = [
    Array(goldenM1ClientFrame.dropFirst(4)), Array(goldenM1xFrame.dropFirst(4)),
  ]
  #expect(payloads == expected)
}

@Test func truncatedWrittenFrameIsReportedByReassembler() throws {
  let frame = try makeWriter().frame(screenName: "m1-client")
  for length in 1..<frame.count {
    var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
    try reassembler.append(Array(frame[..<length]))
    #expect(try reassembler.nextPayload() == nil)
    let expected: BarrierFrameReassemblerError =
      length < 4
      ? .truncatedPrefix(received: length)
      : .truncatedPayload(expected: 24, received: length - 4)
    #expect(throws: expected) { try reassembler.finish() }
  }
}

// MARK: - Boundary

@Test func acceptsScreenNameAtExactlyTheConfiguredLimit() throws {
  let name = String(repeating: "a", count: 16)
  let frame = try makeWriter(limit: 16).frame(screenName: name)
  #expect(frame.count == 4 + 7 + 4 + 4 + 16)
  #expect(Array(frame[..<4]) == [0x00, 0x00, 0x00, 0x1F])
  #expect(Array(frame[15..<19]) == [0x00, 0x00, 0x00, 0x10])
  #expect(Array(frame[19...]) == Array(name.utf8))
}

@Test func rejectsScreenNameOneByteOverTheConfiguredLimit() throws {
  let name = String(repeating: "a", count: 17)
  #expect(throws: HelloBackError.screenNameTooLong(byteCount: 17, limit: 16)) {
    try makeWriter(limit: 16).frame(screenName: name)
  }
}

@Test func acceptsSingleByteScreenNameAtMinimumLimit() throws {
  let frame = try makeWriter(limit: 1).frame(screenName: "x")
  let lengthPrefix: [UInt8] = [0x00, 0x00, 0x00, 0x10]
  let nameField: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x78]
  let expected = lengthPrefix + markerBytes + versionBytes + nameField
  #expect(frame == expected)
}

@Test func lengthFieldsAreBigEndianAcrossByteBoundary() throws {
  // 300 = 0x012C exercises two non-zero bytes, so a little-endian writer cannot pass.
  let name = String(repeating: "z", count: 300)
  let frame = try makeWriter(limit: 300).frame(screenName: name)
  #expect(Array(frame[..<4]) == [0x00, 0x00, 0x01, 0x3B])
  #expect(Array(frame[15..<19]) == [0x00, 0x00, 0x01, 0x2C])
  #expect(frame.count == 4 + 315)
}

@Test func acceptsEveryAllowedCharacterClass() throws {
  let name = "ABCXYZabcxyz0189-_"
  let frame = try makeWriter().frame(screenName: name)
  #expect(Array(frame[19...]) == Array(name.utf8))
}

@Test func rejectsInvalidConfiguredLimits() {
  for limit in [0, -1, Int.min] {
    #expect(throws: HelloBackError.invalidMaximumScreenNameByteCount) {
      try BarrierClientHelloBackWriter(maximumScreenNameByteCount: limit)
    }
  }
  // The whole payload must still fit the 4-byte unsigned length prefix.
  #expect(throws: HelloBackError.invalidMaximumScreenNameByteCount) {
    try BarrierClientHelloBackWriter(maximumScreenNameByteCount: Int.max)
  }
}

@Test func acceptsLargestLimitThatFitsTheLengthPrefix() throws {
  let limit = BarrierClientHelloBackWriter.largestSupportedMaximumScreenNameByteCount
  #expect(limit == Int(UInt32.max) - 15)
  let writer = try BarrierClientHelloBackWriter(maximumScreenNameByteCount: limit)
  #expect(try writer.frame(screenName: "m1x") == goldenM1xFrame)
  #expect(throws: HelloBackError.invalidMaximumScreenNameByteCount) {
    try BarrierClientHelloBackWriter(maximumScreenNameByteCount: limit + 1)
  }
}

// MARK: - Invalid input / failure

@Test func rejectsEmptyScreenName() {
  #expect(throws: HelloBackError.emptyScreenName) { try makeWriter().frame(screenName: "") }
}

@Test func rejectsNonASCIIScreenNames() {
  for name in ["m1-clïent", "螢幕", "m1x\u{1F5A5}", "e\u{301}"] {
    #expect(throws: HelloBackError.unsupportedScreenNameCharacter) {
      try makeWriter().frame(screenName: name)
    }
  }
}

@Test func rejectsASCIIOutsideTheIdentifierSet() {
  let names = [
    "m1 client", "m1.client", "user@host", "a/b", "a\\b", "a:b", "a\u{0}b", "tab\t",
    "line\n", "\u{7F}", "%", "~",
  ]
  for name in names {
    #expect(throws: HelloBackError.unsupportedScreenNameCharacter) {
      try makeWriter().frame(screenName: name)
    }
  }
}

@Test func checksLengthBeforeCharacters() {
  // An over-limit name is rejected by byte count before its contents are inspected.
  #expect(throws: HelloBackError.screenNameTooLong(byteCount: 6, limit: 3)) {
    try makeWriter(limit: 3).frame(screenName: "螢幕")
  }
}

@Test func helloBackErrorsCarryOnlyAllowlistedMetadata() throws {
  // One rejected screen name per screen-name error case.
  let writer = try makeWriter(limit: 4)
  let errors = ["", "secret", "a@b"].map { name in
    caughtError { () throws(HelloBackError) in try writer.frame(screenName: name) }
  }
  #expect(
    errors == [
      .emptyScreenName, .screenNameTooLong(byteCount: 6, limit: 4),
      .unsupportedScreenNameCharacter,
    ])
  // An enum case reflects its associated values as one labeled tuple child.
  let associated = errors.compactMap { $0 }.flatMap { error in
    Mirror(reflecting: error).children.flatMap { Mirror(reflecting: $0.value).children }
  }
  #expect(associated.map(\.label) == ["byteCount", "limit"])
  #expect(associated.allSatisfy { $0.value is Int })
  for error in errors.compactMap({ $0 }) {
    #expect(!String(describing: error).contains("secret"))
  }
}

@Test func writerCarriesOnlyTheConfiguredLimit() throws {
  let labels = Mirror(reflecting: try makeWriter()).children.compactMap(\.label)
  #expect(labels == ["maximumScreenNameByteCount"])
}

// MARK: - Cleanup / idempotency

@Test func repeatedWritesReturnIdenticalBytes() throws {
  // The writer owns no resource or mutable state; repeating a write is deterministic.
  let writer = try makeWriter()
  let first = try writer.frame(screenName: "m1-client")
  let second = try writer.frame(screenName: "m1-client")
  #expect(first == goldenM1ClientFrame)
  #expect(second == first)
}

@Test func failedWriteDoesNotAffectLaterWrite() throws {
  let writer = try makeWriter(limit: 9)
  #expect(throws: HelloBackError.emptyScreenName) { try writer.frame(screenName: "") }
  #expect(throws: HelloBackError.screenNameTooLong(byteCount: 10, limit: 9)) {
    try writer.frame(screenName: "m1-client2")
  }
  #expect(throws: HelloBackError.unsupportedScreenNameCharacter) {
    try writer.frame(screenName: "m1 client")
  }
  #expect(try writer.frame(screenName: "m1-client") == goldenM1ClientFrame)
  #expect(try writer.frame(screenName: "m1x") == goldenM1xFrame)
}

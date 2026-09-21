import Foundation
import Testing

@testable import KVMContracts

private func requireValueContract<Value: Hashable & Sendable>(_: Value) {}

/// Exercises every UTF-8 sequence length in one value: 1-byte ASCII, 2-byte
/// Latin-1 supplement, 3-byte CJK and a 4-byte emoji, for ten bytes total.
private let mixedWidthText = "a\u{00E9}\u{6E2C}\u{1F600}"
private let mixedWidthByteCount = 10

/// Synthetic sentinels that exist only so a privacy assertion has something
/// distinctive to search for. They are test fixtures, never clipboard content.
private let probeText = "m1-052-probe-\u{1F600}-\u{6E2C}"
private let probeHash = "m1-052-probe-hash"

private let fixtureTransactionID = ClipboardTransactionID(
  rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
)

private func makePayload(text: String, hash: String = probeHash) -> ClipboardPayload {
  ClipboardPayload(
    transactionID: fixtureTransactionID,
    origin: .local,
    utf8Text: text,
    contentHash: hash
  )
}

private func clipboardFailure(_ code: ClipboardErrorCode) -> CoreError {
  CoreError(
    code: .clipboard(code),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

private let invalidUTF8Failure = clipboardFailure(.invalidUTF8)
private let oversizedFailure = clipboardFailure(.oversized)

private func captureCoreError(_ operation: () throws -> Void) -> CoreError? {
  do {
    try operation()
    return nil
  } catch let error as CoreError {
    return error
  } catch {
    return nil
  }
}

// MARK: - Happy path

@Test func utf8PlainTextRoundTripsThroughTheCodec() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 64))

  let encoded = try ClipboardTextCodec.encode(mixedWidthText, limit: limit)

  #expect(encoded.count == mixedWidthByteCount)
  #expect(Array(encoded) == Array(mixedWidthText.utf8))
  #expect(try ClipboardTextCodec.decode(encoded, limit: limit) == mixedWidthText)
}

/// The decoder must be byte-faithful, not merely "able to produce a String".
/// `String(data:encoding:.utf8)` silently strips a leading U+FEFF, which would
/// make a decode/encode cycle lose bytes; this pins the lossless contract.
@Test func decodingPreservesEveryValidByteSequenceExactly() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 64))
  let validSequences: [[UInt8]] = [
    [],
    [0x61],
    [0xEF, 0xBB, 0xBF, 0x61],
    [0xEF, 0xBF, 0xBD],
    [0x61, 0x00, 0x62],
    [0x0D, 0x0A, 0x09],
    [0xF0, 0x9F, 0x98, 0x80],
    [0xE6, 0xB8, 0xAC, 0xE8, 0xA9, 0xA6],
    [0xF4, 0x8F, 0xBF, 0xBF],
  ]

  for bytes in validSequences {
    let decoded = try ClipboardTextCodec.decode(Data(bytes), limit: limit)

    #expect(Array(decoded.utf8) == bytes)
    #expect(try Array(ClipboardTextCodec.encode(decoded, limit: limit)) == bytes)
  }
}

@Test func codecAcceptsDataSlicesWithANonZeroStartIndex() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 4))
  let backing = Data([0xFF, 0xFF, 0xF0, 0x9F, 0x98, 0x80, 0xFF])
  let slice = backing[2..<6]

  #expect(slice.startIndex == 2)
  #expect(try ClipboardTextCodec.decode(slice, limit: limit) == "\u{1F600}")

  let oversizedSlice = backing[1..<6]

  #expect(throws: oversizedFailure) {
    try ClipboardTextCodec.decode(oversizedSlice, limit: limit)
  }
}

@Test func byteLimitSatisfiesTheContractsValueSemantics() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 8))

  requireValueContract(limit)
  #expect(ClipboardByteLimit(byteCount: 8) == limit)
  #expect(ClipboardByteLimit(byteCount: 9) != limit)
  #expect(Set([limit, ClipboardByteLimit(byteCount: 8)!]).count == 1)
}

// MARK: - Boundary

@Test func codecAcceptsContentExactlyAtTheByteLimit() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: mixedWidthByteCount))

  let encoded = try ClipboardTextCodec.encode(mixedWidthText, limit: limit)

  #expect(encoded.count == limit.byteCount)
  #expect(try ClipboardTextCodec.decode(encoded, limit: limit) == mixedWidthText)
}

@Test func codecRejectsContentOneByteOverTheLimit() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: mixedWidthByteCount - 1))
  let data = Data(mixedWidthText.utf8)

  #expect(throws: oversizedFailure) {
    try ClipboardTextCodec.encode(mixedWidthText, limit: limit)
  }
  #expect(throws: oversizedFailure) {
    try ClipboardTextCodec.decode(data, limit: limit)
  }
}

@Test func limitsCountUTF8BytesNotCharacters() throws {
  let threeBytes = try #require(ClipboardByteLimit(byteCount: 3))
  let fourBytes = try #require(ClipboardByteLimit(byteCount: 4))
  let emoji = "\u{1F600}"

  #expect(emoji.count == 1)
  #expect(throws: oversizedFailure) {
    try ClipboardTextCodec.encode(emoji, limit: threeBytes)
  }

  let encoded = try ClipboardTextCodec.encode(emoji, limit: fourBytes)

  #expect(encoded.count == 4)
  #expect(try ClipboardTextCodec.decode(encoded, limit: fourBytes) == emoji)
}

@Test func smallestValidLimitAcceptsExactlyOneByte() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 1))

  #expect(try ClipboardTextCodec.decode(Data([0x61]), limit: limit) == "a")
  #expect(throws: oversizedFailure) {
    try ClipboardTextCodec.decode(Data([0x61, 0x62]), limit: limit)
  }
}

@Test func maximumLimitComparesWithoutOverflow() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: .max))

  let encoded = try ClipboardTextCodec.encode(mixedWidthText, limit: limit)

  #expect(Array(encoded) == Array(mixedWidthText.utf8))
  #expect(try ClipboardTextCodec.decode(encoded, limit: limit) == mixedWidthText)
}

@Test func emptyContentIsCarriedRatherThanRejectedHere() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 1))

  let encoded = try ClipboardTextCodec.encode("", limit: limit)

  #expect(encoded.isEmpty)
  #expect(try ClipboardTextCodec.decode(Data(), limit: limit) == "")
}

// MARK: - Invalid limit configuration

@Test func byteLimitRejectsEveryNonPositiveConfiguration() {
  #expect(ClipboardByteLimit(byteCount: 0) == nil)
  #expect(ClipboardByteLimit(byteCount: -1) == nil)
  #expect(ClipboardByteLimit(byteCount: .min) == nil)
  #expect(ClipboardByteLimit(byteCount: 1)?.byteCount == 1)
  #expect(ClipboardByteLimit(byteCount: .max)?.byteCount == .max)
}

// MARK: - Invalid input

@Test func decodingRejectsEveryInvalidUTF8Shape() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 64))
  let invalidSequences: [[UInt8]] = [
    [0xFF],
    [0xFE],
    [0xC3],
    [0xC3, 0x28],
    [0xC0, 0xAF],
    [0xE0, 0x80, 0xAF],
    [0xED, 0xA0, 0x80],
    [0xED, 0xA0, 0xBD, 0xED, 0xB8, 0x80],
    [0xF4, 0x90, 0x80, 0x80],
    [0x61, 0xC3],
    [0x80],
    [0xF0, 0x9F, 0x98],
  ]

  for bytes in invalidSequences {
    #expect(throws: invalidUTF8Failure) {
      try ClipboardTextCodec.decode(Data(bytes), limit: limit)
    }
  }
}

/// Size must be enforced before any decode or allocation, so an input that is
/// both oversized and malformed is reported as oversized.
@Test func oversizedInputIsRejectedBeforeUTF8Validation() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 2))
  let error = try #require(
    captureCoreError {
      _ = try ClipboardTextCodec.decode(Data([0xFF, 0xFF, 0xFF]), limit: limit)
    }
  )

  #expect(error == oversizedFailure)
  #expect(error.code == .clipboard(.oversized))
}

// MARK: - Payload bounds

@Test func payloadBoundsAreEnforcedOnUTF8ByteCount() throws {
  let payload = makePayload(text: mixedWidthText)
  let atLimit = try #require(ClipboardByteLimit(byteCount: mixedWidthByteCount))
  let oneByteShort = try #require(ClipboardByteLimit(byteCount: mixedWidthByteCount - 1))

  #expect(payload.utf8ByteCount == mixedWidthByteCount)
  try payload.validate(against: atLimit)
  #expect(throws: oversizedFailure) {
    try payload.validate(against: oneByteShort)
  }
}

@Test func emptyPayloadHasZeroUTF8Bytes() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 1))
  let payload = makePayload(text: "")

  #expect(payload.utf8ByteCount == 0)
  try payload.validate(against: limit)
}

// MARK: - Frozen taxonomy and privacy

@Test func clipboardFailuresUseTheFrozenClipboardTaxonomy() throws {
  let tight = try #require(ClipboardByteLimit(byteCount: 1))
  let wide = try #require(ClipboardByteLimit(byteCount: 64))
  let observed = [
    try #require(
      captureCoreError { _ = try ClipboardTextCodec.encode(probeText, limit: tight) }
    ),
    try #require(
      captureCoreError { _ = try ClipboardTextCodec.decode(Data([0xFF]), limit: wide) }
    ),
    try #require(
      captureCoreError { try makePayload(text: probeText).validate(against: tight) }
    ),
  ]

  #expect(observed == [oversizedFailure, invalidUTF8Failure, oversizedFailure])

  for error in observed {
    #expect(error.domain == .clipboard)
    #expect(error.severity == .warning)
    #expect(error.retryDisposition == .never)
    #expect(error.retryDisposition.allowsRetry == false)
    #expect(error.retryDisposition.allowsAutomaticRetry == false)
    #expect(error.cleanupDisposition == .notRequired)
    #expect(error.underlyingDiagnosticCode == nil)
  }

  // Only the two codes this Issue owns may be produced; unsupportedType and
  // loopRejected belong to the platform and loop-suppression Issues.
  #expect(
    Set(observed.map(\.code))
      == Set([CoreErrorCode.clipboard(.oversized), .clipboard(.invalidUTF8)])
  )
}

@Test func clipboardFailuresCarryNoTextOrHash() throws {
  let tight = try #require(ClipboardByteLimit(byteCount: 1))
  let wide = try #require(ClipboardByteLimit(byteCount: 64))
  let payload = makePayload(text: probeText)
  let failures: [() throws -> Void] = [
    { _ = try ClipboardTextCodec.encode(probeText, limit: tight) },
    { _ = try ClipboardTextCodec.decode(Data(probeText.utf8), limit: tight) },
    { _ = try ClipboardTextCodec.decode(Data([0xED, 0xA0, 0x80]), limit: wide) },
    { try payload.validate(against: tight) },
  ]

  for failure in failures {
    let error = try #require(captureCoreError(failure))
    let renderings = [
      String(describing: error),
      String(reflecting: error),
      String(decoding: try JSONEncoder().encode(error), as: UTF8.self),
    ]

    for rendering in renderings {
      #expect(rendering.contains(probeText) == false)
      #expect(rendering.contains(probeHash) == false)
      #expect(rendering.contains("\u{1F600}") == false)
      #expect(rendering.contains("\u{6E2C}") == false)
    }
  }
}

// MARK: - M1-013 compatibility and determinism

@Test func clipboardPayloadCodingShapeIsUnchanged() throws {
  let payload = makePayload(text: mixedWidthText)
  let encoded = try JSONEncoder().encode(payload)
  let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

  #expect(Set(object.keys) == Set(["transactionID", "origin", "utf8Text", "contentHash"]))
  #expect(try JSONDecoder().decode(ClipboardPayload.self, from: encoded) == payload)

  let event = KVMEvent.clipboard(payload)
  let encodedEvent = try JSONEncoder().encode(event)

  #expect(try JSONDecoder().decode(KVMEvent.self, from: encodedEvent) == event)
}

@Test func codecIsPureAcrossRepeatedSuccessAndFailure() throws {
  let limit = try #require(ClipboardByteLimit(byteCount: 16))
  let tight = try #require(ClipboardByteLimit(byteCount: 1))
  let first = try ClipboardTextCodec.encode(mixedWidthText, limit: limit)
  let second = try ClipboardTextCodec.encode(mixedWidthText, limit: limit)

  #expect(first == second)
  #expect(
    try ClipboardTextCodec.decode(first, limit: limit)
      == ClipboardTextCodec.decode(second, limit: limit)
  )

  let firstFailure = try #require(
    captureCoreError { _ = try ClipboardTextCodec.encode(mixedWidthText, limit: tight) }
  )
  let secondFailure = try #require(
    captureCoreError { _ = try ClipboardTextCodec.encode(mixedWidthText, limit: tight) }
  )

  #expect(firstFailure == secondFailure)
  #expect(try ClipboardTextCodec.encode(mixedWidthText, limit: limit) == first)
}

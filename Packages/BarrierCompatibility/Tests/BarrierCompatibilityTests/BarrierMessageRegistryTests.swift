import Testing
@testable import BarrierCompatibility

private typealias RegistryError = BarrierMessageRegistryError

// Golden payload: the first server-to-client frame payload of BARRIER-EVID-0002, the same
// bytes used by BarrierBinaryCodecTests (M1-021) and BarrierFrameReassemblerTests (M1-022).
// Source: evidence/issues/M1-WIRE-001/barrier-frame-conformance.json /derived/runs/0
// (frames/0 payloadOffset 4, payloadEndOffset 15). Payload = M1-025 marker
// `42 61 72 72 69 65 72` + version `00 01 00 06`
// (docs/adr/M1-025-barrier-client-wire-contract.md). Copied by hand.
// The frozen marker is registered below only as a prefix that exercises dispatch on golden
// bytes; it is not a claim about Barrier message codes, and the version bytes are passed
// on opaque (validating them belongs to M1-027).
private let markerBytes: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
private let versionBytes: [UInt8] = [0x00, 0x01, 0x00, 0x06]
private let goldenPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]

// Synthetic codes for dispatch mechanics; they carry no Barrier meaning.
private let oneByteCode: [UInt8] = [0xA1]
private let twoByteCode: [UInt8] = [0xB1, 0xB2]
private let fourByteCode: [UInt8] = [0xC1, 0xC2, 0xC3, 0xC4]

private enum TestMessage: Equatable, Sendable {
  case marker(body: [UInt8])
  case oneByte(body: [UInt8])
  case twoByte(body: [UInt8])
  case fourByte(body: [UInt8])
}

private struct TestDecodeFailure: Error, Equatable {
  let bodyByteCount: Int
}

private typealias TestRegistry = BarrierMessageRegistry<TestMessage, TestDecodeFailure>

private func code(_ bytes: [UInt8]) throws -> BarrierMessageCode {
  try BarrierMessageCode(bytes: bytes)
}

private func syntheticRegistry() throws -> TestRegistry {
  var registry = TestRegistry()
  try registry.register(code(oneByteCode)) { .oneByte(body: $0) }
  try registry.register(code(twoByteCode)) { .twoByte(body: $0) }
  try registry.register(code(fourByteCode)) { .fourByte(body: $0) }
  return registry
}

private func decoded(_ dispatch: BarrierMessageDispatch<TestMessage>) -> TestMessage? {
  if case .decoded(let message) = dispatch { return message }
  return nil
}

private func unknown(
  _ dispatch: BarrierMessageDispatch<TestMessage>
) -> BarrierUnknownMessageDiagnostic? {
  if case .unknown(let diagnostic) = dispatch { return diagnostic }
  return nil
}

// MARK: - Happy path

@Test func dispatchesGoldenPayloadToRegisteredDecoderWithExactBody() throws {
  var registry = TestRegistry()
  try registry.register(code(markerBytes)) { .marker(body: $0) }
  let message = try decoded(registry.decode(goldenPayload))
  #expect(message == .marker(body: versionBytes))
  // Code and body bytes together equal the golden payload exactly.
  guard case .marker(let body) = message else {
    Issue.record("not decoded")
    return
  }
  #expect(markerBytes + body == goldenPayload)
}

@Test func dispatchesEachCodeWidthToItsOwnDecoder() throws {
  let registry = try syntheticRegistry()
  #expect(try decoded(registry.decode(oneByteCode + [0x01])) == .oneByte(body: [0x01]))
  #expect(
    try decoded(registry.decode(twoByteCode + [0x02, 0x03])) == .twoByte(body: [0x02, 0x03])
  )
  #expect(try decoded(registry.decode(fourByteCode + [0x04])) == .fourByte(body: [0x04]))
}

@Test func dispatchDoesNotDependOnRegistrationOrder() throws {
  var reversed = TestRegistry()
  try reversed.register(code(fourByteCode)) { .fourByte(body: $0) }
  try reversed.register(code(twoByteCode)) { .twoByte(body: $0) }
  try reversed.register(code(oneByteCode)) { .oneByte(body: $0) }
  let forward = try syntheticRegistry()
  for payload in [oneByteCode + [0x09], twoByteCode, fourByteCode + [0x00, 0xFF]] {
    #expect(try decoded(forward.decode(payload)) == decoded(reversed.decode(payload)))
  }
}

// MARK: - Boundary

@Test func payloadEqualToCodeDecodesEmptyBody() throws {
  let registry = try syntheticRegistry()
  #expect(try decoded(registry.decode(fourByteCode)) == .fourByte(body: []))
  #expect(try decoded(registry.decode(oneByteCode)) == .oneByte(body: []))
}

@Test func payloadShorterThanCodeIsUnknown() throws {
  var registry = TestRegistry()
  try registry.register(code(fourByteCode)) { .fourByte(body: $0) }
  for length in 0..<fourByteCode.count {
    let diagnostic = try unknown(registry.decode(Array(fourByteCode[..<length])))
    #expect(diagnostic == BarrierUnknownMessageDiagnostic(payloadByteCount: length))
  }
}

@Test func emptyPayloadIsUnknown() throws {
  let registry = try syntheticRegistry()
  #expect(try unknown(registry.decode([])) == BarrierUnknownMessageDiagnostic(payloadByteCount: 0))
}

@Test func emptyRegistryReportsEveryPayloadAsUnknown() throws {
  let registry = TestRegistry()
  #expect(registry.registeredCodeCount == 0)
  let diagnostic = try unknown(registry.decode(goldenPayload))
  #expect(diagnostic == BarrierUnknownMessageDiagnostic(payloadByteCount: goldenPayload.count))
}

@Test func codesDifferingOnlyInLastByteAreBothRegistrable() throws {
  var registry = TestRegistry()
  try registry.register(code([0xD1, 0xD2])) { .twoByte(body: $0) }
  try registry.register(code([0xD1, 0xD3])) { .fourByte(body: $0) }
  #expect(registry.registeredCodeCount == 2)
  #expect(try decoded(registry.decode([0xD1, 0xD2])) == .twoByte(body: []))
  #expect(try decoded(registry.decode([0xD1, 0xD3])) == .fourByte(body: []))
}

// MARK: - Invalid input / failure

@Test func rejectsEmptyCode() {
  #expect(throws: RegistryError.emptyCode) { try BarrierMessageCode(bytes: []) }
}

@Test func rejectsDuplicateCode() throws {
  var registry = try syntheticRegistry()
  #expect(throws: RegistryError.duplicateCode) {
    try registry.register(code(twoByteCode)) { .oneByte(body: $0) }
  }
}

@Test func rejectsCodeThatExtendsRegisteredCode() throws {
  var registry = try syntheticRegistry()
  #expect(throws: RegistryError.ambiguousCode) {
    try registry.register(code(oneByteCode + [0x00])) { .oneByte(body: $0) }
  }
}

@Test func rejectsCodeThatIsPrefixOfRegisteredCode() throws {
  var registry = try syntheticRegistry()
  #expect(throws: RegistryError.ambiguousCode) {
    try registry.register(code(Array(fourByteCode[..<3]))) { .fourByte(body: $0) }
  }
}

@Test func unknownPayloadsNeverReachDecodersAndDoNotCrash() throws {
  var registry = TestRegistry()
  try registry.register(code(fourByteCode)) { _ in
    Issue.record("decoder must not run for an unknown payload")
    return .fourByte(body: [])
  }
  // A near-miss code, the golden payload and a large payload of one repeated byte.
  let payloads: [[UInt8]] = [
    [0xC1, 0xC2, 0xC3, 0x00], goldenPayload, [UInt8](repeating: 0xFF, count: 65_536),
  ]
  for payload in payloads {
    let diagnostic = try unknown(registry.decode(payload))
    #expect(diagnostic == BarrierUnknownMessageDiagnostic(payloadByteCount: payload.count))
  }
}

@Test func unknownDiagnosticCarriesOnlyAllowlistedMetadata() throws {
  let diagnostic = try unknown(TestRegistry().decode(goldenPayload))
  let labels = diagnostic.map { Mirror(reflecting: $0).children.compactMap(\.label) }
  #expect(labels == ["payloadByteCount"])
}

@Test func decoderFailurePropagatesTyped() throws {
  var registry = TestRegistry()
  try registry.register(code(twoByteCode)) { body throws(TestDecodeFailure) in
    throw TestDecodeFailure(bodyByteCount: body.count)
  }
  #expect(throws: TestDecodeFailure(bodyByteCount: 3)) {
    try registry.decode(twoByteCode + [0x00, 0x00, 0x00])
  }
}

// MARK: - Cleanup / idempotency

@Test func failedRegistrationLeavesRegistryUnchanged() throws {
  var registry = try syntheticRegistry()
  for rejected in [twoByteCode, oneByteCode + [0x00], Array(fourByteCode[..<2])] {
    #expect(throws: RegistryError.self) {
      try registry.register(code(rejected)) { _ in .marker(body: []) }
    }
  }
  #expect(registry.registeredCodeCount == 3)
  #expect(try decoded(registry.decode(twoByteCode + [0x01])) == .twoByte(body: [0x01]))
  #expect(try decoded(registry.decode(oneByteCode + [0x00])) == .oneByte(body: [0x00]))
}

@Test func repeatedDecodeReturnsSameOutcome() throws {
  let registry = try syntheticRegistry()
  for payload in [twoByteCode + [0x07], [0xEE, 0xEE]] {
    let first = try registry.decode(payload)
    let second = try registry.decode(payload)
    #expect(decoded(first) == decoded(second))
    #expect(unknown(first) == unknown(second))
  }
  #expect(registry.registeredCodeCount == 3)
}

@Test func decoderFailureDoesNotAffectLaterDispatch() throws {
  var registry = try syntheticRegistry()
  try registry.register(code([0xE1])) { body throws(TestDecodeFailure) in
    throw TestDecodeFailure(bodyByteCount: body.count)
  }
  #expect(throws: TestDecodeFailure(bodyByteCount: 0)) { try registry.decode([0xE1]) }
  #expect(try decoded(registry.decode(oneByteCode)) == .oneByte(body: []))
  #expect(throws: TestDecodeFailure(bodyByteCount: 1)) { try registry.decode([0xE1, 0x00]) }
}

@Test func registeringOnCopyDoesNotChangeOriginal() throws {
  let original = try syntheticRegistry()
  var copy = original
  try copy.register(code([0xF1])) { .marker(body: $0) }
  #expect(original.registeredCodeCount == 3)
  #expect(copy.registeredCodeCount == 4)
  #expect(
    try unknown(original.decode([0xF1])) == BarrierUnknownMessageDiagnostic(payloadByteCount: 1)
  )
  #expect(try decoded(copy.decode([0xF1])) == .marker(body: []))
}

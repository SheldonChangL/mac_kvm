import Testing
@testable import BarrierCompatibility

private typealias HelloError = BarrierServerHelloError

// Golden payload: the first server-to-client frame payload of BARRIER-EVID-0002, the same
// bytes used by BarrierBinaryCodecTests (M1-021), BarrierFrameReassemblerTests (M1-022) and
// BarrierMessageRegistryTests (M1-026).
// Source: evidence/issues/M1-WIRE-001/barrier-frame-conformance.json /derived/runs/0
// (frames/0 lengthPrefixHex 0000000b, payloadOffset 4, payloadEndOffset 15) and
// /derived/markerObservations, /derived/versionByteObservations. Payload = M1-025 marker
// `42 61 72 72 69 65 72` + version `00 01 00 06`
// (docs/adr/M1-025-barrier-client-wire-contract.md). Copied by hand; if that evidence is
// superseded, update these bytes from the superseding artifact.
private let markerBytes: [UInt8] = [0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72]
private let versionBytes: [UInt8] = [0x00, 0x01, 0x00, 0x06]
private let goldenPayload: [UInt8] = [
  0x42, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72, 0x00, 0x01, 0x00, 0x06,
]
private let goldenFrame: [UInt8] = [0x00, 0x00, 0x00, 0x0B] + goldenPayload

// MARK: - Happy path

@Test func parsesGoldenPayloadWithExactBytes() throws {
  let hello = try BarrierServerHello(payload: goldenPayload)
  #expect(hello.markerBytes == markerBytes)
  #expect(hello.versionBytes == versionBytes)
  // The accepted bytes together equal the golden payload exactly.
  #expect(hello.markerBytes + hello.versionBytes == goldenPayload)
}

@Test func frozenConstantsEqualGoldenBytesExactly() {
  #expect(BarrierServerHello.supportedMarkerBytes == markerBytes)
  #expect(BarrierServerHello.supportedVersionBytes == versionBytes)
  #expect(BarrierServerHello.payloadByteCount == goldenPayload.count)
}

@Test func parsesGoldenPayloadReassembledFromByteByByteFragments() throws {
  // Stream-level fragmentation belongs to M1-022; this pins the hand-off: the payload the
  // reassembler yields for a fragmented golden frame is accepted unchanged.
  var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64)
  var payloads: [[UInt8]] = []
  for byte in goldenFrame {
    try reassembler.append([byte])
    while let payload = try reassembler.nextPayload() {
      payloads.append(payload)
    }
  }
  try reassembler.finish()
  #expect(payloads == [goldenPayload])
  let hello = try BarrierServerHello(payload: payloads[0])
  #expect(hello.markerBytes + hello.versionBytes == goldenPayload)
}

// MARK: - Boundary

@Test func payloadLengthIsExactlyMarkerPlusVersion() {
  #expect(BarrierServerHello.supportedMarkerBytes.count == 7)
  #expect(BarrierServerHello.supportedVersionBytes.count == 4)
  #expect(BarrierServerHello.payloadByteCount == 11)
}

@Test func rejectsEmptyPayloadAsTruncatedMarker() {
  #expect(throws: HelloError.truncatedMarker(payloadByteCount: 0)) {
    try BarrierServerHello(payload: [])
  }
}

@Test func rejectsTruncatedMarkerAtEveryLength() {
  for length in 1..<markerBytes.count {
    #expect(throws: HelloError.truncatedMarker(payloadByteCount: length)) {
      try BarrierServerHello(payload: Array(goldenPayload[..<length]))
    }
  }
}

@Test func rejectsTruncatedVersionAtEveryLength() {
  for length in markerBytes.count..<goldenPayload.count {
    #expect(throws: HelloError.truncatedVersion(payloadByteCount: length)) {
      try BarrierServerHello(payload: Array(goldenPayload[..<length]))
    }
  }
}

@Test func rejectsTrailingBytesAfterVersion() {
  for extra in [[0x00], [0x00, 0x00, 0x00, 0x00], [UInt8](repeating: 0xFF, count: 65_536)] {
    let payload = goldenPayload + extra
    #expect(throws: HelloError.unexpectedTrailingBytes(payloadByteCount: payload.count)) {
      try BarrierServerHello(payload: payload)
    }
  }
}

// MARK: - Invalid input / failure

@Test func rejectsEverySingleByteMarkerMutation() {
  for index in markerBytes.indices {
    var payload = goldenPayload
    payload[index] ^= 0x01
    #expect(throws: HelloError.unsupportedMarker) { try BarrierServerHello(payload: payload) }
  }
}

@Test func rejectsEverySingleByteVersionMutation() {
  for index in markerBytes.count..<goldenPayload.count {
    var payload = goldenPayload
    payload[index] ^= 0x01
    #expect(throws: HelloError.unsupportedVersion) { try BarrierServerHello(payload: payload) }
  }
}

@Test func rejectsNeighbouringVersionsWithoutNegotiation() {
  // Exact-supported-version policy: no ranges, downgrade or fallback.
  let versions: [[UInt8]] = [
    [0x00, 0x01, 0x00, 0x05], [0x00, 0x01, 0x00, 0x07], [0x00, 0x02, 0x00, 0x06],
    [0x00, 0x00, 0x00, 0x00], [0xFF, 0xFF, 0xFF, 0xFF],
  ]
  for version in versions {
    #expect(throws: HelloError.unsupportedVersion) {
      try BarrierServerHello(payload: markerBytes + version)
    }
  }
}

@Test func rejectsOtherMarkersIncludingCaseVariants() {
  let markers: [[UInt8]] = [
    [0x62, 0x61, 0x72, 0x72, 0x69, 0x65, 0x72],  // "barrier"
    [0x42, 0x41, 0x52, 0x52, 0x49, 0x45, 0x52],  // "BARRIER"
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
  ]
  for marker in markers {
    #expect(throws: HelloError.unsupportedMarker) {
      try BarrierServerHello(payload: marker + versionBytes)
    }
  }
}

@Test func reportsMismatchBeforeTruncation() {
  // A wrong leading byte fails as unsupported even when the payload is also short, so a
  // foreign variant is never reported as a partial supported hello.
  #expect(throws: HelloError.unsupportedMarker) { try BarrierServerHello(payload: [0x62]) }
  #expect(throws: HelloError.unsupportedVersion) {
    try BarrierServerHello(payload: markerBytes + [0x01])
  }
}

@Test func reportsMarkerMismatchBeforeVersionMismatchOrTrailingBytes() {
  let payload = [0x62] + markerBytes.dropFirst() + [0xFF, 0xFF, 0xFF, 0xFF, 0x00]
  #expect(throws: HelloError.unsupportedMarker) { try BarrierServerHello(payload: payload) }
}

@Test func reportsVersionMismatchBeforeTrailingBytes() {
  let payload = markerBytes + [0x00, 0x01, 0x00, 0x07, 0x00]
  #expect(throws: HelloError.unsupportedVersion) { try BarrierServerHello(payload: payload) }
}

@Test func thrownErrorsCarryOnlyAllowlistedMetadata() {
  // One rejected payload per error case, each containing non-zero bytes.
  let payloads: [[UInt8]] = [
    Array(goldenPayload[..<3]), [0x62] + goldenPayload.dropFirst(),
    Array(goldenPayload[..<9]), markerBytes + [0x00, 0x01, 0x00, 0x07],
    goldenPayload + [0x5A],
  ]
  var errors: [HelloError] = []
  for payload in payloads {
    do throws(HelloError) {
      _ = try BarrierServerHello(payload: payload)
      Issue.record("payload must be rejected")
    } catch {
      errors.append(error)
    }
  }
  #expect(
    errors == [
      .truncatedMarker(payloadByteCount: 3), .unsupportedMarker,
      .truncatedVersion(payloadByteCount: 9), .unsupportedVersion,
      .unexpectedTrailingBytes(payloadByteCount: 12),
    ])
  // An enum case reflects its associated values as one labeled tuple child.
  let associated = errors.flatMap { error in
    Mirror(reflecting: error).children.flatMap { Mirror(reflecting: $0.value).children }
  }
  #expect(associated.count == 3)
  #expect(associated.allSatisfy { $0.label == "payloadByteCount" && $0.value is Int })
}

@Test func helloCarriesOnlyAcceptedMarkerAndVersion() throws {
  let hello = try BarrierServerHello(payload: goldenPayload)
  let labels = Mirror(reflecting: hello).children.compactMap(\.label)
  #expect(labels == ["versionBytes"])
}

// MARK: - Cleanup / idempotency

@Test func repeatedParseReturnsEqualValues() throws {
  let first = try BarrierServerHello(payload: goldenPayload)
  let second = try BarrierServerHello(payload: goldenPayload)
  #expect(first == second)
}

@Test func failedParseDoesNotAffectLaterParse() throws {
  #expect(throws: HelloError.unsupportedVersion) {
    try BarrierServerHello(payload: markerBytes + [0x00, 0x01, 0x00, 0x07])
  }
  #expect(throws: HelloError.truncatedVersion(payloadByteCount: 8)) {
    try BarrierServerHello(payload: Array(goldenPayload[..<8]))
  }
  let hello = try BarrierServerHello(payload: goldenPayload)
  #expect(hello.markerBytes + hello.versionBytes == goldenPayload)
}

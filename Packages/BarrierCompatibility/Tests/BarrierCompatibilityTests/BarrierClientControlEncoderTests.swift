import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

// M1-029-FOLLOWUP-001: the client-role control encoder. The DINF and CALV bytes are copied by
// hand from docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md (BARRIER-EVID-0005)
// and docs/components/M1-031-barrier-control-messages.md; the capture-screen DINF, the CCLP and
// the client DCLP transfer are also compared with the M2-022 captures in Tests/Fixtures/Barrier/
// (BARRIER-EVID-0006 to 0008), read from the fixture files.

private typealias Encoder = BarrierClientControlEncoder

/// The M1-031 golden DINF: origin (-1920, 0), 3648 x 1117, reserved 0, cursor (772, 594).
private let goldenDinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0xF8, 0x80, 0x00, 0x00, 0x0E, 0x40, 0x04, 0x5D,
  0x00, 0x00, 0x03, 0x04, 0x02, 0x52,
]
private let goldenScreen = BarrierScreenInfo(
  originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)

/// The client DINF of every M2-022 capture: origin (0, 0), 1600 x 900, cursor (800, 450).
private let captureDinf: [UInt8] = [
  0x00, 0x00, 0x00, 0x12, 0x44, 0x49, 0x4E, 0x46, 0x00, 0x00, 0x00, 0x00, 0x06, 0x40, 0x03, 0x84,
  0x00, 0x00, 0x03, 0x20, 0x01, 0xC2,
]
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

private let calv: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]
/// The client CCLP of the M2-022 clipboard captures: clipboard 0, the sequence of `CINN` 1.
private let capturedCclp: [UInt8] = [
  0x00, 0x00, 0x00, 0x09, 0x43, 0x43, 0x4C, 0x50, 0x00, 0x00, 0x00, 0x00, 0x01,
]

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// The fixture's frames in capture order with their direction.
private func capturedFrames(
  _ fixture: String
) throws -> [(clientToServer: Bool, bytes: [UInt8])] {
  let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  return try observations.map { observation in
    let direction = try #require(observation["direction"] as? String)
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    let bytes = [UInt8](try #require(Data(base64Encoded: base64)))
    return (direction == "client-to-server", bytes)
  }
}

private func token(_ frame: [UInt8]) -> String {
  String(decoding: frame.dropFirst(4).prefix(4), as: UTF8.self)
}

private func decodeAsClient(_ frame: [UInt8]) throws -> BarrierControlOutcome {
  var decoder = try BarrierControlDecoder(maximumPayloadLength: 4096)
  return try decoder.decode(payload: Array(frame.dropFirst(4)), direction: .clientToServer)
}

private func be32(_ value: UInt32) -> [UInt8] {
  [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
}

@Suite("M1-029-FOLLOWUP-001 BarrierClientControlEncoder")
struct BarrierClientControlEncoderTests {
  @Test func screenInfoWritesTheM1031GoldenFrame() {
    #expect(Encoder.screenInfo(goldenScreen) == goldenDinf)
  }

  @Test func screenInfoOfTheCaptureScreenEqualsEveryCapturedClientDinf() throws {
    #expect(Encoder.screenInfo(captureScreen) == captureDinf)
    let fixtures = [
      "m2-022-linux-server-input/server-input-capture.json",
      "m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json",
      "m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json",
    ]
    for fixture in fixtures {
      let dinfs = try capturedFrames(fixture).filter {
        $0.clientToServer && token($0.bytes) == "DINF"
      }
      #expect(dinfs.map(\.bytes) == [captureDinf], "\(fixture)")
    }
  }

  @Test func screenInfoIsTheExactInverseOfTheFrozenParse() throws {
    let screens = [
      goldenScreen, captureScreen,
      BarrierScreenInfo(originX: 0, originY: 0, width: 1, height: 1, cursorX: 0, cursorY: 0),
      BarrierScreenInfo(
        originX: 0, originY: 0, width: 0x7FFF, height: 0x7FFF, cursorX: 0x7FFE, cursorY: 0x7FFE),
      BarrierScreenInfo(
        originX: -16384, originY: 100, width: 0x7FFF, height: 200, cursorX: 0, cursorY: 100),
      BarrierScreenInfo(originX: 10, originY: 20, width: 30, height: 40, cursorX: 39, cursorY: 59),
    ]
    for screen in screens {
      let frame = Encoder.screenInfo(screen)
      try #require(frame.count == 22)
      #expect(Array(frame.prefix(8)) == Array(goldenDinf.prefix(8)))
      #expect(Array(frame[16..<18]) == [0x00, 0x00], "the reserved field is written as zero")
      #expect(try decodeAsClient(frame) == .event(.screenInfo(screen)))
    }
    // The origin is signed: the extremes keep their bit patterns.
    let extremes = Encoder.screenInfo(
      BarrierScreenInfo(
        originX: -32768, originY: 32767, width: 1, height: 1, cursorX: 0, cursorY: 0))
    try #require(extremes.count == 22)
    #expect(Array(extremes[8..<12]) == [0x80, 0x00, 0x7F, 0xFF])
  }

  @Test func keepaliveIsTheTokenOnlyCalvAndDecodesAsAClientKeepalive() throws {
    #expect(Encoder.keepalive() == calv)
    #expect(try decodeAsClient(Encoder.keepalive()) == .keepalive(.keepalive(.clientToServer)))
  }

  @Test func clipboardOwnershipCarriesTheIdAndTheSequence() throws {
    #expect(Encoder.clipboardOwnership(id: 0, sequence: 1) == capturedCclp)
    let captured = try capturedFrames(
      "m2-022-linux-client-clipboard-keepalive/client-clipboard-keepalive-capture.json")
    #expect(captured.filter { token($0.bytes) == "CCLP" }.map(\.bytes) == [capturedCclp])
    #expect(
      Encoder.clipboardOwnership(id: 1, sequence: 0x0102_0304)
        == [0x00, 0x00, 0x00, 0x09, 0x43, 0x43, 0x4C, 0x50, 0x01, 0x01, 0x02, 0x03, 0x04])
    #expect(Encoder.clipboardOwnershipToken == Array("CCLP".utf8))
  }

  @Test func clipboardTransferEqualsTheCapturedClientFramesByteForByte() throws {
    // BARRIER-EVID-0008: after the copy the client sent CCLP, then (after COUT) a DCLP start,
    // one chunk and an end for clipboard 0 with the sequence of the CINN in force (1). The
    // chunk's content bytes are zero-filled by the fixture's sanitization; its layout is kept.
    let frames = try capturedFrames(
      "m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json"
    ).filter { $0.clientToServer && ["CCLP", "DCLP"].contains(token($0.bytes)) }.map(\.bytes)
    #expect(frames.count == 4)
    let chunk = try #require(frames.dropFirst(2).first)
    let data = Array(chunk.dropFirst(18))
    #expect(data.count == 119)
    #expect(Encoder.clipboard(marshalled: data, sequence: 1) == frames.flatMap { $0 })
  }

  @Test func clipboardTransferOfTextReassemblesWithTheSequenceOfTheEnter() throws {
    let texts = ["", "probe \u{2713}", String(repeating: "y", count: 600_001)]
    for text in texts {
      let sequence: UInt32 = 0x0001_0003
      let bytes = Encoder.clipboard(
        marshalled: BarrierClipboard.marshal(text: text), sequence: sequence)
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: 64 * 1024)
      try reassembler.append(bytes)
      var payloads: [[UInt8]] = []
      while let payload = try reassembler.nextPayload() { payloads.append(payload) }
      let ownership = try #require(payloads.first)
      #expect(ownership == Array("CCLP".utf8) + [0] + be32(sequence))
      var assembler = BarrierClipboardAssembler(limit: 4 << 20)
      var transfers: [BarrierClipboardTransfer] = []
      for payload in payloads.dropFirst() {
        #expect(Array(payload.prefix(4)) == Array("DCLP".utf8))
        #expect(payload.count <= 14 + 32 * 1024, "chunks of at most 32 KiB")
        if let transfer = try assembler.receive(payload: payload) { transfers.append(transfer) }
      }
      #expect(transfers.count == 1)
      #expect(transfers.first?.id == 0)
      #expect(transfers.first?.sequence == sequence)
      #expect(
        try transfers.first.flatMap { try BarrierClipboard.text(fromMarshalled: $0.data) } == text)
    }
  }
}

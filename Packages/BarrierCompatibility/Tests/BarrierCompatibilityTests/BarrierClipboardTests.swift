import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// The `DCLP` frames of the M2-022 punctuation and clipboard capture sent in
/// `direction`, in order. Clipboard content is zero-filled by the fixture.
private func capturedClipboardFrames(_ direction: String) throws -> [[UInt8]] {
  let url = repositoryRoot().appendingPathComponent(
    "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: [[UInt8]] = []
  for observation in observations where observation["direction"] as? String == direction {
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    let frame = [UInt8](try #require(Data(base64Encoded: base64)))
    if frame.dropFirst(4).prefix(4).elementsEqual("DCLP".utf8) { frames.append(frame) }
  }
  return frames
}

/// The data string of a `DCLP` frame: after the length, code, id, sequence,
/// mark and the string's own length.
private func dataString(_ frame: [UInt8]) -> [UInt8] {
  Array(frame.dropFirst(18))
}

/// Feeds whole frames to `assembler` and returns the last completed transfer.
private func assemble(
  _ frames: [[UInt8]], into assembler: inout BarrierClipboardAssembler
) throws -> BarrierClipboardTransfer? {
  var completed: BarrierClipboardTransfer?
  for frame in frames {
    if let transfer = try assembler.receive(payload: Array(frame.dropFirst(4))) {
      completed = transfer
    }
  }
  return completed
}

@Suite("M2-028 Barrier clipboard transfer")
struct BarrierClipboardTests {
  @Test("framing equals the captured server-to-client transfer of both clipboard ids")
  func serverFramingMatchesCapture() throws {
    let frames = try capturedClipboardFrames("server-to-client")
    #expect(frames.count == 6)
    let clipboard = BarrierClipboard.frames(id: 0, sequence: 0, data: dataString(frames[1]))
    #expect(clipboard == Array(frames[0...2]))
    let selection = BarrierClipboard.frames(id: 1, sequence: 0, data: dataString(frames[4]))
    #expect(selection == Array(frames[3...5]))
  }

  @Test("the assembler rebuilds the captured client-to-server transfer")
  func clientTransferAssembles() throws {
    let frames = try capturedClipboardFrames("client-to-server")
    #expect(frames.count == 3)
    var assembler = BarrierClipboardAssembler(limit: 1 << 20)
    let transfer = try #require(try assemble(frames, into: &assembler))
    #expect(transfer.id == 0)
    #expect(transfer.sequence == 1)
    #expect(transfer.data == dataString(frames[1]))
    // Text, HTML and bitmap formats; the text content is zero-filled.
    #expect(
      try BarrierClipboard.text(fromMarshalled: transfer.data) == String(repeating: "\0", count: 37)
    )
  }

  @Test("text is marshalled as the only format and round-trips through chunked frames")
  func textRoundTrip() throws {
    let text = "mackvm \u{2713} caf\u{E9} \u{4E2D}\u{6587}\nline 2"
    let data = BarrierClipboard.marshal(text: text)
    let length = UInt32(text.utf8.count)
    #expect(Array(data.prefix(8)) == [0, 0, 0, 1, 0, 0, 0, 0])
    #expect(Array(data[8..<12]) == [0, 0, UInt8(length >> 8), UInt8(length & 0xFF)])
    #expect(try BarrierClipboard.text(fromMarshalled: data) == text)

    let frames = BarrierClipboard.frames(id: 0, sequence: 3, data: data, chunkSize: 7)
    #expect(frames.count == 2 + (data.count + 6) / 7)
    var assembler = BarrierClipboardAssembler(limit: 1 << 20)
    let transfer = try #require(try assemble(frames, into: &assembler))
    #expect(transfer.data == data)
    #expect(transfer.sequence == 3)
  }

  @Test("text is decoded byte for byte, keeping a leading byte order mark")
  func byteFaithfulText() throws {
    let text = "\u{FEFF}probe"
    let decoded = try #require(
      try BarrierClipboard.text(fromMarshalled: BarrierClipboard.marshal(text: text)))
    #expect(Array(decoded.utf8) == Array(text.utf8))
  }

  @Test("a clipboard without a text format yields no text")
  func noText() throws {
    #expect(try BarrierClipboard.text(fromMarshalled: [0, 0, 0, 0]) == nil)
    let htmlOnly: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0x41]
    #expect(try BarrierClipboard.text(fromMarshalled: htmlOnly) == nil)
  }

  @Test("malformed marshalled data is rejected")
  func malformedData() {
    let cases: [[UInt8]] = [
      [0, 0, 0],
      [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 9, 0x41],
      [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0xFF],
      [0, 0, 0, 0, 0x41],
      [0x7F, 0xFF, 0xFF, 0xFF],
    ]
    for data in cases {
      #expect(throws: BarrierClipboardError.malformed) {
        try BarrierClipboard.text(fromMarshalled: data)
      }
    }
  }

  @Test("oversized, out-of-order and short transfers are rejected without output")
  func malformedTransfers() throws {
    let data = BarrierClipboard.marshal(text: "probe")
    let frames = BarrierClipboard.frames(id: 0, sequence: 1, data: data)
    let start = Array(frames[0].dropFirst(4))
    let chunk = Array(frames[1].dropFirst(4))
    let end = Array(frames[2].dropFirst(4))

    var small = BarrierClipboardAssembler(limit: data.count - 1)
    #expect(throws: BarrierClipboardError.oversized) { try small.receive(payload: start) }

    var orphan = BarrierClipboardAssembler(limit: 1 << 20)
    #expect(throws: BarrierClipboardError.malformed) { try orphan.receive(payload: chunk) }

    var short = BarrierClipboardAssembler(limit: 1 << 20)
    _ = try short.receive(payload: start)
    #expect(throws: BarrierClipboardError.malformed) { try short.receive(payload: end) }

    var long = BarrierClipboardAssembler(limit: 1 << 20)
    _ = try long.receive(payload: start)
    _ = try long.receive(payload: chunk)
    #expect(throws: BarrierClipboardError.malformed) { try long.receive(payload: chunk) }

    // After a rejection the next complete transfer still assembles.
    #expect(try assemble(frames, into: &long)?.data == data)
  }

  @Test("sequence, mark, length and size-string violations are rejected; a new start replaces")
  func malformedFrames() throws {
    let data = BarrierClipboard.marshal(text: "probe")
    let frames = BarrierClipboard.frames(id: 0, sequence: 1, data: data).map {
      Array($0.dropFirst(4))
    }
    let other = BarrierClipboard.frames(id: 0, sequence: 2, data: data).map {
      Array($0.dropFirst(4))
    }

    var chunkSequence = BarrierClipboardAssembler(limit: 1 << 20)
    _ = try chunkSequence.receive(payload: frames[0])
    #expect(throws: BarrierClipboardError.malformed) {
      try chunkSequence.receive(payload: other[1])
    }

    var endSequence = BarrierClipboardAssembler(limit: 1 << 20)
    _ = try endSequence.receive(payload: frames[0])
    _ = try endSequence.receive(payload: frames[1])
    #expect(throws: BarrierClipboardError.malformed) { try endSequence.receive(payload: other[2]) }

    for mark: UInt8 in [0, 4] {
      var badMark = BarrierClipboardAssembler(limit: 1 << 20)
      var frame = frames[0]
      frame[9] = mark
      #expect(throws: BarrierClipboardError.malformed) { try badMark.receive(payload: frame) }
    }

    var badLength = BarrierClipboardAssembler(limit: 1 << 20)
    #expect(throws: BarrierClipboardError.malformed) {
      try badLength.receive(payload: frames[1] + [0])
    }

    let header = Array(frames[0].prefix(10))
    for size in ["12a", "12345678901", ""] {
      var badSize = BarrierClipboardAssembler(limit: 1 << 20)
      let string = Array(size.utf8)
      let start = header + [0, 0, 0, UInt8(string.count)] + string
      #expect(throws: BarrierClipboardError.malformed) { try badSize.receive(payload: start) }
    }

    var restart = BarrierClipboardAssembler(limit: 1 << 20)
    _ = try restart.receive(payload: frames[0])
    _ = try restart.receive(payload: frames[1])
    _ = try restart.receive(payload: other[0])
    _ = try restart.receive(payload: other[1])
    let transfer = try #require(try restart.receive(payload: other[2]))
    #expect(transfer.sequence == 2)
    #expect(transfer.data == data)
  }
}

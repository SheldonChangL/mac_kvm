import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

// Golden frames copied by hand from the M2-022 server-role capture
// (Tests/Fixtures/Barrier/m2-022-linux-server-input/, decoded in
// evidence/e2e/M2-022/README.md): a 1600 x 900 client entered at (0, 450) with
// sequence 1, left, then entered again with sequence 3, mask 0 both times.
private let goldenFirstCINN: [UInt8] = [
  0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E, 0x00, 0x00, 0x01, 0xC2, 0x00, 0x00, 0x00, 0x01,
  0x00, 0x00,
]
private let goldenSecondCINN: [UInt8] = [
  0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E, 0x00, 0x00, 0x01, 0xC2, 0x00, 0x00, 0x00, 0x03,
  0x00, 0x00,
]
private let goldenCOUT: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4F, 0x55, 0x54]
private let goldenCALV: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]

private let screen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1921, height: 1081, cursorX: 0, cursorY: 0)
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)
private let negativeOrigin = BarrierScreenInfo(
  originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)

private typealias EncoderError = BarrierClipboardControlEncoderError

@Suite("M2-028 BarrierClipboardControlEncoder")
struct BarrierClipboardControlEncoderTests {
  @Test("enter, leave and enter again match the captured CINN and COUT frames")
  func goldenEnterSequence() throws {
    var encoder = BarrierClipboardControlEncoder(screen: captureScreen)
    #expect(try encoder.enter(x: 0, y: 450) == goldenFirstCINN)
    #expect(encoder.leave() == goldenCOUT)
    #expect(try encoder.enter(x: 0, y: 450) == goldenSecondCINN)
  }

  @Test("enter at a normalized position maps into the client rectangle")
  func normalizedEnter() throws {
    var encoder = BarrierClipboardControlEncoder(screen: screen)
    let frame = try encoder.enter(position: NormalizedPoint(x: 0.5, y: 0.25))
    #expect(Array(frame[8..<12]) == [0x03, 0xC0, 0x01, 0x0E])
    #expect(Array(frame[12...]) == [0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
  }

  @Test("leave and keepalive match the golden token frames")
  func tokens() {
    var encoder = BarrierClipboardControlEncoder(screen: screen)
    #expect(encoder.leave() == goldenCOUT)
    #expect(encoder.keepalive() == goldenCALV)
  }

  @Test("the sequence advances on every enter and leave; a failed enter consumes nothing")
  func sequenceAdvances() throws {
    var encoder = BarrierClipboardControlEncoder(screen: screen)
    #expect(throws: EncoderError.coordinateOutsideScreen) { try encoder.enter(x: 5000, y: 1) }
    #expect(Array(try encoder.enter(x: 1, y: 1)[12..<16]) == [0, 0, 0, 1])
    _ = encoder.leave()
    #expect(Array(try encoder.enter(x: 1, y: 1)[12..<16]) == [0, 0, 0, 3])
    _ = encoder.leave()
    _ = encoder.leave()
    #expect(Array(try encoder.enter(x: 1, y: 1)[12..<16]) == [0, 0, 0, 6])
  }

  @Test("boundary: coordinates outside the rectangle or the raw range fail closed")
  func coordinates() throws {
    var outside = BarrierClipboardControlEncoder(screen: screen)
    #expect(throws: EncoderError.coordinateOutsideScreen) { try outside.enter(x: 1921, y: 0) }
    #expect(throws: EncoderError.coordinateOutsideScreen) { try outside.enter(x: 0, y: 1081) }
    #expect(try outside.enter(x: 1920, y: 1080).count == goldenFirstCINN.count)

    var negative = BarrierClipboardControlEncoder(screen: negativeOrigin)
    #expect(throws: EncoderError.coordinateOutOfRange) {
      try negative.enter(position: NormalizedPoint(x: 0, y: 0.5))
    }
    var failed = BarrierClipboardControlEncoder(screen: screen)
    #expect(throws: EncoderError.coordinateOutsideScreen) { try failed.enter(x: 5000, y: 0) }
    #expect(try failed.enter(x: 0, y: 0).count == goldenFirstCINN.count)
  }

  @Test("clipboard is unsupported and emits no bytes, even within the size limit")
  func clipboardUnsupported() throws {
    let encoder = BarrierClipboardControlEncoder(screen: screen)
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: "m2-028-probe",
      contentHash: "hash")
    let limit = try #require(ClipboardByteLimit(byteCount: 1024))
    #expect(throws: EncoderError.clipboardWireContractNotFrozen) {
      try encoder.clipboard(payload, limit: limit)
    }
    let small = try #require(ClipboardByteLimit(byteCount: 2))
    #expect(throws: EncoderError.clipboardOversized) {
      try encoder.clipboard(payload, limit: small)
    }
    do {
      try encoder.clipboard(payload, limit: limit)
    } catch {
      #expect(!String(describing: error).contains("m2-028-probe"))
    }
  }
}

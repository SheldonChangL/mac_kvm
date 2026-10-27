import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

// Golden frames, copied by hand from BARRIER-EVID-0005
// (docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md); the server
// role reuses them under the proposed docs/adr/M2-023.
private let goldenCINN: [UInt8] = [
  0x00, 0x00, 0x00, 0x0E, 0x43, 0x49, 0x4E, 0x4E, 0x03, 0x04, 0x02, 0x52, 0x00, 0x00, 0x00, 0x01,
  0x20, 0x00,
]
private let goldenCOUT: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x4F, 0x55, 0x54]
private let goldenCALV: [UInt8] = [0x00, 0x00, 0x00, 0x04, 0x43, 0x41, 0x4C, 0x56]

private let screen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1921, height: 1081, cursorX: 0, cursorY: 0)
private let negativeOrigin = BarrierScreenInfo(
  originX: -1920, originY: 0, width: 3648, height: 1117, cursorX: 772, cursorY: 594)

private typealias EncoderError = BarrierClipboardControlEncoderError

@Suite("M2-028 BarrierClipboardControlEncoder")
struct BarrierClipboardControlEncoderTests {
  @Test("enter at a raw coordinate matches the golden CINN frame")
  func goldenEnter() throws {
    var encoder = BarrierClipboardControlEncoder(screen: negativeOrigin)
    #expect(try encoder.enter(x: 772, y: 594) == goldenCINN)
  }

  @Test("enter at a normalized position maps into the client rectangle")
  func normalizedEnter() throws {
    var encoder = BarrierClipboardControlEncoder(screen: screen)
    let frame = try encoder.enter(position: NormalizedPoint(x: 0.5, y: 0.25))
    #expect(Array(frame[8..<12]) == [0x03, 0xC0, 0x01, 0x0E])
    #expect(Array(frame[12...]) == [0x00, 0x00, 0x00, 0x01, 0x20, 0x00])
  }

  @Test("leave and keepalive match the golden token frames")
  func tokens() {
    let encoder = BarrierClipboardControlEncoder(screen: screen)
    #expect(encoder.leave() == goldenCOUT)
    #expect(encoder.keepalive() == goldenCALV)
  }

  @Test("only one enter per session is supported; later enters fail closed")
  func singleEnter() throws {
    var encoder = BarrierClipboardControlEncoder(screen: screen)
    _ = try encoder.enter(x: 1, y: 1)
    #expect(throws: EncoderError.repeatedEnterUnsupported) { try encoder.enter(x: 1, y: 1) }
    #expect(encoder.leave() == goldenCOUT)
    #expect(throws: EncoderError.repeatedEnterUnsupported) { try encoder.enter(x: 2, y: 2) }
  }

  @Test("boundary: coordinates outside the rectangle or the raw range fail closed")
  func coordinates() throws {
    var outside = BarrierClipboardControlEncoder(screen: screen)
    #expect(throws: EncoderError.coordinateOutsideScreen) { try outside.enter(x: 1921, y: 0) }
    #expect(throws: EncoderError.coordinateOutsideScreen) { try outside.enter(x: 0, y: 1081) }
    #expect(try outside.enter(x: 1920, y: 1080).count == goldenCINN.count)

    var negative = BarrierClipboardControlEncoder(screen: negativeOrigin)
    #expect(throws: EncoderError.coordinateOutOfRange) {
      try negative.enter(position: NormalizedPoint(x: 0, y: 0.5))
    }
    var failed = BarrierClipboardControlEncoder(screen: screen)
    #expect(throws: EncoderError.coordinateOutsideScreen) { try failed.enter(x: 5000, y: 0) }
    #expect(try failed.enter(x: 0, y: 0).count == goldenCINN.count)
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

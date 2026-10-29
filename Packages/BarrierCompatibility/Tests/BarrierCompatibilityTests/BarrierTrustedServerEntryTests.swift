import Testing

@testable import BarrierCompatibility

@Suite("M2 Barrier trusted-server entry")
struct BarrierTrustedServerEntryTests {
  @Test("a SHA-256 digest becomes one lowercase v2 trust-list line")
  func line() {
    let digest = (0..<32).map { UInt8($0 * 8) }
    #expect(
      BarrierTrustedServerEntry.line(sha256: digest)
        == "v2:sha256:0008101820283038404850586068707880889098" + "a0a8b0b8c0c8d0d8e0e8f0f8")
  }

  @Test("any other digest length produces no line")
  func wrongLength() {
    #expect(BarrierTrustedServerEntry.line(sha256: []) == nil)
    #expect(BarrierTrustedServerEntry.line(sha256: Array(repeating: 0xAB, count: 31)) == nil)
    #expect(BarrierTrustedServerEntry.line(sha256: Array(repeating: 0xAB, count: 33)) == nil)
  }
}

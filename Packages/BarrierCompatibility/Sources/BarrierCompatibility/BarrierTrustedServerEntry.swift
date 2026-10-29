// Barrier client trust-list entry for the server certificate (M2). A Barrier 2.4
// client pins its server by the SHA-256 of the certificate DER and reads
// `SSL/Fingerprints/TrustedServers.txt` in its profile directory, one
// `v2:sha256:<lowercase hex>` line per trusted server (format observed on the
// Linux test client, 2026-10-28).

/// Formats the trusted-server line a Barrier client needs to accept this server.
package enum BarrierTrustedServerEntry {
  private static let digestByteCount = 32
  private static let hexDigits = Array("0123456789abcdef")

  /// The trust-list line for a 32-byte SHA-256 digest, or `nil` for any other
  /// length.
  package static func line(sha256 digest: [UInt8]) -> String? {
    guard digest.count == digestByteCount else { return nil }
    let hex = digest.map { String([hexDigits[Int($0 >> 4)], hexDigits[Int($0 & 0x0F)]]) }
    return "v2:sha256:" + hex.joined()
  }
}

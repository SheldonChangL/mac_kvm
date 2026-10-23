import CryptoKit
import Foundation

/// Why a certificate fingerprint operation produced no value.
///
/// The reasons are closed and carry no payload, so a failure can be reported
/// or rendered without ever exposing certificate or digest bytes, or their
/// length.
enum CertificateFingerprintFailure: String, Error, Equatable, Sendable, CaseIterable {
  /// The certificate DER was empty. Hashing zero bytes would produce a
  /// well-defined digest that identifies no certificate, so it is refused.
  case emptyCertificate

  /// A digest handed to the formatter was not exactly
  /// `CertificateFingerprint.sha256DigestLength` bytes.
  case invalidDigestLength
}

/// Computes the SHA-256 fingerprint of a certificate's DER bytes and renders a
/// digest for people to read.
///
/// The two operations are deliberately separate. `sha256Digest` returns the raw
/// 32-byte digest, which is the value a trust store compares;
/// `canonicalDisplay` only formats an existing digest as uppercase hex pairs
/// joined by colons. Formatting never hashes and hashing never formats.
///
/// Nothing here decides trust. Accepting, prompting for, or rejecting a peer
/// belongs to the trust policy, which consumes these values. The DER is never
/// parsed, so which certificate of a chain to fingerprint is the caller's
/// choice.
///
/// The type is a caseless enum: it has no instances and no stored state, owns
/// no task, stream, file or other resource, and each call derives its result
/// only from its argument. There is therefore nothing to cancel and nothing to
/// clean up, and calls are safe from any thread.
enum CertificateFingerprint {
  /// The length in bytes of a SHA-256 digest.
  static let sha256DigestLength = 32

  /// Returns the SHA-256 digest of `der`, or `.emptyCertificate` if it has no
  /// bytes.
  ///
  /// `der` may be a slice with a non-zero start index; only its own bytes are
  /// hashed.
  static func sha256Digest(
    ofCertificateDER der: Data
  ) -> Result<Data, CertificateFingerprintFailure> {
    guard !der.isEmpty else { return .failure(.emptyCertificate) }
    return .success(Data(SHA256.hash(data: der)))
  }

  /// Returns `digest` as 32 uppercase two-digit hex groups joined by single
  /// colons, or `.invalidDigestLength` if it is not exactly
  /// `sha256DigestLength` bytes.
  ///
  /// `digest` may be a slice with a non-zero start index; only its own bytes
  /// are formatted.
  static func canonicalDisplay(
    ofSHA256Digest digest: Data
  ) -> Result<String, CertificateFingerprintFailure> {
    guard digest.count == sha256DigestLength else { return .failure(.invalidDigestLength) }
    let groups = digest.map { byte in
      String([hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]])
    }
    return .success(groups.joined(separator: ":"))
  }

  /// Uppercase hex digits indexed by nibble value. A fixed table keeps the
  /// output independent of locale and of any formatting API.
  private static let hexDigits: [Character] = Array("0123456789ABCDEF")
}

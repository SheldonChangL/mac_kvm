import Foundation
import KVMContracts

/// What the caller already knows about a peer identity.
///
/// The caller owns this value and where it comes from. A trusted state carries
/// the raw SHA-256 digest of the certificate that was trusted, never its
/// display text.
enum TrustPolicyState: Equatable, Sendable {
  /// No trust decision has been recorded for this peer.
  case unknown

  /// The peer was trusted with exactly `fingerprint`, a raw
  /// `CertificateFingerprint.sha256DigestLength`-byte digest.
  case trusted(fingerprint: Data)

  /// Trust in this peer was withdrawn. No fingerprint revives it.
  case revoked
}

/// What the C-009 trust policy concluded.
///
/// The cases carry no fingerprint, so a decision can be reported or rendered
/// without exposing digest bytes.
enum TrustPolicyDecision: Equatable, Sendable {
  /// The identity is unknown. The caller must ask a person; this is not an
  /// acceptance and must never be treated as one.
  case prompt

  /// The presented fingerprint equals the one already trusted.
  case allow

  /// The connection must not proceed, for the given reason.
  case reject(SecurityErrorCode)
}

/// The C-009 trust decision: unknown prompts, trusted with the same
/// fingerprint allows, a changed or revoked identity rejects, and nothing is
/// ever accepted automatically.
///
/// Both fingerprints must be raw digests of exactly
/// `CertificateFingerprint.sha256DigestLength` bytes. Precedence, highest
/// first:
///
/// 1. A presented fingerprint of any other length rejects with
///    `.trustRejected`, whatever the state.
/// 2. A trusted state whose stored fingerprint has any other length rejects
///    with `.trustRejected`, even when the bytes compare equal.
/// 3. `.unknown` prompts; `.trusted` allows on an exact byte match and
///    otherwise rejects with `.identityChanged`; `.revoked` rejects with
///    `.identityRevoked`.
///
/// The policy only decides. It never stores, prompts, logs, formats a
/// fingerprint, or picks a certificate out of a chain; the caller owns the
/// state, the presented digest and whatever happens after `.prompt`.
///
/// The type is a caseless enum with no stored state, and `decide` derives its
/// result only from its arguments. It owns no task or resource, so there is
/// nothing to cancel or clean up, and calls are safe from any thread.
enum TrustPolicy {
  /// Returns the decision for a peer presenting `presentedFingerprint` when
  /// the caller's recorded knowledge of it is `state`.
  ///
  /// Either fingerprint may be a slice with a non-zero start index; only its
  /// own bytes are compared.
  static func decide(
    state: TrustPolicyState,
    presentedFingerprint: Data
  ) -> TrustPolicyDecision {
    guard isSHA256Digest(presentedFingerprint) else { return .reject(.trustRejected) }
    switch state {
    case .unknown:
      return .prompt
    case .trusted(let storedFingerprint):
      guard isSHA256Digest(storedFingerprint) else { return .reject(.trustRejected) }
      return storedFingerprint == presentedFingerprint ? .allow : .reject(.identityChanged)
    case .revoked:
      return .reject(.identityRevoked)
    }
  }

  private static func isSHA256Digest(_ fingerprint: Data) -> Bool {
    fingerprint.count == CertificateFingerprint.sha256DigestLength
  }
}

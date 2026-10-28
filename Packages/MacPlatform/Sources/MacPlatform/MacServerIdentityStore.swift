// Keychain-backed TLS identity for the Barrier server role (M2; owner decision
// 2026-10-28: a self-signed certificate generated on first launch, the private key
// only in the Keychain). The P-256 key is generated inside the Keychain as a
// permanent, non-extractable item and is only ever referenced. M2 uses the
// file-based login Keychain: the M2 server is an unbundled executable, and the
// data-protection Keychain refuses a process without a provisioned app identity
// (M1-058 manual evidence D-1..D-3). Moving to the data-protection Keychain
// belongs with the signed app bundle.

import CryptoKit
import Foundation
import Security

/// Why no server identity is available. Carries no key, certificate or
/// platform diagnostic.
package enum MacServerIdentityFailure: Error, Equatable, Sendable {
  /// A Keychain operation failed or the Keychain is unavailable, for example
  /// locked. Nothing was deleted because of it.
  case secureStorageUnavailable
  /// More than one certificate carries the identity label; none is chosen.
  case ambiguousIdentity
  /// The certificate could not be generated or signed.
  case certificateGenerationFailed
}

/// The server's TLS identity and the fingerprint a Barrier client pins.
///
/// `SecIdentity` is an immutable Security object that is safe to share across
/// threads, hence `@unchecked Sendable`.
package struct MacServerIdentity: @unchecked Sendable {
  let secIdentity: SecIdentity
  /// SHA-256 of the certificate DER.
  package let certificateSHA256: Data
}

/// Loads the server identity, creating it on first use.
///
/// One identity per label: one private key tagged with a value derived from
/// `label`, and the one certificate whose public-key hash matches it. The
/// file-based Keychain names a certificate after its subject and ignores a
/// requested label, so certificates are found through the key, never by label.
/// A key without a certificate is left over from an interrupted creation; it is
/// removed and a new identity is created, whose fingerprint must be trusted
/// again. A certificate whose key is gone is unreachable and is not reused.
/// More than one key or certificate fails closed, and so does any other
/// Keychain failure, without deleting anything.
package struct MacServerIdentityStore: Sendable {
  package static let productionLabel = "MacKVM Barrier Server Identity"
  static let commonName = "MacKVM Barrier Server"
  /// Ten years. Barrier clients pin the certificate and do not check dates, so
  /// a short lifetime would only force needless re-trust.
  static let lifetime: TimeInterval = 10 * 365 * 24 * 60 * 60
  /// Upper bound on delete calls for one query, in case the Keychain deletes
  /// one match per call.
  private static let maximumDeletePasses = 16

  let label: String

  package init(label: String = productionLabel) {
    self.label = label
  }

  private var applicationTag: Data { Data("mackvm.server-identity:\(label)".utf8) }

  package func loadOrCreate(now: Date = Date()) throws(MacServerIdentityFailure)
    -> MacServerIdentity
  {
    let keyHashes = try findKeyHashes()
    guard keyHashes.count <= 1 else { throw .ambiguousIdentity }
    guard let keyHash = keyHashes.first else { return try create(now: now) }
    let certificates = try findCertificates(publicKeyHash: keyHash)
    guard certificates.count <= 1 else { throw .ambiguousIdentity }
    guard let certificate = certificates.first else {
      try remove()
      return try create(now: now)
    }
    guard case .success(let identity) = identity(for: certificate) else {
      throw .secureStorageUnavailable
    }
    return identity
  }

  /// Deletes the private key and every certificate for it. Succeeds when
  /// nothing is stored.
  package func remove() throws(MacServerIdentityFailure) {
    for keyHash in try findKeyHashes() {
      try deleteAll(certificateQuery(publicKeyHash: keyHash))
    }
    try deleteAll(keyQuery)
  }

  // MARK: Keychain

  private var keyQuery: [CFString: Any] {
    [
      kSecClass: kSecClassKey,
      kSecAttrApplicationTag: applicationTag,
      kSecUseDataProtectionKeychain: false,
    ]
  }

  private func certificateQuery(publicKeyHash: Data) -> [CFString: Any] {
    [
      kSecClass: kSecClassCertificate,
      kSecAttrPublicKeyHash: publicKeyHash,
      kSecUseDataProtectionKeychain: false,
    ]
  }

  /// The public-key hash of every key carrying the tag.
  private func findKeyHashes() throws(MacServerIdentityFailure) -> [Data] {
    var query = keyQuery
    query[kSecReturnAttributes] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    var result: CFTypeRef?
    switch SecItemCopyMatching(query as CFDictionary, &result) {
    case errSecSuccess:
      guard let items = result as? [[CFString: Any]] else { throw .secureStorageUnavailable }
      var hashes: [Data] = []
      for item in items {
        guard let hash = item[kSecAttrApplicationLabel] as? Data, !hash.isEmpty else {
          throw .secureStorageUnavailable
        }
        hashes.append(hash)
      }
      return hashes
    case errSecItemNotFound:
      return []
    default:
      throw .secureStorageUnavailable
    }
  }

  private func findCertificates(publicKeyHash: Data) throws(MacServerIdentityFailure)
    -> [SecCertificate]
  {
    var query = certificateQuery(publicKeyHash: publicKeyHash)
    query[kSecReturnRef] = true
    query[kSecMatchLimit] = kSecMatchLimitAll
    var result: CFTypeRef?
    switch SecItemCopyMatching(query as CFDictionary, &result) {
    case errSecSuccess:
      guard let certificates = result as? [SecCertificate] else {
        throw .secureStorageUnavailable
      }
      return certificates
    case errSecItemNotFound:
      return []
    default:
      throw .secureStorageUnavailable
    }
  }

  private func create(now: Date) throws(MacServerIdentityFailure) -> MacServerIdentity {
    // The file-based Keychain only honours non-extractability at the top level.
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
      kSecAttrKeySizeInBits: 256,
      kSecAttrIsExtractable: false,
      kSecUseDataProtectionKeychain: false,
      kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrIsExtractable: false,
        kSecAttrLabel: label,
        kSecAttrApplicationTag: applicationTag,
      ] as [CFString: Any],
    ]
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
      throw .secureStorageUnavailable
    }
    do throws(MacServerIdentityFailure) {
      let certificate = try makeCertificate(privateKey: privateKey, now: now)
      let add: [CFString: Any] = [
        kSecClass: kSecClassCertificate,
        kSecValueRef: certificate,
        kSecUseDataProtectionKeychain: false,
      ]
      guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess,
        case .success(let identity) = identity(for: certificate)
      else { throw .secureStorageUnavailable }
      return identity
    } catch {
      try? remove()
      throw error
    }
  }

  private func makeCertificate(privateKey: SecKey, now: Date) throws(MacServerIdentityFailure)
    -> SecCertificate
  {
    let notBefore = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    do throws(SelfSignedCertificateError) {
      let der = try SelfSignedCertificate.make(
        SelfSignedCertificateRequest(
          commonName: Self.commonName,
          serialNumber: try SelfSignedCertificate.randomSerialNumber(),
          notBefore: notBefore,
          notAfter: notBefore.addingTimeInterval(Self.lifetime)),
        privateKey: privateKey)
      guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
        throw .unparsable
      }
      return certificate
    } catch {
      throw .certificateGenerationFailed
    }
  }

  private func identity(for certificate: SecCertificate)
    -> Result<MacServerIdentity, MacServerIdentityFailure>
  {
    var identity: SecIdentity?
    guard SecIdentityCreateWithCertificate(nil, certificate, &identity) == errSecSuccess,
      let identity
    else { return .failure(.secureStorageUnavailable) }
    let der = SecCertificateCopyData(certificate) as Data
    return .success(
      MacServerIdentity(secIdentity: identity, certificateSHA256: Data(SHA256.hash(data: der))))
  }

  private func deleteAll(_ query: [CFString: Any]) throws(MacServerIdentityFailure) {
    for _ in 0..<Self.maximumDeletePasses {
      switch SecItemDelete(query as CFDictionary) {
      case errSecSuccess: continue
      case errSecItemNotFound: return
      default: throw .secureStorageUnavailable
      }
    }
    throw .secureStorageUnavailable
  }
}

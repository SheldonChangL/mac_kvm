import CryptoKit
import Foundation
import KVMContracts
import Security
import Testing

@testable import MacPlatform

// These tests use the real login Keychain and real loopback sockets, so they
// only run when opted in:
//
//   MACKVM_M2_TLS_PROBE=login-keychain swift test --package-path Packages/MacPlatform \
//     --filter MacServerIdentity
//
// Every test uses a fresh random label and removes what it created, also when
// an expectation fails. Nothing is logged; only fingerprints are compared.

private let probeEnabled =
  ProcessInfo.processInfo.environment["MACKVM_M2_TLS_PROBE"] == "login-keychain"

private func freshStore() -> MacServerIdentityStore {
  MacServerIdentityStore(label: "MacKVM M2 TLS probe \(UUID().uuidString)")
}

private func keyIsExtractable(_ identity: MacServerIdentity) throws -> Bool {
  var key: SecKey?
  #expect(SecIdentityCopyPrivateKey(identity.secIdentity, &key) == errSecSuccess)
  return SecKeyCopyExternalRepresentation(try #require(key), nil) != nil
}

private func keyQuery(_ store: MacServerIdentityStore) -> [CFString: Any] {
  [
    kSecClass: kSecClassKey,
    kSecAttrApplicationTag: Data("mackvm.server-identity:\(store.label)".utf8),
    kSecUseDataProtectionKeychain: false,
  ]
}

private func certificateQuery(_ publicKeyHash: Data) -> [CFString: Any] {
  [
    kSecClass: kSecClassCertificate,
    kSecAttrPublicKeyHash: publicKeyHash,
    kSecUseDataProtectionKeychain: false,
  ]
}

/// The public-key hashes of the store's keys, optionally creating the
/// identity first.
private func keyHashes(_ store: MacServerIdentityStore, creating: Bool = false) throws -> [Data] {
  if creating { _ = try store.loadOrCreate() }
  var query = keyQuery(store)
  query[kSecReturnAttributes] = true
  query[kSecMatchLimit] = kSecMatchLimitAll
  var result: CFTypeRef?
  guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
  return ((result as? [[CFString: Any]]) ?? []).compactMap {
    $0[kSecAttrApplicationLabel] as? Data
  }
}

private func certificateSHA256(_ identity: MacServerIdentity) throws -> Data {
  var certificate: SecCertificate?
  #expect(SecIdentityCopyCertificate(identity.secIdentity, &certificate) == errSecSuccess)
  return Data(SHA256.hash(data: SecCertificateCopyData(try #require(certificate)) as Data))
}

@Suite(
  "M2 server identity in the login Keychain (opt-in)", .serialized,
  .enabled(if: probeEnabled), .timeLimit(.minutes(1)))
struct MacServerIdentityStoreTests {
  @Test("first use creates an identity; later loads return the same one until removed")
  func roundTrip() throws {
    let store = freshStore()
    defer { try? store.remove() }

    let created = try store.loadOrCreate()
    #expect(created.certificateSHA256.count == 32)
    #expect(try certificateSHA256(created) == created.certificateSHA256)
    #expect(try !keyIsExtractable(created))
    #expect(try store.loadOrCreate().certificateSHA256 == created.certificateSHA256)

    try store.remove()
    let replaced = try store.loadOrCreate()
    #expect(replaced.certificateSHA256 != created.certificateSHA256)
    try store.remove()
    try store.remove()
  }

  @Test("a key whose certificate is gone is replaced by a new identity")
  func keyWithoutCertificateIsReplaced() throws {
    let store = freshStore()
    defer { try? store.remove() }
    let original = try store.loadOrCreate()
    let keyHash = try #require(try keyHashes(store).first)
    #expect(SecItemDelete(certificateQuery(keyHash) as CFDictionary) == errSecSuccess)

    let replaced = try store.loadOrCreate()
    #expect(replaced.certificateSHA256 != original.certificateSHA256)
    #expect(try keyHashes(store).count == 1)
    #expect(try store.loadOrCreate().certificateSHA256 == replaced.certificateSHA256)
  }

  @Test("a certificate whose key is gone is not reused")
  func certificateWithoutKeyIsNotReused() throws {
    let store = freshStore()
    let oldHash = try #require(try keyHashes(store, creating: true).first)
    defer {
      try? store.remove()
      SecItemDelete(certificateQuery(oldHash) as CFDictionary)
    }
    let original = try store.loadOrCreate()
    #expect(SecItemDelete(keyQuery(store) as CFDictionary) == errSecSuccess)

    let replaced = try store.loadOrCreate()
    #expect(replaced.certificateSHA256 != original.certificateSHA256)
  }

  @Test("two certificates for the key, or two keys under the tag, fail closed")
  func ambiguityFailsClosed() throws {
    let store = freshStore()
    defer { try? store.remove() }
    let identity = try store.loadOrCreate()

    var key: SecKey?
    #expect(SecIdentityCopyPrivateKey(identity.secIdentity, &key) == errSecSuccess)
    let der = try SelfSignedCertificate.make(
      SelfSignedCertificateRequest(
        commonName: "MacKVM M2 TLS probe duplicate", serialNumber: [0x01],
        notBefore: Date(), notAfter: Date().addingTimeInterval(3600)),
      privateKey: try #require(key))
    let duplicate = try #require(SecCertificateCreateWithData(nil, der as CFData))
    let add: [CFString: Any] = [
      kSecClass: kSecClassCertificate, kSecValueRef: duplicate,
      kSecUseDataProtectionKeychain: false,
    ]
    #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
    #expect(throws: MacServerIdentityFailure.ambiguousIdentity) { try store.loadOrCreate() }

    try store.remove()
    _ = try store.loadOrCreate()
    let second: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
      kSecUseDataProtectionKeychain: false,
      kSecPrivateKeyAttrs: [
        kSecAttrIsPermanent: true,
        kSecAttrApplicationTag: Data("mackvm.server-identity:\(store.label)".utf8),
      ] as [CFString: Any],
    ]
    #expect(SecKeyCreateRandomKey(second as CFDictionary, nil) != nil)
    #expect(throws: MacServerIdentityFailure.ambiguousIdentity) { try store.loadOrCreate() }
  }

  @Test("a loopback TLS client pinning the fingerprint exchanges bytes; a wrong pin is refused")
  func loopbackHandshake() async throws {
    let store = freshStore()
    defer { try? store.remove() }
    let identity = try store.loadOrCreate()
    let (listener, port) = try await startedLoopbackListener(identity)
    defer { listener.stop() }
    var accepted = listener.connections.makeAsyncIterator()

    let client = MacTLSTransport(host: "127.0.0.1", port: port) { chain in
      chain.contains { Data(SHA256.hash(data: $0)) == identity.certificateSHA256 }
        ? .accept : .reject(.identityChanged)
    }
    async let clientConnected: Void = client.connect()
    let server = try #require(await accepted.next())
    try await server.connect()
    try await clientConnected

    var serverBytes = server.incomingBytes.makeAsyncIterator()
    var clientBytes = client.incomingBytes.makeAsyncIterator()
    try await client.send(Data("m2-ping".utf8))
    #expect(try await serverBytes.next() == Data("m2-ping".utf8))
    try await server.send(Data("m2-pong".utf8))
    #expect(try await clientBytes.next() == Data("m2-pong".utf8))
    await client.disconnect()
    await server.disconnect()

    let stranger = MacTLSTransport(host: "127.0.0.1", port: port) { _ in
      .reject(.identityChanged)
    }
    async let strangerResult: CoreError? = {
      do throws(CoreError) {
        try await stranger.connect()
        return nil
      } catch {
        return error
      }
    }()
    let refused = try #require(await accepted.next())
    do {
      try await refused.connect()
    } catch {
      // The server side fails too once the client aborts the handshake.
    }
    #expect(await strangerResult?.code == .security(.identityChanged))
    await refused.disconnect()
  }

  @Test("a second listener on a bound port fails to start")
  func portInUse() async throws {
    let store = freshStore()
    defer { try? store.remove() }
    let identity = try store.loadOrCreate()
    let (listener, port) = try await startedLoopbackListener(identity)
    defer { listener.stop() }

    let second = MacTLSServerListener(port: port, scope: .loopback, identity: identity)
    await #expect(throws: CoreError.self) { try await second.start() }
    second.stop()
  }
}

/// A loopback listener on a free high port.
private func startedLoopbackListener(_ identity: MacServerIdentity) async throws
  -> (MacTLSServerListener, UInt16)
{
  for _ in 0..<8 {
    let port = UInt16.random(in: 40_000...60_000)
    let listener = MacTLSServerListener(port: port, scope: .loopback, identity: identity)
    do {
      try await listener.start()
      return (listener, port)
    } catch {
      listener.stop()
    }
  }
  Issue.record("no free loopback port")
  throw CancellationError()
}

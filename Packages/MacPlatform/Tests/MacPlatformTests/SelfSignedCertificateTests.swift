import Foundation
import Security
import Testing

@testable import MacPlatform

// Every key here is ephemeral (never added to a Keychain), so no test touches
// persistent storage. The certificate is checked with the platform's own X.509
// parser and trust evaluation rather than with a second hand-written decoder.

private func ephemeralKey(type: CFString = kSecAttrKeyTypeECSECPrimeRandom, bits: Int = 256)
  throws -> SecKey
{
  let attributes: [CFString: Any] = [
    kSecAttrKeyType: type,
    kSecAttrKeySizeInBits: bits,
    kSecAttrIsPermanent: false,
  ]
  var error: Unmanaged<CFError>?
  return try #require(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
}

private func utc(_ text: String) throws -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return try #require(formatter.date(from: text))
}

private func request(
  serial: [UInt8] = [0x01, 0x23, 0x45],
  notBefore: Date,
  notAfter: Date
) -> SelfSignedCertificateRequest {
  SelfSignedCertificateRequest(
    commonName: "MacKVM Test Server", serialNumber: serial, notBefore: notBefore,
    notAfter: notAfter)
}

/// One definite-length DER element starting at `offset`: its content range and
/// the index just past it. Only the outer certificate structure is split; the
/// platform parser checks everything else.
private func element(in bytes: [UInt8], at offset: Int) throws -> (content: Range<Int>, end: Int) {
  try #require(offset + 2 <= bytes.count)
  var index = offset + 1
  var count = Int(bytes[index])
  index += 1
  if count & 0x80 != 0 {
    let width = count & 0x7F
    try #require((1...4).contains(width) && index + width <= bytes.count)
    count = bytes[index..<index + width].reduce(0) { $0 << 8 | Int($1) }
    index += width
  }
  try #require(index + count <= bytes.count)
  return (index..<index + count, index + count)
}

/// Verifies the certificate's signature over its TBS bytes with `key`.
private func signatureVerifies(_ der: Data, with key: SecKey) throws -> Bool {
  let bytes = Array(der)
  let certificate = try element(in: bytes, at: 0)
  let tbsStart = certificate.content.lowerBound
  let tbs = try element(in: bytes, at: tbsStart)
  let algorithm = try element(in: bytes, at: tbs.end)
  let signature = try element(in: bytes, at: algorithm.end)
  try #require(bytes[signature.content.lowerBound] == 0x00)
  let publicKey = try #require(SecKeyCopyPublicKey(key))
  return SecKeyVerifySignature(
    publicKey, .ecdsaSignatureMessageX962SHA256, Data(bytes[tbsStart..<tbs.end]) as CFData,
    Data(bytes[(signature.content.lowerBound + 1)..<signature.end]) as CFData, nil)
}

/// Evaluates `der` as its own only anchor with the basic X.509 policy at `date`.
/// An anchor's own signature is not checked, so this proves structure and
/// validity dates only; `signatureVerifies` proves the signature.
private func selfTrustEvaluates(_ der: Data, at date: Date) throws -> Bool {
  let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
  var trust: SecTrust?
  #expect(
    SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
      == errSecSuccess)
  let created = try #require(trust)
  #expect(SecTrustSetAnchorCertificates(created, [certificate] as CFArray) == errSecSuccess)
  #expect(SecTrustSetAnchorCertificatesOnly(created, true) == errSecSuccess)
  #expect(SecTrustSetNetworkFetchAllowed(created, false) == errSecSuccess)
  #expect(SecTrustSetVerifyDate(created, date as CFDate) == errSecSuccess)
  return SecTrustEvaluateWithError(created, nil)
}

@Suite("M2 self-signed server certificate DER")
struct SelfSignedCertificateDERTests {
  @Test("definite lengths use the short form below 128 and minimal long forms above")
  func lengths() {
    #expect(DEREncoder.length(0) == [0x00])
    #expect(DEREncoder.length(127) == [0x7F])
    #expect(DEREncoder.length(128) == [0x81, 0x80])
    #expect(DEREncoder.length(255) == [0x81, 0xFF])
    #expect(DEREncoder.length(256) == [0x82, 0x01, 0x00])
    #expect(DEREncoder.length(65_536) == [0x83, 0x01, 0x00, 0x00])
  }

  @Test("object identifiers match their published encodings")
  func objectIdentifiers() {
    #expect(
      DEREncoder.objectIdentifier([1, 2, 840, 10045, 4, 3, 2])
        == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
    #expect(
      DEREncoder.objectIdentifier([1, 2, 840, 10045, 3, 1, 7])
        == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    #expect(DEREncoder.objectIdentifier([2, 5, 4, 3]) == [0x06, 0x03, 0x55, 0x04, 0x03])
    #expect(
      DEREncoder.objectIdentifier([1, 3, 6, 1, 5, 5, 7, 3, 1])
        == [0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
  }

  @Test("integers are minimal and positive")
  func integers() {
    #expect(DEREncoder.integer(unsignedBigEndian: [0x02]) == [0x02, 0x01, 0x02])
    #expect(DEREncoder.integer(unsignedBigEndian: [0x80]) == [0x02, 0x02, 0x00, 0x80])
    #expect(DEREncoder.integer(unsignedBigEndian: [0x00, 0x00, 0x7F]) == [0x02, 0x01, 0x7F])
    #expect(DEREncoder.integer(unsignedBigEndian: [0x00]) == [0x02, 0x01, 0x00])
  }

  @Test("times use UTCTime through 2049 and GeneralizedTime from 2050")
  func times() throws {
    #expect(
      DEREncoder.time(try utc("2026-10-28T06:50:02Z"))
        == [0x17, 0x0D] + Array("261028065002Z".utf8))
    #expect(
      DEREncoder.time(try utc("2049-12-31T23:59:59Z"))
        == [0x17, 0x0D] + Array("491231235959Z".utf8))
    #expect(
      DEREncoder.time(try utc("2050-01-01T00:00:00Z"))
        == [0x18, 0x0F] + Array("20500101000000Z".utf8))
  }

  @Test("bit strings carry the unused-bit count")
  func bitStrings() {
    #expect(DEREncoder.bitString([0xAB, 0xCD]) == [0x03, 0x03, 0x00, 0xAB, 0xCD])
    #expect(DEREncoder.bitString([0x80], unusedBits: 7) == [0x03, 0x02, 0x07, 0x80])
  }
}

@Suite("M2 self-signed server certificate")
struct SelfSignedCertificateTests {
  @Test("the platform parses the certificate and finds the signing key and name in it")
  func parses() throws {
    let key = try ephemeralKey()
    let der = try SelfSignedCertificate.make(
      request(notBefore: try utc("2026-10-28T00:00:00Z"), notAfter: try utc("2036-10-25T00:00:00Z")),
      privateKey: key)
    let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
    #expect(SecCertificateCopySubjectSummary(certificate) as String? == "MacKVM Test Server")

    let embedded = try #require(SecCertificateCopyKey(certificate))
    let publicKey = try #require(SecKeyCopyPublicKey(key))
    #expect(
      SecKeyCopyExternalRepresentation(embedded, nil) as Data?
        == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    #expect(SecCertificateCopySerialNumberData(certificate, nil) as Data? == Data([0x01, 0x23, 0x45]))
  }

  @Test("the certificate is a valid anchor for itself exactly inside its validity")
  func validityWindow() throws {
    let key = try ephemeralKey()
    let der = try SelfSignedCertificate.make(
      request(notBefore: try utc("2026-10-28T00:00:00Z"), notAfter: try utc("2036-10-25T00:00:00Z")),
      privateKey: key)
    #expect(try selfTrustEvaluates(der, at: try utc("2027-01-01T00:00:00Z")))
    #expect(try !selfTrustEvaluates(der, at: try utc("2026-10-27T23:59:59Z")))
    #expect(try !selfTrustEvaluates(der, at: try utc("2036-10-25T00:00:01Z")))
  }

  @Test("the signature over the TBS bytes verifies with the certificate's own key only")
  func signature() throws {
    let key = try ephemeralKey()
    let validity = (try utc("2026-10-28T00:00:00Z"), try utc("2036-10-25T00:00:00Z"))
    let der = try SelfSignedCertificate.make(
      request(notBefore: validity.0, notAfter: validity.1), privateKey: key)
    #expect(try signatureVerifies(der, with: key))
    #expect(try !signatureVerifies(der, with: try ephemeralKey()))

    let forged = try SelfSignedCertificate.make(
      request(notBefore: validity.0, notAfter: validity.1), privateKey: key,
      signingKey: try ephemeralKey())
    #expect(try !signatureVerifies(forged, with: key))
  }

  @Test("validity beyond 2049 is encoded as GeneralizedTime and still evaluates")
  func generalizedTimeValidity() throws {
    let der = try SelfSignedCertificate.make(
      request(notBefore: try utc("2048-01-01T00:00:00Z"), notAfter: try utc("2051-01-01T00:00:00Z")),
      privateKey: try ephemeralKey())
    #expect(try selfTrustEvaluates(der, at: try utc("2050-06-01T00:00:00Z")))
    #expect(try !selfTrustEvaluates(der, at: try utc("2051-01-01T00:00:01Z")))
  }

  @Test("invalid serial numbers, validity and key types fail closed")
  func invalidInputs() throws {
    let key = try ephemeralKey()
    let start = try utc("2026-10-28T00:00:00Z")
    let end = try utc("2036-10-25T00:00:00Z")
    for serial: [UInt8] in [[], [0x00], [0x00, 0x01], [0x80], Array(repeating: 0x01, count: 21)] {
      #expect(throws: SelfSignedCertificateError.invalidSerialNumber) {
        try SelfSignedCertificate.make(request(serial: serial, notBefore: start, notAfter: end), privateKey: key)
      }
    }
    #expect(throws: SelfSignedCertificateError.invalidValidity) {
      try SelfSignedCertificate.make(request(notBefore: end, notAfter: start), privateKey: key)
    }
    #expect(throws: SelfSignedCertificateError.invalidValidity) {
      try SelfSignedCertificate.make(request(notBefore: start, notAfter: start), privateKey: key)
    }
    let rsa = try ephemeralKey(type: kSecAttrKeyTypeRSA, bits: 2048)
    #expect(throws: SelfSignedCertificateError.invalidPublicKey) {
      try SelfSignedCertificate.make(request(notBefore: start, notAfter: end), privateKey: rsa)
    }
  }

  @Test("random serial numbers are 16 positive, minimal bytes and differ between calls")
  func randomSerialNumbers() throws {
    var seen = Set<[UInt8]>()
    for _ in 0..<64 {
      let serial = try SelfSignedCertificate.randomSerialNumber()
      #expect(serial.count == 16)
      #expect((0x01...0x7F).contains(serial[0]))
      seen.insert(serial)
    }
    #expect(seen.count == 64)
  }
}

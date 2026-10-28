// Self-signed TLS certificate for the Barrier server role (M2; owner decision
// 2026-10-28: the server generates its certificate on first launch and keeps the
// private key only in the Keychain). Barrier clients pin the server by the SHA-256
// of the certificate DER and do not validate the chain, names or dates, so a
// minimal, well-formed X.509 v3 certificate signed by its own P-256 key is enough.
// Only the DER subset this certificate needs is encoded here; the platform X.509
// parser and trust evaluation check the result in tests.

import Foundation
import Security

/// Why no certificate was produced. Carries no key, name or signature bytes.
enum SelfSignedCertificateError: Error, Equatable, Sendable {
  /// The key is not an EC P-256 key with an uncompressed public point.
  case invalidPublicKey
  /// The serial number is not 1...20 bytes, positive and minimally encoded.
  case invalidSerialNumber
  /// `notAfter` is not later than `notBefore`, or a year is outside 1950...9999.
  case invalidValidity
  /// The signing key refused to sign or produced nothing.
  case signingFailed
  /// The platform could not parse the encoded certificate.
  case unparsable
  /// The system random number generator failed.
  case randomUnavailable
}

/// What goes into the certificate besides the key.
struct SelfSignedCertificateRequest: Equatable, Sendable {
  let commonName: String
  let serialNumber: [UInt8]
  let notBefore: Date
  let notAfter: Date
}

/// Builds a self-signed X.509 v3 certificate for an EC P-256 key, signed with
/// ECDSA-SHA256. Subject and issuer are the same single common name; the
/// extensions mark it as a non-CA TLS server certificate.
enum SelfSignedCertificate {
  private static let ecdsaWithSHA256: [UInt] = [1, 2, 840, 10045, 4, 3, 2]
  private static let ecPublicKey: [UInt] = [1, 2, 840, 10045, 2, 1]
  private static let prime256v1: [UInt] = [1, 2, 840, 10045, 3, 1, 7]
  private static let commonName: [UInt] = [2, 5, 4, 3]
  private static let basicConstraints: [UInt] = [2, 5, 29, 19]
  private static let keyUsage: [UInt] = [2, 5, 29, 15]
  private static let extendedKeyUsage: [UInt] = [2, 5, 29, 37]
  private static let serverAuthentication: [UInt] = [1, 3, 6, 1, 5, 5, 7, 3, 1]

  /// Returns the certificate DER. `signingKey` defaults to `privateKey`; tests
  /// pass a different key to prove the signature is checked.
  static func make(
    _ request: SelfSignedCertificateRequest,
    privateKey: SecKey,
    signingKey: SecKey? = nil
  ) throws(SelfSignedCertificateError) -> Data {
    guard let publicKey = SecKeyCopyPublicKey(privateKey),
      let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?,
      point.count == 65, point.first == 0x04
    else { throw .invalidPublicKey }
    guard isValidSerialNumber(request.serialNumber) else { throw .invalidSerialNumber }
    guard request.notBefore < request.notAfter,
      isEncodable(request.notBefore), isEncodable(request.notAfter)
    else { throw .invalidValidity }

    let algorithm = DEREncoder.sequence([DEREncoder.objectIdentifier(ecdsaWithSHA256)])
    let name = DEREncoder.sequence([
      DEREncoder.set([
        DEREncoder.sequence([
          DEREncoder.objectIdentifier(commonName), DEREncoder.utf8String(request.commonName),
        ])
      ])
    ])
    let subjectPublicKeyInfo = DEREncoder.sequence([
      DEREncoder.sequence([
        DEREncoder.objectIdentifier(ecPublicKey), DEREncoder.objectIdentifier(prime256v1),
      ]),
      DEREncoder.bitString(Array(point)),
    ])
    let extensions = DEREncoder.explicit(
      3,
      DEREncoder.sequence([
        DEREncoder.sequence([
          DEREncoder.objectIdentifier(basicConstraints), DEREncoder.boolean(true),
          DEREncoder.octetString(DEREncoder.sequence([])),
        ]),
        DEREncoder.sequence([
          DEREncoder.objectIdentifier(keyUsage), DEREncoder.boolean(true),
          DEREncoder.octetString(DEREncoder.bitString([0x80], unusedBits: 7)),
        ]),
        DEREncoder.sequence([
          DEREncoder.objectIdentifier(extendedKeyUsage),
          DEREncoder.octetString(
            DEREncoder.sequence([DEREncoder.objectIdentifier(serverAuthentication)])),
        ]),
      ]))
    let tbsCertificate = DEREncoder.sequence([
      DEREncoder.explicit(0, DEREncoder.integer(unsignedBigEndian: [0x02])),
      DEREncoder.integer(unsignedBigEndian: request.serialNumber),
      algorithm,
      name,
      DEREncoder.sequence([
        DEREncoder.time(request.notBefore), DEREncoder.time(request.notAfter),
      ]),
      name,
      subjectPublicKeyInfo,
      extensions,
    ])

    guard
      let signature = SecKeyCreateSignature(
        signingKey ?? privateKey, .ecdsaSignatureMessageX962SHA256,
        Data(tbsCertificate) as CFData, nil) as Data?,
      !signature.isEmpty
    else { throw .signingFailed }

    let certificate = Data(
      DEREncoder.sequence([tbsCertificate, algorithm, DEREncoder.bitString(Array(signature))]))
    guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else {
      throw .unparsable
    }
    return certificate
  }

  /// 16 random bytes whose first byte is 0x01...0x7F, so the serial number is
  /// positive and its DER encoding is minimal.
  static func randomSerialNumber() throws(SelfSignedCertificateError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw .randomUnavailable
    }
    bytes[0] = (bytes[0] & 0x7F) | 0x01
    return bytes
  }

  private static func isValidSerialNumber(_ serial: [UInt8]) -> Bool {
    guard (1...20).contains(serial.count), let first = serial.first else { return false }
    return (0x01...0x7F).contains(first)
  }

  private static func isEncodable(_ date: Date) -> Bool {
    (1950...9999).contains(DEREncoder.utcCalendar.component(.year, from: date))
  }
}

/// The DER building blocks `SelfSignedCertificate` needs, and nothing more.
enum DEREncoder {
  static let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    return calendar
  }()

  static func length(_ count: Int) -> [UInt8] {
    guard count >= 0x80 else { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var remaining = count
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func element(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
    [tag] + length(content.count) + content
  }

  static func sequence(_ elements: [[UInt8]]) -> [UInt8] {
    element(0x30, elements.flatMap { $0 })
  }

  static func set(_ elements: [[UInt8]]) -> [UInt8] {
    element(0x31, elements.flatMap { $0 })
  }

  /// A context-specific, constructed, explicitly tagged element.
  static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] {
    element(0xA0 | number, content)
  }

  static func boolean(_ value: Bool) -> [UInt8] {
    element(0x01, [value ? 0xFF : 0x00])
  }

  /// A non-negative integer from big-endian magnitude bytes.
  static func integer(unsignedBigEndian magnitude: [UInt8]) -> [UInt8] {
    var bytes = Array(magnitude.drop { $0 == 0 })
    if bytes.isEmpty { bytes = [0x00] }
    if bytes[0] & 0x80 != 0 { bytes.insert(0x00, at: 0) }
    return element(0x02, bytes)
  }

  static func objectIdentifier(_ arcs: [UInt]) -> [UInt8] {
    var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
    for arc in arcs.dropFirst(2) {
      var chunk: [UInt8] = [UInt8(arc & 0x7F)]
      var remaining = arc >> 7
      while remaining > 0 {
        chunk.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
        remaining >>= 7
      }
      content += chunk
    }
    return element(0x06, content)
  }

  static func utf8String(_ text: String) -> [UInt8] {
    element(0x0C, Array(text.utf8))
  }

  static func octetString(_ content: [UInt8]) -> [UInt8] {
    element(0x04, content)
  }

  static func bitString(_ content: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] {
    element(0x03, [unusedBits] + content)
  }

  /// UTCTime for 1950...2049 and GeneralizedTime otherwise (RFC 5280 4.1.2.5),
  /// both in UTC with whole seconds.
  static func time(_ date: Date) -> [UInt8] {
    let parts = utcCalendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let year = parts.year ?? 0
    let rest = [parts.month, parts.day, parts.hour, parts.minute, parts.second]
      .map { twoDigits($0 ?? 0) }.joined()
    if (1950...2049).contains(year) {
      return element(0x17, Array((twoDigits(year % 100) + rest + "Z").utf8))
    }
    return element(0x18, Array((fourDigits(year) + rest + "Z").utf8))
  }

  private static func twoDigits(_ value: Int) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  private static func fourDigits(_ value: Int) -> String {
    String(repeating: "0", count: max(0, 4 - String(value).count)) + String(value)
  }
}

import Foundation
import Testing

@testable import MacPlatform

// MARK: - Expected internal surface
//
// These tests drive the fingerprint formatter through a small internal seam.
// Nothing below is public, and nothing here decides trust: accepting,
// prompting for, or rejecting a peer belongs to the C-009 TrustPolicy, not to
// this unit.
//
//   enum CertificateFingerprint {
//     static let sha256DigestLength: Int  // 32
//     static func sha256Digest(ofCertificateDER der: Data)
//       -> Result<Data, CertificateFingerprintFailure>
//     static func canonicalDisplay(ofSHA256Digest digest: Data)
//       -> Result<String, CertificateFingerprintFailure>
//   }
//   enum CertificateFingerprintFailure: String, Error, Equatable, Sendable,
//     CaseIterable
//     { case emptyCertificate; case invalidDigestLength }
//
// Hashing and formatting are two separate operations: the raw digest is the
// value a trust store compares, and the display string is only for people.

// MARK: - Independent reference vectors
//
// Each digest below is a published SHA-256 test vector, transcribed byte by
// byte rather than computed by any code under test.

/// FIPS 180-2 Appendix B.1: SHA-256 of the three ASCII bytes "abc".
private let abcInput = Data("abc".utf8)
private let abcDigest = Data([
  0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
  0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
  0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
  0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD,
])
private let abcDisplay =
  "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:"
  + "B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD"

/// FIPS 180-2 Appendix B.2: a 56-byte message whose padding spills into a
/// second 64-byte block.
private let twoBlockInput = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
private let twoBlockDigest = Data([
  0x24, 0x8D, 0x6A, 0x61, 0xD2, 0x06, 0x38, 0xB8,
  0xE5, 0xC0, 0x26, 0x93, 0x0C, 0x3E, 0x60, 0x39,
  0xA3, 0x3C, 0xE4, 0x59, 0x64, 0xFF, 0x21, 0x67,
  0xF6, 0xEC, 0xED, 0xD4, 0x19, 0xDB, 0x06, 0xC1,
])
private let twoBlockDisplay =
  "24:8D:6A:61:D2:06:38:B8:E5:C0:26:93:0C:3E:60:39:"
  + "A3:3C:E4:59:64:FF:21:67:F6:EC:ED:D4:19:DB:06:C1"

/// SHA-256 of the single byte 0x00: the smallest non-empty input.
private let singleZeroByteInput = Data([0x00])
private let singleZeroByteDigest = Data([
  0x6E, 0x34, 0x0B, 0x9C, 0xFF, 0xB3, 0x7A, 0x98,
  0x9C, 0xA5, 0x44, 0xE6, 0xBB, 0x78, 0x0A, 0x2C,
  0x78, 0x90, 0x1D, 0x3F, 0xB3, 0x37, 0x38, 0x76,
  0x85, 0x11, 0xA3, 0x06, 0x17, 0xAF, 0xA0, 0x1D,
])

/// SHA-256 of zero bytes. Empty DER must fail closed, so this value must never
/// be produced.
private let emptyInputDigest = Data([
  0xE3, 0xB0, 0xC4, 0x42, 0x98, 0xFC, 0x1C, 0x14,
  0x9A, 0xFB, 0xF4, 0xC8, 0x99, 0x6F, 0xB9, 0x24,
  0x27, 0xAE, 0x41, 0xE4, 0x64, 0x9B, 0x93, 0x4C,
  0xA4, 0x95, 0x99, 0x1B, 0x78, 0x52, 0xB8, 0x55,
])

/// A formatting-only vector: bytes 0x00 through 0x1F, which exercises leading
/// zeros and every uppercase hex letter in the low nibble.
private let sequentialBytes = Data((0x00...0x1F).map { UInt8($0) })
private let sequentialDisplay =
  "00:01:02:03:04:05:06:07:08:09:0A:0B:0C:0D:0E:0F:"
  + "10:11:12:13:14:15:16:17:18:19:1A:1B:1C:1D:1E:1F"

/// Synthetic DER-shaped certificates. They are never parsed; only their bytes
/// matter.
private let certificateA = Data([0x30, 0x03, 0x02, 0x01, 0x01])
private let certificateB = Data([0x30, 0x03, 0x02, 0x01, 0x02])

// MARK: - Helpers

private func digest(_ der: Data) -> Data? {
  try? CertificateFingerprint.sha256Digest(ofCertificateDER: der).get()
}

private func display(_ digest: Data) -> String? {
  try? CertificateFingerprint.canonicalDisplay(ofSHA256Digest: digest).get()
}

private func digestFailure(_ der: Data) -> CertificateFingerprintFailure? {
  guard case .failure(let reason) = CertificateFingerprint.sha256Digest(ofCertificateDER: der)
  else { return nil }
  return reason
}

private func displayFailure(_ digest: Data) -> CertificateFingerprintFailure? {
  guard case .failure(let reason) = CertificateFingerprint.canonicalDisplay(ofSHA256Digest: digest)
  else { return nil }
  return reason
}

private let hexDigits = Set("0123456789ABCDEF")

/// Checks the canonical shape independently of any expected value: 32 groups
/// of two uppercase hex digits joined by single colons, nothing else.
private func isCanonicalShape(_ text: String) -> Bool {
  let groups = text.split(separator: ":", omittingEmptySubsequences: false)
  return text.count == 95
    && groups.count == 32
    && groups.allSatisfy { $0.count == 2 && $0.allSatisfy(hexDigits.contains) }
}

// MARK: - Happy path

@Test func digestLengthIsThirtyTwoBytes() {
  #expect(CertificateFingerprint.sha256DigestLength == 32)
}

@Test func sha256OfASCIIabcMatchesTheFIPSVector() {
  #expect(digest(abcInput) == abcDigest)
}

@Test func canonicalDisplayOfTheABCDigestMatchesTheVector() {
  #expect(display(abcDigest) == abcDisplay)
  #expect(isCanonicalShape(abcDisplay))
}

@Test func formattingBytesZeroThroughThirtyOneMatchesTheExplicitVector() {
  #expect(sequentialBytes.count == 32)
  #expect(display(sequentialBytes) == sequentialDisplay)
}

@Test func formattingUsesUppercaseHexForEveryByteValue() {
  let allHigh = Data(repeating: 0xFF, count: 32)
  #expect(display(allHigh) == Array(repeating: "FF", count: 32).joined(separator: ":"))

  // Every byte value 0x00...0xFF appears in exactly one of eight digests.
  for start in stride(from: 0, to: 256, by: 32) {
    let bytes = Data((start..<start + 32).map { UInt8($0) })
    let text = display(bytes)
    #expect(text.map(isCanonicalShape) == true, "byte range starting at \(start)")
    #expect(text == text?.uppercased())
  }
}

@Test func hashThenFormatProducesTheCanonicalFingerprint() throws {
  let raw = try CertificateFingerprint.sha256Digest(ofCertificateDER: abcInput).get()
  let text = try CertificateFingerprint.canonicalDisplay(ofSHA256Digest: raw).get()
  #expect(text == abcDisplay)
}

// MARK: - Raw digest and display are separate

@Test func digestIsRawBytesNotHexText() throws {
  let raw = try #require(digest(certificateA))
  let text = try #require(display(raw))
  #expect(raw.count == 32)
  #expect(text.count == 95)
  #expect(raw != Data(text.utf8), "the digest must not be its own display string")
}

/// Formatting never hashes: a 32-byte input is rendered as those exact bytes.
@Test func formattingDoesNotHashItsInput() throws {
  #expect(display(sequentialBytes) == sequentialDisplay)
  #expect(display(abcDigest) == abcDisplay)

  let rehashed = try #require(digest(abcDigest))
  #expect(display(rehashed) != abcDisplay)
}

/// Hashing never formats or passes through: a 32-byte DER is hashed, not
/// returned unchanged.
@Test func hashingDoesNotPassAThirtyTwoByteInputThrough() throws {
  let raw = try #require(digest(sequentialBytes))
  #expect(raw.count == 32)
  #expect(raw != sequentialBytes)
}

// MARK: - Boundaries

@Test func smallestNonEmptyCertificateIsHashed() {
  #expect(digest(singleZeroByteInput) == singleZeroByteDigest)
}

@Test func multiBlockInputMatchesTheFIPSVector() {
  #expect(digest(twoBlockInput) == twoBlockDigest)
  #expect(display(twoBlockDigest) == twoBlockDisplay)
}

@Test func largeCertificateStillYieldsAThirtyTwoByteDigest() throws {
  let large = Data(repeating: 0x5A, count: 262_144)
  let raw = try #require(digest(large))
  #expect(raw.count == 32)
  #expect(display(raw).map(isCanonicalShape) == true)
}

/// `Data` slices keep their parent's indices, so a slice does not start at
/// index zero. Both operations must read the slice's own bytes only.
@Test func dataSlicesWithANonZeroStartIndexAreHandled() throws {
  let paddedDER = Data([0xEE]) + abcInput + Data([0xEE])
  let derSlice = paddedDER[1..<4]
  try #require(derSlice.startIndex == 1)
  #expect(digest(derSlice) == abcDigest)

  let paddedDigest = Data([0xEE, 0xEE]) + sequentialBytes + Data([0xEE])
  let digestSlice = paddedDigest[2..<34]
  try #require(digestSlice.startIndex == 2)
  #expect(display(digestSlice) == sequentialDisplay)
}

// MARK: - Invalid input and fail-closed behaviour

@Test func emptyCertificateFailsClosedWithATypedError() {
  #expect(digestFailure(Data()) == .emptyCertificate)
  #expect(digest(Data()) == nil)
}

@Test func emptyCertificateNeverYieldsTheEmptyInputDigest() {
  let result = CertificateFingerprint.sha256Digest(ofCertificateDER: Data())
  #expect(result == .failure(.emptyCertificate))
  #expect(result != .success(emptyInputDigest))
}

@Test func emptySliceOfANonEmptyBufferFailsClosed() throws {
  let buffer = Data([0x30, 0x03])
  let empty = buffer[1..<1]
  try #require(empty.isEmpty)
  #expect(digestFailure(empty) == .emptyCertificate)
}

@Test(arguments: [0, 1, 16, 20, 31, 33, 48, 64, 95])
func digestOfAnyLengthOtherThanThirtyTwoFailsClosed(length: Int) {
  let candidate = Data(repeating: 0xAB, count: length)
  #expect(displayFailure(candidate) == .invalidDigestLength)
  #expect(display(candidate) == nil)
}

/// A display string fed back in as "digest" bytes is the wrong length and must
/// not be re-rendered.
@Test func displayTextIsNotAcceptedAsADigest() {
  #expect(displayFailure(Data(abcDisplay.utf8)) == .invalidDigestLength)
}

@Test func failureReasonsAreClosedAndDistinct() {
  #expect(CertificateFingerprintFailure.allCases == [.emptyCertificate, .invalidDigestLength])
  #expect(
    CertificateFingerprintFailure.allCases.map(\.rawValue) == [
      "emptyCertificate", "invalidDigestLength",
    ])
  #expect(CertificateFingerprintFailure.emptyCertificate != .invalidDigestLength)
}

// MARK: - Fingerprint changed

@Test func differentCertificatesProduceDifferentFingerprints() throws {
  let rawA = try #require(digest(certificateA))
  let rawB = try #require(digest(certificateB))
  #expect(rawA != rawB)
  #expect(display(rawA) != display(rawB))
}

@Test func anySingleBitFlipChangesTheFingerprint() throws {
  let original = try #require(digest(certificateA))
  for byteIndex in certificateA.indices {
    for bit in 0..<8 {
      var flipped = certificateA
      flipped[byteIndex] ^= UInt8(1 << bit)
      #expect(digest(flipped) != original, "byte \(byteIndex) bit \(bit)")
    }
  }
}

@Test func appendedOrTruncatedCertificateChangesTheFingerprint() throws {
  let original = try #require(digest(certificateA))
  #expect(digest(certificateA + Data([0x00])) != original)
  #expect(digest(certificateA.dropLast()) != original)
}

// MARK: - Determinism

@Test func sameCertificateAlwaysYieldsTheSameFingerprint() throws {
  let copy = Data(Array(certificateA))
  let first = try #require(digest(certificateA))
  #expect(digest(certificateA) == first)
  #expect(digest(copy) == first)

  let firstText = try #require(display(first))
  let copyDigest = try #require(digest(copy))
  #expect(display(first) == firstText)
  #expect(display(copyDigest) == firstText)
}

@Test func failuresDoNotPoisonLaterCalls() {
  #expect(digestFailure(Data()) == .emptyCertificate)
  #expect(displayFailure(Data([0x01])) == .invalidDigestLength)
  #expect(digest(abcInput) == abcDigest)
  #expect(display(abcDigest) == abcDisplay)
  #expect(digestFailure(Data()) == .emptyCertificate)
  #expect(displayFailure(Data([0x01])) == .invalidDigestLength)
}

// MARK: - Privacy

/// A failure carries no payload, so no rendering of it can leak certificate
/// or digest bytes.
@Test func failureRenderingsCarryNoInputBytes() {
  let distinctive = Data(repeating: 0xC7, count: 31)
  let renderings = [
    String(describing: CertificateFingerprint.canonicalDisplay(ofSHA256Digest: distinctive)),
    String(reflecting: CertificateFingerprint.canonicalDisplay(ofSHA256Digest: distinctive)),
    String(describing: CertificateFingerprint.sha256Digest(ofCertificateDER: Data())),
    String(reflecting: CertificateFingerprintFailure.invalidDigestLength),
  ]
  for text in renderings {
    #expect(!text.uppercased().contains("C7"))
    #expect(!text.contains("199"))  // 0xC7 in decimal
    #expect(!text.contains("31 bytes"))
  }
}

// MARK: - Purity: no state, nothing to cancel or clean up

/// Not applicable by design: both operations are pure, synchronous functions
/// over in-memory `Data`. They own no task, stream, socket, file, timer or
/// stored state, so there is nothing to cancel, nothing to release and no
/// teardown entry point. These tests therefore add no async or resource
/// behaviour; determinism and non-poisoning above cover idempotency.
@Test func fingerprintHoldsNoStateAndCannotBeInstantiated() {
  // A caseless enum has no instances and no stored state.
  #expect(MemoryLayout<CertificateFingerprint>.size == 0)
}

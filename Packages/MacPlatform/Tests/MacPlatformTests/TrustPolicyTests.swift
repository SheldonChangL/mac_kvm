import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

// MARK: - Expected internal surface
//
// These tests drive the C-009 trust policy through a small internal seam.
// Nothing below is public.
//
//   enum TrustPolicyState: Equatable, Sendable
//     { case unknown; case trusted(fingerprint: Data); case revoked }
//   enum TrustPolicyDecision: Equatable, Sendable
//     { case prompt; case allow; case reject(SecurityErrorCode) }
//   enum TrustPolicy {
//     static func decide(state: TrustPolicyState, presentedFingerprint: Data)
//       -> TrustPolicyDecision
//   }
//
// Precedence, highest first:
//   1. A presented fingerprint that is not exactly
//      `CertificateFingerprint.sha256DigestLength` bytes rejects with
//      `.trustRejected`, whatever the state.
//   2. A trusted state whose stored fingerprint is not exactly that length
//      rejects with `.trustRejected`, even when the bytes compare equal.
//   3. unknown → prompt; trusted + same → allow; trusted + different →
//      reject(.identityChanged); revoked → reject(.identityRevoked).
//
// The policy only decides. It never auto-accepts, stores, prompts, logs,
// formats a fingerprint, or picks a certificate out of a chain; the caller
// owns the state, the presented digest and whatever happens after `.prompt`.

// MARK: - Fixtures
//
// Valid fingerprints are published SHA-256 vectors, transcribed byte by byte
// rather than computed by any code under test.

private let validLength = CertificateFingerprint.sha256DigestLength

/// FIPS 180-2 Appendix B.1: SHA-256 of "abc".
private let fingerprintA = Data([
  0xBA, 0x78, 0x16, 0xBF, 0x8F, 0x01, 0xCF, 0xEA,
  0x41, 0x41, 0x40, 0xDE, 0x5D, 0xAE, 0x22, 0x23,
  0xB0, 0x03, 0x61, 0xA3, 0x96, 0x17, 0x7A, 0x9C,
  0xB4, 0x10, 0xFF, 0x61, 0xF2, 0x00, 0x15, 0xAD,
])

/// FIPS 180-2 Appendix B.2: SHA-256 of the 56-byte two-block message.
private let fingerprintB = Data([
  0x24, 0x8D, 0x6A, 0x61, 0xD2, 0x06, 0x38, 0xB8,
  0xE5, 0xC0, 0x26, 0x93, 0x0C, 0x3E, 0x60, 0x39,
  0xA3, 0x3C, 0xE4, 0x59, 0x64, 0xFF, 0x21, 0x67,
  0xF6, 0xEC, 0xED, 0xD4, 0x19, 0xDB, 0x06, 0xC1,
])

/// The canonical display of `fingerprintA`, written out by hand. Display text is
/// never a digest.
private let fingerprintADisplay =
  "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:"
  + "B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD"

/// A third valid-length fingerprint, unrelated to the published vectors.
private let distinctiveFingerprint = Data(repeating: 0xC7, count: 32)

// MARK: - Helpers

private func decide(_ state: TrustPolicyState, _ presented: Data) -> TrustPolicyDecision {
  TrustPolicy.decide(state: state, presentedFingerprint: presented)
}

/// Returns `fingerprint` cut to, or zero-padded out to, `length` bytes, so a
/// wrong-length value still shares every byte it can with the original.
private func resized(_ fingerprint: Data, to length: Int) -> Data {
  if length <= fingerprint.count { return Data(fingerprint.prefix(length)) }
  return fingerprint + Data(repeating: 0x00, count: length - fingerprint.count)
}

private func flipping(_ fingerprint: Data, byte offset: Int, bit: Int) -> Data {
  var copy = Data(Array(fingerprint))
  copy[offset] ^= UInt8(1 << bit)
  return copy
}

/// An exhaustive switch: adding a decision case breaks compilation here.
private func label(_ decision: TrustPolicyDecision) -> String {
  switch decision {
  case .prompt: "prompt"
  case .allow: "allow"
  case .reject(let code): "reject.\(code.rawValue)"
  }
}

/// An exhaustive switch: adding a state case breaks compilation here.
private func label(_ state: TrustPolicyState) -> String {
  switch state {
  case .unknown: "unknown"
  case .trusted: "trusted"
  case .revoked: "revoked"
  }
}

private func requireSendable<T: Sendable>(_: T.Type) {}

/// Every state shape, including trusted states holding an invalid-length
/// stored fingerprint.
private let everyStateShape: [TrustPolicyState] = [
  .unknown,
  .trusted(fingerprint: fingerprintA),
  .trusted(fingerprint: Data()),
  .trusted(fingerprint: resized(fingerprintA, to: 31)),
  .trusted(fingerprint: resized(fingerprintA, to: 33)),
  .revoked,
]

// MARK: - Full state/decision table

@Test func fullStateDecisionTable() {
  let table: [(state: TrustPolicyState, presented: Data, expected: TrustPolicyDecision)] = [
    (.unknown, fingerprintA, .prompt),
    (.unknown, fingerprintB, .prompt),
    (.trusted(fingerprint: fingerprintA), fingerprintA, .allow),
    (.trusted(fingerprint: fingerprintB), fingerprintB, .allow),
    (.trusted(fingerprint: fingerprintA), fingerprintB, .reject(.identityChanged)),
    (.trusted(fingerprint: fingerprintB), fingerprintA, .reject(.identityChanged)),
    (.revoked, fingerprintA, .reject(.identityRevoked)),
    (.revoked, fingerprintB, .reject(.identityRevoked)),
    (.unknown, Data(), .reject(.trustRejected)),
    (.trusted(fingerprint: fingerprintA), Data(), .reject(.trustRejected)),
    (.revoked, Data(), .reject(.trustRejected)),
    (.trusted(fingerprint: Data()), fingerprintA, .reject(.trustRejected)),
    (.trusted(fingerprint: Data()), Data(), .reject(.trustRejected)),
  ]
  for row in table {
    #expect(
      decide(row.state, row.presented) == row.expected,
      "\(label(row.state)) with \(row.presented.count)-byte input")
  }
}

@Test func digestLengthUsedByThePolicyIsThirtyTwoBytes() {
  #expect(validLength == 32)
  #expect(fingerprintA.count == validLength)
  #expect(fingerprintB.count == validLength)
  #expect(distinctiveFingerprint.count == validLength)
  #expect(fingerprintA != fingerprintB)
}

// MARK: - Happy path

@Test func unknownIdentityPromptsAndIsNeverAllowed() {
  #expect(decide(.unknown, fingerprintA) == .prompt)
  #expect(decide(.unknown, distinctiveFingerprint) == .prompt)
  #expect(decide(.unknown, Data(repeating: 0x00, count: 32)) == .prompt)
  #expect(decide(.unknown, Data(repeating: 0xFF, count: 32)) == .prompt)
}

@Test func trustedIdentityWithTheSameFingerprintIsAllowed() {
  #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintA) == .allow)
}

/// Equality is by content, not by storage: an independent copy matches.
@Test func trustedMatchComparesBytesNotStorage() {
  let independentCopy = Data(Array(fingerprintA))
  #expect(decide(.trusted(fingerprint: fingerprintA), independentCopy) == .allow)
  #expect(decide(.trusted(fingerprint: independentCopy), fingerprintA) == .allow)
}

/// `Data` slices keep their parent's indices. Both the stored and the presented
/// fingerprint may be slices with different non-zero start indices.
@Test func dataSlicesWithNonZeroStartIndicesAreHandled() throws {
  let storedBuffer = Data([0xEE]) + fingerprintA + Data([0xEE])
  let stored = storedBuffer[1..<33]
  let presentedBuffer = Data([0xEE, 0xEE, 0xEE]) + fingerprintA
  let presented = presentedBuffer[3..<35]
  try #require(stored.startIndex == 1)
  try #require(presented.startIndex == 3)

  #expect(decide(.trusted(fingerprint: stored), presented) == .allow)
  #expect(decide(.unknown, presented) == .prompt)
  #expect(decide(.revoked, presented) == .reject(.identityRevoked))

  let changedBuffer = Data([0xEE, 0xEE]) + fingerprintB
  let changed = changedBuffer[2..<34]
  #expect(decide(.trusted(fingerprint: stored), changed) == .reject(.identityChanged))

  let shortSlice = presentedBuffer[3..<34]
  #expect(decide(.trusted(fingerprint: stored), shortSlice) == .reject(.trustRejected))
}

// MARK: - Exact 32-byte boundary

@Test func exactlyThirtyTwoBytesIsTheOnlyAcceptedLength() {
  let short = resized(fingerprintA, to: 31)
  let long = resized(fingerprintA, to: 33)

  #expect(decide(.unknown, short) == .reject(.trustRejected))
  #expect(decide(.unknown, fingerprintA) == .prompt)
  #expect(decide(.unknown, long) == .reject(.trustRejected))

  #expect(decide(.trusted(fingerprint: fingerprintA), short) == .reject(.trustRejected))
  #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintA) == .allow)
  #expect(decide(.trusted(fingerprint: fingerprintA), long) == .reject(.trustRejected))

  #expect(decide(.revoked, short) == .reject(.trustRejected))
  #expect(decide(.revoked, fingerprintA) == .reject(.identityRevoked))
  #expect(decide(.revoked, long) == .reject(.trustRejected))
}

// MARK: - Wrong lengths

/// Length validation outranks every state: an unknown identity is not prompted
/// for, a revoked one is not reported as revoked, and a trusted one is not
/// reported as changed.
@Test(arguments: [0, 1, 16, 20, 31, 33, 48, 64, 95, 4096])
func wrongLengthPresentedFingerprintIsRejectedInEveryState(length: Int) {
  let presentations = [
    Data(repeating: 0xAB, count: length),
    resized(fingerprintA, to: length),
  ]
  for presented in presentations {
    for state in everyStateShape {
      #expect(
        decide(state, presented) == .reject(.trustRejected),
        "\(label(state)) with \(length)-byte input")
    }
  }
}

/// A trusted state is only as good as its stored fingerprint. A stored value of
/// the wrong length never matches, even against identical bytes.
@Test(arguments: [0, 1, 16, 20, 31, 33, 48, 64, 95, 4096])
func trustedStateWithAWrongLengthStoredFingerprintIsRejected(length: Int) {
  let stored = resized(fingerprintA, to: length)
  let state = TrustPolicyState.trusted(fingerprint: stored)

  #expect(decide(state, stored) == .reject(.trustRejected), "identical bytes")
  #expect(decide(state, Data(Array(stored))) == .reject(.trustRejected), "identical copy")
  #expect(decide(state, fingerprintA) == .reject(.trustRejected), "valid shared prefix")
  #expect(decide(state, fingerprintB) == .reject(.trustRejected), "valid unrelated")
}

// MARK: - Identity changed: one-bit and structural changes

@Test func flippingAnySingleBitOfThePresentedFingerprintIsAnIdentityChange() {
  let state = TrustPolicyState.trusted(fingerprint: fingerprintA)
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let flipped = flipping(fingerprintA, byte: offset, bit: bit)
      #expect(decide(state, flipped) == .reject(.identityChanged), "byte \(offset) bit \(bit)")
    }
  }
}

@Test func flippingAnySingleBitOfTheStoredFingerprintIsAnIdentityChange() {
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let stored = flipping(fingerprintA, byte: offset, bit: bit)
      let state = TrustPolicyState.trusted(fingerprint: stored)
      #expect(
        decide(state, fingerprintA) == .reject(.identityChanged), "byte \(offset) bit \(bit)")
    }
  }
}

/// The first and last bytes are where a prefix or truncated comparison would
/// go wrong, so they are pinned explicitly.
@Test func firstAndLastByteChangesAreIdentityChanges() {
  let state = TrustPolicyState.trusted(fingerprint: fingerprintA)
  #expect(decide(state, flipping(fingerprintA, byte: 0, bit: 0)) == .reject(.identityChanged))
  #expect(decide(state, flipping(fingerprintA, byte: 0, bit: 7)) == .reject(.identityChanged))
  #expect(decide(state, flipping(fingerprintA, byte: 31, bit: 0)) == .reject(.identityChanged))
  #expect(decide(state, flipping(fingerprintA, byte: 31, bit: 7)) == .reject(.identityChanged))
}

@Test func reorderedBytesAreAnIdentityChange() {
  let state = TrustPolicyState.trusted(fingerprint: fingerprintA)
  let reversed = Data(fingerprintA.reversed())
  let rotated = fingerprintA.dropFirst() + fingerprintA.prefix(1)
  #expect(decide(state, reversed) == .reject(.identityChanged))
  #expect(decide(state, Data(rotated)) == .reject(.identityChanged))
}

/// A one-bit change does not turn an unknown identity into anything but a
/// prompt, nor a revoked one into anything but a revocation.
@Test func oneBitChangesDoNotAlterUnknownOrRevokedOutcomes() {
  for offset in [0, validLength / 2, validLength - 1] {
    let flipped = flipping(fingerprintA, byte: offset, bit: 3)
    #expect(decide(.unknown, flipped) == .prompt)
    #expect(decide(.revoked, flipped) == .reject(.identityRevoked))
  }
}

// MARK: - No auto-accept and closed outcomes

/// `.allow` is reachable only through a trusted state whose valid stored
/// fingerprint equals a valid presented one; `.prompt` only through an unknown
/// state with a valid presented fingerprint.
@Test func allowAndPromptAreReachableOnlyThroughTheirOwnRows() {
  let presentedPool: [Data] = [
    fingerprintA, fingerprintB, distinctiveFingerprint,
    flipping(fingerprintA, byte: 31, bit: 0),
    Data(), resized(fingerprintA, to: 31), resized(fingerprintA, to: 33),
  ]
  let statePool = everyStateShape + [
    .trusted(fingerprint: fingerprintB), .trusted(fingerprint: distinctiveFingerprint),
  ]
  for state in statePool {
    for presented in presentedPool {
      let decision = decide(state, presented)
      let context = "\(label(state)) with \(presented.count)-byte input"
      if decision == .allow {
        #expect(presented.count == validLength, "\(context)")
        #expect(state == .trusted(fingerprint: presented), "\(context)")
      }
      if decision == .prompt {
        #expect(presented.count == validLength, "\(context)")
        #expect(state == .unknown, "\(context)")
      }
    }
  }
}

/// The policy reports only the three security codes its table names. In
/// particular an unknown identity prompts rather than rejecting with
/// `.identityUnknown`, and nothing claims storage was involved.
@Test func rejectionsUseOnlyTheTableCodes() {
  let allowedCodes: Set<SecurityErrorCode> = [.identityChanged, .identityRevoked, .trustRejected]
  let presentedPool: [Data] = [fingerprintA, fingerprintB, Data(), resized(fingerprintA, to: 33)]
  for state in everyStateShape {
    for presented in presentedPool {
      if case .reject(let code) = decide(state, presented) {
        #expect(allowedCodes.contains(code), "\(label(state)) gave \(code.rawValue)")
      }
    }
  }
}

@Test func decisionAndStateCaseSetsAreClosed() {
  #expect(label(TrustPolicyDecision.prompt) == "prompt")
  #expect(label(TrustPolicyDecision.allow) == "allow")
  #expect(label(TrustPolicyDecision.reject(.trustRejected)) == "reject.trustRejected")
  #expect(label(TrustPolicyState.unknown) == "unknown")
  #expect(label(TrustPolicyState.trusted(fingerprint: fingerprintA)) == "trusted")
  #expect(label(TrustPolicyState.revoked) == "revoked")
}

@Test func valueTypesAreEquatableAndSendable() {
  requireSendable(TrustPolicyState.self)
  requireSendable(TrustPolicyDecision.self)

  let trustedA = TrustPolicyState.trusted(fingerprint: fingerprintA)
  #expect(trustedA == .trusted(fingerprint: Data(Array(fingerprintA))))
  #expect(trustedA != .trusted(fingerprint: fingerprintB))
  #expect(TrustPolicyState.unknown != .revoked)
  #expect(TrustPolicyDecision.reject(.identityChanged) != .reject(.identityRevoked))
  #expect(TrustPolicyDecision.prompt != .allow)
}

// MARK: - Abuse paths

/// Two empty values compare equal; equality must not stand in for validity.
@Test func emptyStoredAndEmptyPresentedDoNotMatch() {
  #expect(decide(.trusted(fingerprint: Data()), Data()) == .reject(.trustRejected))
}

/// A stored value holding two digests back to back must not match either half,
/// and a presented value holding the trusted digest twice must not match it.
@Test func concatenatedDigestsDoNotMatchByPrefixOrSuffix() {
  let doubled = fingerprintA + fingerprintA
  let pair = fingerprintA + fingerprintB

  #expect(decide(.trusted(fingerprint: pair), fingerprintA) == .reject(.trustRejected))
  #expect(decide(.trusted(fingerprint: pair), fingerprintB) == .reject(.trustRejected))
  #expect(decide(.trusted(fingerprint: fingerprintA), doubled) == .reject(.trustRejected))
  #expect(decide(.trusted(fingerprint: doubled), doubled) == .reject(.trustRejected))
}

/// The policy compares raw digests. Display text, in either case, is not a
/// digest and is never accepted in place of one.
@Test func displayTextIsNotAcceptedAsAFingerprint() {
  let upper = Data(fingerprintADisplay.utf8)
  let lower = Data(fingerprintADisplay.lowercased().utf8)
  let bareHex = Data(fingerprintADisplay.replacingOccurrences(of: ":", with: "").utf8)
  for text in [upper, lower, bareHex] {
    #expect(decide(.trusted(fingerprint: fingerprintA), text) == .reject(.trustRejected))
    #expect(decide(.trusted(fingerprint: text), text) == .reject(.trustRejected))
    #expect(decide(.unknown, text) == .reject(.trustRejected))
  }
}

/// A revoked identity cannot be revived by presenting the fingerprint that was
/// once trusted, or any other.
@Test func revocationCannotBeBypassedByAnyValidFingerprint() {
  for presented in [fingerprintA, fingerprintB, distinctiveFingerprint] {
    #expect(decide(.revoked, presented) == .reject(.identityRevoked))
  }
}

// MARK: - Determinism, statelessness and failure recovery

@Test func repeatedCallsReturnTheSameDecision() {
  let cases: [(TrustPolicyState, Data)] = [
    (.unknown, fingerprintA),
    (.trusted(fingerprint: fingerprintA), fingerprintA),
    (.trusted(fingerprint: fingerprintA), fingerprintB),
    (.revoked, fingerprintA),
    (.unknown, Data()),
  ]
  for (state, presented) in cases {
    let first = decide(state, presented)
    for _ in 0..<100 {
      #expect(decide(state, presented) == first)
    }
  }
}

/// Prompting is not trust-on-first-use and allowing is not learning: the
/// policy keeps no memory of earlier calls, so the caller's state alone decides.
@Test func earlierCallsDoNotChangeLaterDecisions() {
  #expect(decide(.unknown, fingerprintA) == .prompt)
  #expect(decide(.unknown, fingerprintA) == .prompt)

  #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintA) == .allow)
  #expect(decide(.unknown, fingerprintA) == .prompt)

  #expect(decide(.revoked, fingerprintA) == .reject(.identityRevoked))
  #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintA) == .allow)

  #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintB) == .reject(.identityChanged))
  #expect(decide(.trusted(fingerprint: fingerprintB), fingerprintB) == .allow)
}

@Test func rejectionsDoNotPoisonLaterCalls() {
  for _ in 0..<3 {
    #expect(decide(.unknown, Data()) == .reject(.trustRejected))
    #expect(decide(.trusted(fingerprint: Data()), Data()) == .reject(.trustRejected))
    #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintB) == .reject(.identityChanged))
    #expect(decide(.revoked, fingerprintA) == .reject(.identityRevoked))

    #expect(decide(.unknown, fingerprintA) == .prompt)
    #expect(decide(.trusted(fingerprint: fingerprintA), fingerprintA) == .allow)
  }
}

@Test func decidingDoesNotMutateTheCallersInputs() {
  let stored = Data(Array(fingerprintA))
  let presented = Data(Array(fingerprintB))
  let state = TrustPolicyState.trusted(fingerprint: stored)

  _ = decide(state, presented)

  #expect(stored == fingerprintA)
  #expect(presented == fingerprintB)
  #expect(state == .trusted(fingerprint: fingerprintA))
}

@Test func concurrentCallsAgreeWithSerialCalls() async {
  let cases: [(TrustPolicyState, Data)] = [
    (.unknown, fingerprintA),
    (.trusted(fingerprint: fingerprintA), fingerprintA),
    (.trusted(fingerprint: fingerprintA), fingerprintB),
    (.revoked, fingerprintA),
    (.unknown, Data()),
  ]
  let expected = cases.map { decide($0.0, $0.1) }
  await withTaskGroup(of: (Int, TrustPolicyDecision).self) { group in
    for _ in 0..<16 {
      for (index, (state, presented)) in cases.enumerated() {
        group.addTask { (index, decide(state, presented)) }
      }
    }
    for await (index, decision) in group {
      #expect(decision == expected[index], "case \(index)")
    }
  }
}

// MARK: - Privacy: decisions carry no fingerprint

/// If a decision carried the presented fingerprint, synthesized equality would
/// tell two different fingerprints' decisions apart.
@Test func decisionsForDifferentFingerprintsAreIndistinguishable() {
  #expect(decide(.unknown, fingerprintA) == decide(.unknown, fingerprintB))
  #expect(decide(.revoked, fingerprintA) == decide(.revoked, distinctiveFingerprint))
  #expect(
    decide(.trusted(fingerprint: fingerprintA), fingerprintB)
      == decide(.trusted(fingerprint: fingerprintA), distinctiveFingerprint))
  #expect(decide(.unknown, Data()) == decide(.unknown, Data(repeating: 0xC7, count: 31)))
}

// MARK: - Cancellation and cleanup
//
// Not applicable by design: `decide` is a pure, synchronous function over two
// caller-owned values. It starts no work that could outlive the call, so there
// is nothing to cancel and nothing to release. Idempotency is covered by the
// determinism and non-poisoning tests above.

import Foundation
import KVMContracts
import KVMCore
import Testing

private let probeText = "m1-054-probe-\u{00E9}\u{4E2D}\u{1F600}"
private let probeHash = "m1-054-hash-sentinel"
private let otherHash = "m1-054-other-hash"

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x54, value))
}

private func transaction(_ value: UInt8) -> ClipboardTransactionID {
  ClipboardTransactionID(rawValue: fixedUUID(value))
}

private let peer = DeviceID(rawValue: fixedUUID(0xA0))
private let otherPeer = DeviceID(rawValue: fixedUUID(0xA1))

private func payload(
  _ transactionValue: UInt8,
  origin: ClipboardOrigin = .local,
  text: String = probeText,
  hash: String = probeHash
) -> ClipboardPayload {
  ClipboardPayload(
    transactionID: transaction(transactionValue),
    origin: origin,
    utf8Text: text,
    contentHash: hash
  )
}

private func limit(_ byteCount: Int) throws -> ClipboardByteLimit {
  try #require(ClipboardByteLimit(byteCount: byteCount))
}

private func generousLimit() throws -> ClipboardByteLimit {
  try limit(probeText.utf8.count)
}

private let oversizedRejection = CoreError(
  code: .clipboard(.oversized),
  severity: .warning,
  retryDisposition: .never,
  cleanupDisposition: .notRequired
)

private let loopRejection = CoreError(
  code: .clipboard(.loopRejected),
  severity: .warning,
  retryDisposition: .never,
  cleanupDisposition: .notRequired
)

private enum Direction {
  case outbound
  case inbound
}

private func admit(
  _ direction: Direction,
  _ value: ClipboardPayload,
  into loopGuard: inout ClipboardLoopGuard,
  limit: ClipboardByteLimit
) -> CoreError? {
  do {
    switch direction {
    case .outbound:
      try loopGuard.admitOutbound(value, limit: limit)
    case .inbound:
      try loopGuard.admitInbound(value, limit: limit)
    }
    return nil
  } catch {
    return error
  }
}

// MARK: - Happy path

@Test func clipboardLoopGuardAdmitsFirstOutboundLocalPayload() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()

  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)
  #expect(loopGuard != ClipboardLoopGuard())
}

@Test func clipboardLoopGuardAdmitsFirstInboundRemotePayload() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  let inbound = payload(1, origin: .remote(peer))

  #expect(admit(.inbound, inbound, into: &loopGuard, limit: byteLimit) == nil)
}

@Test func clipboardLoopGuardAdmitsSuccessiveDistinctPayloadsInBothDirections() throws {
  var loopGuard = ClipboardLoopGuard()
  let byteLimit = try generousLimit()

  #expect(admit(.outbound, payload(1, hash: "a"), into: &loopGuard, limit: byteLimit) == nil)
  let inbound = payload(2, origin: .remote(peer), hash: "b")
  #expect(admit(.inbound, inbound, into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.outbound, payload(3, hash: "c"), into: &loopGuard, limit: byteLimit) == nil)
}

@Test func clipboardLoopGuardAdmitsContentAgainOnceOtherContentIntervened() throws {
  var loopGuard = ClipboardLoopGuard()
  let byteLimit = try generousLimit()

  #expect(admit(.outbound, payload(1, hash: "a"), into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.outbound, payload(2, hash: "b"), into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.outbound, payload(3, hash: "a"), into: &loopGuard, limit: byteLimit) == nil)
}

// MARK: - Size limit

@Test func clipboardLoopGuardAcceptsPayloadExactlyAtTheByteLimit() throws {
  let exact = try limit(probeText.utf8.count)

  var outboundGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &outboundGuard, limit: exact) == nil)

  var inboundGuard = ClipboardLoopGuard()
  let inbound = payload(1, origin: .remote(peer))
  #expect(admit(.inbound, inbound, into: &inboundGuard, limit: exact) == nil)
}

@Test func clipboardLoopGuardRejectsPayloadOneByteOverTheLimitInBothDirections() throws {
  let tooSmall = try limit(probeText.utf8.count - 1)

  var outboundGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &outboundGuard, limit: tooSmall) == oversizedRejection)
  #expect(outboundGuard == ClipboardLoopGuard())

  var inboundGuard = ClipboardLoopGuard()
  let inbound = payload(1, origin: .remote(peer))
  #expect(admit(.inbound, inbound, into: &inboundGuard, limit: tooSmall) == oversizedRejection)
  #expect(inboundGuard == ClipboardLoopGuard())
}

@Test func clipboardLoopGuardMeasuresUTF8BytesNotCharacters() throws {
  let emoji = "\u{1F600}"
  let threeBytes = try limit(3)
  let fourBytes = try limit(4)
  var loopGuard = ClipboardLoopGuard()

  #expect(emoji.count == 1)
  let rejected = admit(.outbound, payload(1, text: emoji), into: &loopGuard, limit: threeBytes)
  #expect(rejected == oversizedRejection)
  #expect(admit(.outbound, payload(1, text: emoji), into: &loopGuard, limit: fourBytes) == nil)
}

@Test func clipboardLoopGuardAdmitsEmptyTextUnderTheSmallestLimit() throws {
  let oneByte = try limit(1)
  var loopGuard = ClipboardLoopGuard()

  #expect(admit(.outbound, payload(1, text: ""), into: &loopGuard, limit: oneByte) == nil)
}

@Test func clipboardLoopGuardOversizedRejectionMatchesTheM1052Codec() throws {
  let tooSmall = try limit(1)
  var loopGuard = ClipboardLoopGuard()
  let guardError = admit(.outbound, payload(1), into: &loopGuard, limit: tooSmall)

  do {
    _ = try ClipboardTextCodec.encode(probeText, limit: tooSmall)
    Issue.record("the codec must reject the oversized probe")
  } catch let codecError as CoreError {
    #expect(guardError == codecError)
  }
}

@Test func clipboardLoopGuardChecksSizeBeforeOriginAndIdentity() throws {
  let tooSmall = try limit(1)
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1, text: "x"), into: &loopGuard, limit: tooSmall) == nil)

  let wrongOrigin = payload(2, origin: .remote(peer))
  #expect(admit(.outbound, wrongOrigin, into: &loopGuard, limit: tooSmall) == oversizedRejection)
  let sameTransaction = payload(1, hash: otherHash)
  let sameTransactionResult = admit(.outbound, sameTransaction, into: &loopGuard, limit: tooSmall)
  #expect(sameTransactionResult == oversizedRejection)
  #expect(admit(.inbound, payload(3), into: &loopGuard, limit: tooSmall) == oversizedRejection)
}

// MARK: - Origin

@Test func clipboardLoopGuardNeverSendsARemotePayloadBack() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  let remote = payload(1, origin: .remote(peer))

  #expect(admit(.outbound, remote, into: &loopGuard, limit: byteLimit) == loopRejection)
  #expect(loopGuard == ClipboardLoopGuard())
}

@Test func clipboardLoopGuardRejectsInboundPayloadClaimingLocalOrigin() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()

  #expect(admit(.inbound, payload(1), into: &loopGuard, limit: byteLimit) == loopRejection)
  #expect(loopGuard == ClipboardLoopGuard())
}

@Test func clipboardLoopGuardAcceptsInboundFromAnyRemoteDevice() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()

  let first = payload(1, origin: .remote(peer), hash: "a")
  #expect(admit(.inbound, first, into: &loopGuard, limit: byteLimit) == nil)
  let second = payload(2, origin: .remote(otherPeer), hash: "b")
  #expect(admit(.inbound, second, into: &loopGuard, limit: byteLimit) == nil)
}

// MARK: - Loop and duplicate suppression

@Test func clipboardLoopGuardSuppressesLocalEchoOfAnAppliedInboundPayload() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()

  let inbound = payload(1, origin: .remote(peer))
  #expect(admit(.inbound, inbound, into: &loopGuard, limit: byteLimit) == nil)

  // Applying the inbound text changes the local pasteboard, which the caller
  // observes as a new local payload with a fresh transaction but the same hash.
  let echo = payload(2)
  #expect(admit(.outbound, echo, into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardSuppressesPeerEchoOfAnOutboundPayload() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)

  let sameTransaction = payload(1, origin: .remote(peer), hash: otherHash)
  #expect(admit(.inbound, sameTransaction, into: &loopGuard, limit: byteLimit) == loopRejection)
  let sameHash = payload(2, origin: .remote(peer))
  #expect(admit(.inbound, sameHash, into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardRejectsARepeatedTransactionEvenWithNewContent() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)

  let reused = payload(1, text: "different", hash: otherHash)
  #expect(admit(.outbound, reused, into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardRejectsARepeatedHashUnderANewTransaction() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)

  #expect(admit(.outbound, payload(2), into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardRejectsTheExactSamePayloadTwice() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  let inbound = payload(1, origin: .remote(peer))

  #expect(admit(.inbound, inbound, into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.inbound, inbound, into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardSuppressesDuplicateContentFromAnotherRemoteDevice() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()

  let first = payload(1, origin: .remote(peer))
  #expect(admit(.inbound, first, into: &loopGuard, limit: byteLimit) == nil)
  let duplicate = payload(2, origin: .remote(otherPeer))
  #expect(admit(.inbound, duplicate, into: &loopGuard, limit: byteLimit) == loopRejection)
}

@Test func clipboardLoopGuardComparesHashesAsOpaqueExactValues() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1, hash: "abc"), into: &loopGuard, limit: byteLimit) == nil)

  // No normalisation: case and whitespace variants are different identities.
  #expect(admit(.outbound, payload(2, hash: "ABC"), into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.outbound, payload(3, hash: "ABC "), into: &loopGuard, limit: byteLimit) == nil)
  let repeated = admit(.outbound, payload(4, hash: "ABC "), into: &loopGuard, limit: byteLimit)
  #expect(repeated == loopRejection)
}

@Test func clipboardLoopGuardRemembersOnlyTheLastAdmittedIdentity() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1, hash: "a"), into: &loopGuard, limit: byteLimit) == nil)
  #expect(admit(.outbound, payload(2, hash: "b"), into: &loopGuard, limit: byteLimit) == nil)

  // A superseded transaction is no longer remembered; state holds one entry.
  let stale = payload(1, origin: .remote(peer), hash: "c")
  #expect(admit(.inbound, stale, into: &loopGuard, limit: byteLimit) == nil)
}

// MARK: - Cleanup and idempotency

@Test func clipboardLoopGuardRejectionLeavesStateUnchanged() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1, hash: "a"), into: &loopGuard, limit: byteLimit) == nil)
  let snapshot = loopGuard

  let tooSmall = try limit(1)
  #expect(admit(.outbound, payload(2, hash: "b"), into: &loopGuard, limit: tooSmall) != nil)
  #expect(admit(.inbound, payload(3, hash: "b"), into: &loopGuard, limit: byteLimit) != nil)
  #expect(admit(.outbound, payload(4, hash: "a"), into: &loopGuard, limit: byteLimit) != nil)
  #expect(loopGuard == snapshot)

  #expect(admit(.outbound, payload(5, hash: "b"), into: &loopGuard, limit: byteLimit) == nil)
}

@Test func clipboardLoopGuardResetForgetsTheRememberedPayload() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)

  loopGuard.reset()

  #expect(loopGuard == ClipboardLoopGuard())
  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)
}

@Test func clipboardLoopGuardResetIsIdempotent() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  loopGuard.reset()
  loopGuard.reset()
  #expect(loopGuard == ClipboardLoopGuard())

  #expect(admit(.outbound, payload(1), into: &loopGuard, limit: byteLimit) == nil)
  loopGuard.reset()
  loopGuard.reset()
  #expect(loopGuard == ClipboardLoopGuard())
}

@Test func clipboardLoopGuardCopiesAreIndependentValues() throws {
  let byteLimit = try generousLimit()
  var original = ClipboardLoopGuard()
  var copy = original

  #expect(admit(.outbound, payload(1), into: &copy, limit: byteLimit) == nil)
  #expect(original == ClipboardLoopGuard())
  #expect(admit(.outbound, payload(2), into: &original, limit: byteLimit) == nil)
}

// MARK: - Determinism

private func runScript(limit byteLimit: ClipboardByteLimit) -> ([CoreError?], ClipboardLoopGuard) {
  var loopGuard = ClipboardLoopGuard()
  let script: [(Direction, ClipboardPayload)] = [
    (.outbound, payload(1, hash: "a")),
    (.inbound, payload(2, origin: .remote(peer), hash: "a")),
    (.inbound, payload(3, origin: .remote(peer), hash: "b")),
    (.outbound, payload(4, hash: "b")),
    (.outbound, payload(5, origin: .remote(otherPeer), hash: "c")),
    (.inbound, payload(6, hash: "c")),
    (.outbound, payload(3, hash: "d")),
    (.outbound, payload(7, hash: "d")),
  ]
  let results = script.map { direction, value in
    admit(direction, value, into: &loopGuard, limit: byteLimit)
  }
  return (results, loopGuard)
}

private let expectedScriptResults: [CoreError?] = [
  nil,
  loopRejection,
  nil,
  loopRejection,
  loopRejection,
  loopRejection,
  loopRejection,
  nil,
]

@Test func clipboardLoopGuardIsDeterministicAcrossRepeatedRuns() throws {
  let byteLimit = try generousLimit()
  let (firstResults, firstState) = runScript(limit: byteLimit)
  let (secondResults, secondState) = runScript(limit: byteLimit)

  #expect(firstResults == expectedScriptResults)
  #expect(secondResults == firstResults)
  #expect(secondState == firstState)
}

// MARK: - Concurrency

private func requireSendable<T: Sendable>(_: T.Type) {}

@Test func clipboardLoopGuardIsSendable() {
  requireSendable(ClipboardLoopGuard.self)
}

@Test func clipboardLoopGuardRunsOffTheMainThread() async throws {
  let byteLimit = try generousLimit()
  let task = Task.detached { runScript(limit: byteLimit) }
  let (results, _) = await task.value

  #expect(results == expectedScriptResults)
}

@Test func clipboardLoopGuardIndependentOwnersDoNotInterfere() async throws {
  let byteLimit = try generousLimit()
  let outcomes = await withTaskGroup(of: [CoreError?].self) { group in
    for _ in 0..<16 {
      group.addTask { runScript(limit: byteLimit).0 }
    }
    var collected: [[CoreError?]] = []
    for await outcome in group {
      collected.append(outcome)
    }
    return collected
  }

  #expect(outcomes.count == 16)
  #expect(outcomes.allSatisfy { $0 == expectedScriptResults })
}

private actor LoopGuardOwner {
  private var loopGuard = ClipboardLoopGuard()

  func admitOutbound(_ value: ClipboardPayload, limit: ClipboardByteLimit) -> CoreError? {
    admit(.outbound, value, into: &loopGuard, limit: limit)
  }
}

@Test func clipboardLoopGuardSerializesThroughAnOwningActor() async throws {
  let owner = LoopGuardOwner()
  let byteLimit = try generousLimit()
  let rejections = await withTaskGroup(of: CoreError?.self) { group in
    for index in 0..<16 {
      // Every task offers the same content under a different transaction.
      group.addTask { await owner.admitOutbound(payload(UInt8(index)), limit: byteLimit) }
    }
    var collected: [CoreError?] = []
    for await result in group {
      collected.append(result)
    }
    return collected
  }

  #expect(rejections.filter { $0 == nil }.count == 1)
  #expect(rejections.filter { $0 == loopRejection }.count == 15)
}

// MARK: - Privacy

private func forbiddenFragments() -> [String] {
  [
    probeText,
    probeHash,
    otherHash,
    "\u{00E9}",
    "\u{4E2D}",
    "\u{1F600}",
    fixedUUID(1).uuidString,
    peer.rawValue.uuidString,
  ]
}

private func renderings(of error: CoreError) throws -> [String] {
  let json = try JSONEncoder().encode(error)
  return [
    String(describing: error),
    String(reflecting: error),
    "\(error)",
    String(decoding: json, as: UTF8.self),
  ]
}

@Test func clipboardLoopGuardRejectionsRenderOnlyFixedTaxonomy() throws {
  let oneByte = try limit(1)
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  let oversized = try #require(admit(.outbound, payload(1), into: &loopGuard, limit: oneByte))
  let loop = try #require(admit(.inbound, payload(1), into: &loopGuard, limit: byteLimit))

  #expect(oversized == oversizedRejection)
  #expect(loop == loopRejection)
  for error in [oversized, loop] {
    #expect(error.underlyingDiagnosticCode == nil)
    for rendering in try renderings(of: error) {
      for fragment in forbiddenFragments() {
        #expect(!rendering.contains(fragment))
      }
      #expect(!rendering.contains(String(probeText.utf8.count)))
    }

    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(error))
    let dictionary = try #require(object as? [String: Any])
    let expectedKeys: Set<String> = ["code", "severity", "retryDisposition", "cleanupDisposition"]
    #expect(Set(dictionary.keys) == expectedKeys)
  }
}

@Test func clipboardLoopGuardRedactsItsRememberedIdentity() throws {
  let byteLimit = try generousLimit()
  var loopGuard = ClipboardLoopGuard()
  let remote = payload(1, origin: .remote(peer))
  #expect(admit(.inbound, remote, into: &loopGuard, limit: byteLimit) == nil)

  var dumped = ""
  dump(loopGuard, to: &dumped)
  let rendered = [
    String(describing: loopGuard),
    String(reflecting: loopGuard),
    "\(loopGuard)",
    dumped,
  ]

  for rendering in rendered {
    for fragment in forbiddenFragments() {
      #expect(!rendering.contains(fragment))
    }
  }
  #expect(Mirror(reflecting: loopGuard).children.isEmpty)
}

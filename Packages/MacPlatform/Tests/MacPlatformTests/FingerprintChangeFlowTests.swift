import Foundation
import KVMContracts
import Security
import Testing

@testable import MacPlatform

// MARK: - Expected internal/package surface
//
// These tests drive the M1-059 fingerprint change flow over the M1-058
// `KeychainTrustStore`. Nothing below is public.
//
//   package enum FingerprintChangeOwnerDecision: Equatable, Sendable
//     { case repair; case reject }
//
//   package struct FingerprintChangeWarning: Equatable, Sendable,
//     CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
//     package let trustedFingerprintDisplay: String     // canonical display text
//     package let presentedFingerprintDisplay: String   // canonical display text
//     let deviceID: DeviceID
//     let trustedFingerprint: Data                      // raw digest, internal
//     let presentedFingerprint: Data                    // raw digest, internal
//     init?(deviceID:trustedFingerprint:presentedFingerprint:)
//   }
//
//   package enum FingerprintChangeOutcome: Equatable, Sendable {
//     case prompt
//     case allow
//     case reject(SecurityErrorCode)
//     case identityChanged(FingerprintChangeWarning)
//   }
//
//   package struct FingerprintChangeFlow: Sendable {
//     package init(store: KeychainTrustStore)
//     func evaluate(deviceID:presentedFingerprint:) async
//       -> CoreResult<FingerprintChangeOutcome>
//     func apply(ownerDecision:warning:) async -> CoreResult<FingerprintChangeOutcome>
//   }
//
// A warning exists only for two different raw SHA-256 digests. Every rendering
// of it is redacted; only its two display fields carry the fingerprints.
//
// evaluate  wrong presented length → reject(.trustRejected) with no I/O;
//           missing → prompt; same → allow; different → identityChanged(warning);
//           malformed stored → reject(.trustRejected); storage failure → failure.
//           It never writes.
// apply     .reject → reject(.trustRejected) with no I/O.
//           .repair → read the record. Unless it still holds the warning's trusted
//           fingerprint, nothing changes and the outcome judges the record as read.
//           Otherwise: observe cancellation, remove, insert-if-absent (issued even
//           if the task is cancelled after removal), read again and judge that read.
//           Only a read that allows the presented fingerprint answers .allow.
//           Nothing is retried, restored or overwritten.
//
// No automated test here touches the real Keychain. Ordinary tests only ever use
// the in-memory fake below; the static audit at the end of the ordinary region
// proves the production environment is named only in the Tier-H region.

// MARK: - Fixtures
//
// Valid fingerprints are published SHA-256 vectors, transcribed byte by byte
// rather than computed by any code under test. Display text is written out by
// hand.

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

/// A third valid-length fingerprint, unrelated to the published vectors.
private let fingerprintC = Data(repeating: 0xC7, count: 32)

private let fingerprintADisplay =
  "BA:78:16:BF:8F:01:CF:EA:41:41:40:DE:5D:AE:22:23:"
  + "B0:03:61:A3:96:17:7A:9C:B4:10:FF:61:F2:00:15:AD"

private let fingerprintBDisplay =
  "24:8D:6A:61:D2:06:38:B8:E5:C0:26:93:0C:3E:60:39:"
  + "A3:3C:E4:59:64:FF:21:67:F6:EC:ED:D4:19:DB:06:C1"

private let deviceOne = DeviceID(
  rawValue: UUID(uuidString: "5EED0590-ABCD-4EF0-8A1B-C2D3E4F50001")!
)
private let deviceTwo = DeviceID(
  rawValue: UUID(uuidString: "5EED0590-ABCD-4EF0-8A1B-C2D3E4F50002")!
)

private let wrongLengths = [0, 1, 16, 20, 31, 33, 48, 64, 95, 4096]

/// Statuses that mean a person must unlock, authenticate, or allow interaction.
private let interactionStatuses: [OSStatus] = [
  errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled,
]

/// Statuses no person can resolve by interacting, plus arbitrary values.
private let nonInteractiveStatuses: [OSStatus] = [
  errSecNotAvailable, errSecMissingEntitlement, errSecParam, errSecIO, -1, Int32.min, Int32.max,
]

private let readFailureStatuses =
  interactionStatuses + nonInteractiveStatuses + [errSecDuplicateItem]
private let addFailureStatuses = interactionStatuses + nonInteractiveStatuses + [errSecItemNotFound]
private let deleteFailureStatuses =
  interactionStatuses + nonInteractiveStatuses + [errSecDuplicateItem]

// MARK: - Deterministic in-memory Keychain

/// The three operations the store's seam exposes.
private enum KeychainOperation: Equatable {
  case read
  case add
  case delete
}

/// One observed call into the substituted Keychain seam, in call order.
private enum KeychainSeamCall: Equatable {
  case read(account: String)
  case add(account: String)
  case delete(account: String)

  var isMutation: Bool {
    if case .read = self { return false }
    return true
  }
}

private enum FakeKeychainItem: Equatable {
  case data(Data)
  /// A record the platform returns successfully but not as data.
  case nonData
}

private func popFront<T>(_ script: inout [T?]) -> T? {
  guard !script.isEmpty else { return nil }
  return script.removeFirst()
}

/// An in-memory Keychain that every ordinary test uses instead of the real one.
///
/// Add is atomic and insert-only: an existing account answers duplicate-item and
/// is left untouched. Each scripted reply is consumed once, in call order; a
/// `nil` entry means "behave normally". One call can be held before it reads or
/// changes anything, so a test can cancel the caller, or change the records as
/// another writer would, at an exact point. A release that comes first lets the
/// call through, and waiting for a hold ends when the waiting task is
/// cancelled, so a test whose time limit expires fails instead of hanging the
/// run. Each test owns its own instance, so tests are deterministic and safe in
/// parallel.
///
/// The seam closures are `@Sendable`, so the fake is lock-guarded and
/// `@unchecked Sendable`. macOS 14 is the platform floor, so `NSLock` is used
/// rather than `Synchronization.Mutex`.
private final class FakeKeychain: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: FakeKeychainItem]
  private var callLog: [KeychainSeamCall] = []
  private var addedPayloads: [Data] = []
  private var mainThreadLog: [Bool] = []
  private var readScript: [KeychainItemReadReply?] = []
  private var addScript: [OSStatus?] = []
  private var deleteScript: [OSStatus?] = []
  private var holdRequested: KeychainOperation?
  private var heldCall: CheckedContinuation<Void, Never>?
  private var isHolding = false
  private var releaseRequested = false
  private var waitCancelled = false
  private var holdWaiters: [CheckedContinuation<Void, Never>] = []

  init(items: [String: FakeKeychainItem] = [:]) {
    self.items = items
  }

  var calls: [KeychainSeamCall] { lock.withLock { callLog } }
  var mutations: [KeychainSeamCall] { calls.filter(\.isMutation) }
  var added: [Data] { lock.withLock { addedPayloads } }
  var allItems: [String: FakeKeychainItem] { lock.withLock { items } }
  var mainThreadObservations: [Bool] { lock.withLock { mainThreadLog } }

  func item(for account: String) -> FakeKeychainItem? {
    lock.withLock { items[account] }
  }

  /// Replaces whatever is stored for `account`, as another writer would.
  func replaceItem(for account: String, with item: FakeKeychainItem?) {
    lock.withLock { items[account] = item }
  }

  func scriptReads(_ replies: [KeychainItemReadReply?]) {
    lock.withLock { readScript = replies }
  }

  func scriptAdds(_ statuses: [OSStatus?]) {
    lock.withLock { addScript = statuses }
  }

  func scriptDeletes(_ statuses: [OSStatus?]) {
    lock.withLock { deleteScript = statuses }
  }

  /// Makes the next call of `operation` suspend, before it reads or changes
  /// anything, until `releaseHeldCall()` is called.
  func holdNext(_ operation: KeychainOperation) {
    lock.withLock { holdRequested = operation }
  }

  /// Returns once a call is held, or once the waiting task is cancelled.
  func waitUntilHeld() async {
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = lock.withLock {
          if isHolding || waitCancelled { return true }
          holdWaiters.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    } onCancel: {
      let waiters: [CheckedContinuation<Void, Never>] = self.lock.withLock {
        self.waitCancelled = true
        defer { self.holdWaiters = [] }
        return self.holdWaiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  /// Lets the held call continue. If no call is held yet, the next one that
  /// would be held continues at once.
  func releaseHeldCall() {
    let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
      releaseRequested = true
      defer { heldCall = nil }
      return heldCall
    }
    continuation?.resume()
  }

  var environment: KeychainTrustStoreEnvironment {
    KeychainTrustStoreEnvironment(
      readItem: { account in
        await self.pauseIfHolding(.read)
        return self.recordRead(account)
      },
      addItem: { account, fingerprint in
        await self.pauseIfHolding(.add)
        return self.recordAdd(account, fingerprint)
      },
      deleteItem: { account in
        await self.pauseIfHolding(.delete)
        return self.recordDelete(account)
      }
    )
  }

  private func pauseIfHolding(_ operation: KeychainOperation) async {
    let shouldHold: Bool = lock.withLock {
      guard holdRequested == operation else { return false }
      holdRequested = nil
      return !releaseRequested
    }
    guard shouldHold else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let (waiters, released): ([CheckedContinuation<Void, Never>], Bool) = lock.withLock {
        if releaseRequested { return ([], true) }
        heldCall = continuation
        isHolding = true
        defer { holdWaiters = [] }
        return (holdWaiters, false)
      }
      if released { continuation.resume() }
      for waiter in waiters { waiter.resume() }
    }
  }

  private func recordRead(_ account: String) -> KeychainItemReadReply {
    lock.withLock {
      callLog.append(.read(account: account))
      mainThreadLog.append(Thread.isMainThread)
      if let scripted = popFront(&readScript) { return scripted }
      switch items[account] {
      case .data(let stored): return .data(stored)
      case .nonData: return .nonData
      case nil: return .status(errSecItemNotFound)
      }
    }
  }

  private func recordAdd(_ account: String, _ fingerprint: Data) -> OSStatus {
    lock.withLock {
      callLog.append(.add(account: account))
      mainThreadLog.append(Thread.isMainThread)
      addedPayloads.append(fingerprint)
      if let scripted = popFront(&addScript) { return scripted }
      if items[account] != nil { return errSecDuplicateItem }
      items[account] = .data(Data(fingerprint))
      return errSecSuccess
    }
  }

  private func recordDelete(_ account: String) -> OSStatus {
    lock.withLock {
      callLog.append(.delete(account: account))
      mainThreadLog.append(Thread.isMainThread)
      if let scripted = popFront(&deleteScript) { return scripted }
      guard items.removeValue(forKey: account) != nil else { return errSecItemNotFound }
      return errSecSuccess
    }
  }
}

// MARK: - Helpers

/// The canonical account, derived here independently of the code under test.
private func account(_ deviceID: DeviceID) -> String {
  deviceID.rawValue.uuidString.lowercased()
}

private enum Seed {
  case absent
  case stored(Data)
  case nonData
}

private func keychain(_ seed: Seed, device: DeviceID = deviceOne) -> FakeKeychain {
  switch seed {
  case .absent: FakeKeychain()
  case .stored(let data): FakeKeychain(items: [account(device): .data(data)])
  case .nonData: FakeKeychain(items: [account(device): .nonData])
  }
}

private func makeStore(_ fake: FakeKeychain) -> KeychainTrustStore {
  KeychainTrustStore(environment: fake.environment)
}

private func makeFlow(_ fake: FakeKeychain) -> FingerprintChangeFlow {
  FingerprintChangeFlow(store: makeStore(fake))
}

private func evaluate(
  _ fake: FakeKeychain,
  _ presented: Data,
  device: DeviceID = deviceOne
) async -> CoreResult<FingerprintChangeOutcome> {
  await makeFlow(fake).evaluate(deviceID: device, presentedFingerprint: presented)
}

private func apply(
  _ fake: FakeKeychain,
  _ decision: FingerprintChangeOwnerDecision,
  _ warning: FingerprintChangeWarning
) async -> CoreResult<FingerprintChangeOutcome> {
  await makeFlow(fake).apply(ownerDecision: decision, warning: warning)
}

/// The warning for `device` trusting `trusted` while presenting `presented`,
/// built directly rather than by an evaluation.
private func expectedWarning(
  _ trusted: Data,
  _ presented: Data,
  device: DeviceID = deviceOne
) throws -> FingerprintChangeWarning {
  try #require(
    FingerprintChangeWarning(
      deviceID: device, trustedFingerprint: trusted, presentedFingerprint: presented))
}

/// The warning an identity-change outcome carries, or `nil` for any other result.
private func changeWarning(
  in result: CoreResult<FingerprintChangeOutcome>
) -> FingerprintChangeWarning? {
  if case .success(.identityChanged(let warning)) = result { return warning }
  return nil
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

private func hex(_ data: Data, uppercase: Bool) -> String {
  data.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
}

private func requireSendable<T: Sendable>(_: T.Type) {}

/// Runs `body` in a task that is already cancelled when `body` starts.
private func runCancelledBeforeStart<T: Sendable>(
  _ body: @escaping @Sendable () async -> T
) async -> T {
  await Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return await body()
  }.value
}

extension Result {
  fileprivate var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}

/// An exhaustive switch: adding an outcome case breaks compilation here.
private func label(_ outcome: FingerprintChangeOutcome) -> String {
  switch outcome {
  case .prompt: "prompt"
  case .allow: "allow"
  case .reject(let code): "reject.\(code.rawValue)"
  case .identityChanged: "identityChanged"
  }
}

/// An exhaustive switch: adding an owner decision breaks compilation here.
private func label(_ decision: FingerprintChangeOwnerDecision) -> String {
  switch decision {
  case .repair: "repair"
  case .reject: "reject"
  }
}

private func label(_ outcome: FirstUseTrustOutcome) -> String {
  switch outcome {
  case .prompt: "prompt"
  case .allow: "allow"
  case .reject(let code): "reject.\(code.rawValue)"
  }
}

private func label(_ reply: KeychainItemReadReply) -> String {
  switch reply {
  case .data: "data"
  case .nonData: "nonData"
  case .status: "status"
  }
}

/// Every form in which a test fingerprint or test device could appear in text.
private let forbiddenRenderingTokens: [String] = [
  hex(fingerprintA, uppercase: true), hex(fingerprintA, uppercase: false),
  hex(fingerprintB, uppercase: true), hex(fingerprintB, uppercase: false),
  fingerprintADisplay, fingerprintBDisplay,
  "BA:78:16", "ba:78:16", "BA7816", "ba7816", "24:8D:6A", "24:8d:6a", "248D6A", "248d6a",
  account(deviceOne), account(deviceOne).uppercased(),
]

// MARK: - Expected failure shapes

private func expectedRetry(for status: OSStatus) -> RetryDisposition {
  interactionStatuses.contains(status) ? .userActionRequired : .never
}

private func storageFailure(_ status: OSStatus) -> CoreError {
  CoreError(
    code: .security(.secureStorageUnavailable),
    severity: .error,
    retryDisposition: expectedRetry(for: status),
    cleanupDisposition: .notRequired,
    underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: status)
  )
}

/// The platform read succeeded but returned no data. There is no failing
/// status to report, so no diagnostic code is carried.
private let unreadableStorageFailure = CoreError(
  code: .security(.secureStorageUnavailable),
  severity: .error,
  retryDisposition: .never,
  cleanupDisposition: .notRequired
)

private let cancellationFailure = CoreError(
  code: .cancellation(.requested),
  severity: .info,
  retryDisposition: .never,
  cleanupDisposition: .notRequired
)

// MARK: - Types

@Test func fingerprintChangeTypesAreClosedEquatableAndSendable() throws {
  requireSendable(FingerprintChangeFlow.self)
  requireSendable(FingerprintChangeWarning.self)
  requireSendable(FingerprintChangeOutcome.self)
  requireSendable(FingerprintChangeOwnerDecision.self)

  // Referenced, never called: the flow is built over a store, nothing else.
  let initializer: (KeychainTrustStore) -> FingerprintChangeFlow = FingerprintChangeFlow.init
  _ = initializer

  #expect(label(FingerprintChangeOwnerDecision.repair) == "repair")
  #expect(label(FingerprintChangeOwnerDecision.reject) == "reject")

  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let outcomes: [FingerprintChangeOutcome] = [
    .prompt, .allow, .reject(.trustRejected), .identityChanged(warning),
  ]
  #expect(
    outcomes.map { label($0) } == ["prompt", "allow", "reject.trustRejected", "identityChanged"])
  // The change is its own case: it carries the warning, and it is never `.allow`.
  #expect(FingerprintChangeOutcome.identityChanged(warning) != .reject(.identityChanged))
  #expect(FingerprintChangeOutcome.identityChanged(warning) != .allow)
}

// MARK: - Warning presentation model

@Test func changeWarningShowsBothFingerprintsOnlyAsCanonicalDisplayText() throws {
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  #expect(warning.trustedFingerprintDisplay == fingerprintADisplay)
  #expect(warning.presentedFingerprintDisplay == fingerprintBDisplay)
  #expect(warning.deviceID == deviceOne)
  #expect(warning.trustedFingerprint == fingerprintA)
  #expect(warning.presentedFingerprint == fingerprintB)

  let reversed = try expectedWarning(fingerprintB, fingerprintA)
  #expect(reversed.trustedFingerprintDisplay == fingerprintBDisplay)
  #expect(reversed.presentedFingerprintDisplay == fingerprintADisplay)
  #expect(reversed != warning)

  // A warning is bound to its device.
  let otherDevice = try expectedWarning(fingerprintA, fingerprintB, device: deviceTwo)
  #expect(otherDevice != warning)
}

@Test(arguments: wrongLengths)
func changeWarningRefusesAFingerprintOfAnyOtherLength(length: Int) {
  let trustedMalformed = FingerprintChangeWarning(
    deviceID: deviceOne,
    trustedFingerprint: resized(fingerprintA, to: length),
    presentedFingerprint: fingerprintB
  )
  let presentedMalformed = FingerprintChangeWarning(
    deviceID: deviceOne,
    trustedFingerprint: fingerprintA,
    presentedFingerprint: resized(fingerprintB, to: length)
  )
  #expect(trustedMalformed == nil)
  #expect(presentedMalformed == nil)
}

@Test func changeWarningRefusesIdenticalFingerprints() {
  let identical = FingerprintChangeWarning(
    deviceID: deviceOne, trustedFingerprint: fingerprintA, presentedFingerprint: fingerprintA)
  let equalCopy = FingerprintChangeWarning(
    deviceID: deviceOne,
    trustedFingerprint: fingerprintA,
    presentedFingerprint: Data(Array(fingerprintA))
  )
  #expect(identical == nil)
  #expect(equalCopy == nil)
}

/// The warning is the one deliberate presentation of both fingerprints. Every
/// other rendering of it, or of a result carrying it, is redacted.
@Test func changeWarningIsRedactedInEveryRenderingButItsDisplayFields() async throws {
  let fake = keychain(.stored(fingerprintA))
  let result = await evaluate(fake, fingerprintB)
  let warning = try #require(changeWarning(in: result))
  let outcome = try result.get()

  var dumpedWarning = ""
  dump(warning, to: &dumpedWarning)
  var dumpedResult = ""
  dump(result, to: &dumpedResult)

  let renderings = [
    String(describing: warning),
    String(reflecting: warning),
    "\(warning)",
    String(describing: outcome),
    String(reflecting: outcome),
    "\(outcome)",
    String(describing: result),
    String(reflecting: result),
    dumpedWarning,
    dumpedResult,
  ]
  for rendering in renderings {
    for token in forbiddenRenderingTokens {
      #expect(!rendering.contains(token), "a rendering carries a fingerprint or device")
    }
  }
  #expect(String(describing: warning) == "FingerprintChangeWarning(redacted)")
  #expect(String(reflecting: warning) == "FingerprintChangeWarning(redacted)")
  #expect(Mirror(reflecting: warning).children.isEmpty)

  // The deliberate presentation still shows both fingerprints to the owner.
  #expect(warning.trustedFingerprintDisplay == fingerprintADisplay)
  #expect(warning.presentedFingerprintDisplay == fingerprintBDisplay)
}

// MARK: - Evaluation: reject a changed identity immediately

@Test func fingerprintChangeEvaluationTable() async throws {
  let changed = try expectedWarning(fingerprintA, fingerprintB)
  let cases: [(Seed, Data, CoreResult<FingerprintChangeOutcome>)] = [
    (.absent, fingerprintA, .success(.prompt)),
    (.stored(fingerprintA), fingerprintA, .success(.allow)),
    (.stored(fingerprintA), fingerprintB, .success(.identityChanged(changed))),
    (.stored(resized(fingerprintA, to: 31)), fingerprintA, .success(.reject(.trustRejected))),
    (.stored(resized(fingerprintA, to: 33)), fingerprintA, .success(.reject(.trustRejected))),
    (.stored(Data()), fingerprintB, .success(.reject(.trustRejected))),
    (.nonData, fingerprintA, .failure(unreadableStorageFailure)),
    (.stored(fingerprintA), Data(), .success(.reject(.trustRejected))),
  ]
  for (index, (seed, presented, expected)) in cases.enumerated() {
    let fake = keychain(seed)
    let before = fake.allItems
    #expect(await evaluate(fake, presented) == expected, "case \(index)")
    #expect(fake.mutations.isEmpty, "case \(index)")
    #expect(fake.allItems == before, "case \(index)")
  }
}

@Test func changedFingerprintRejectsImmediatelyWithAWarningAndNeverWrites() async throws {
  let fake = keychain(.stored(fingerprintA))
  let expected = try expectedWarning(fingerprintA, fingerprintB)
  for _ in 0..<3 {
    #expect(await evaluate(fake, fingerprintB) == .success(.identityChanged(expected)))
  }
  let one = account(deviceOne)
  #expect(fake.calls == [.read(account: one), .read(account: one), .read(account: one)])
  #expect(fake.allItems == [one: .data(fingerprintA)])
  #expect(await evaluate(fake, fingerprintA) == .success(.allow))
}

@Test func everySingleBitChangeOfThePresentedFingerprintCarriesAWarning() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let presented = flipping(fingerprintA, byte: offset, bit: bit)
      let expected = try expectedWarning(fingerprintA, presented)
      let result = await flow.evaluate(deviceID: deviceOne, presentedFingerprint: presented)
      #expect(result == .success(.identityChanged(expected)), "byte \(offset) bit \(bit)")
    }
  }
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

@Test(arguments: wrongLengths)
func wrongLengthPresentedFingerprintIsRejectedBeforeAnyKeychainRead(length: Int) async {
  let fake = keychain(.stored(fingerprintA))
  let presented = resized(fingerprintA, to: length)
  #expect(await evaluate(fake, presented) == .success(.reject(.trustRejected)))
  #expect(fake.calls.isEmpty)
}

@Test(arguments: wrongLengths)
func malformedStoredFingerprintRejectsWithoutAWarningOrAWrite(length: Int) async {
  let stored = resized(fingerprintA, to: length)
  let fake = keychain(.stored(stored))
  #expect(await evaluate(fake, fingerprintA) == .success(.reject(.trustRejected)))
  #expect(await evaluate(fake, fingerprintB) == .success(.reject(.trustRejected)))
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(stored)])
}

@Test(arguments: readFailureStatuses)
func changeEvaluationStorageFailureFailsClosed(status: OSStatus) async {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptReads([.status(status)])
  #expect(await evaluate(fake, fingerprintB) == .failure(storageFailure(status)))
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

// MARK: - The owner's explicit decision

@Test func ownerRejectKeepsTheTrustedRecordWithoutKeychainIO() async throws {
  let fake = keychain(.stored(fingerprintA))
  let evaluated = await evaluate(fake, fingerprintB)
  let warning = try #require(changeWarning(in: evaluated))
  let callsBefore = fake.calls

  #expect(await apply(fake, .reject, warning) == .success(.reject(.trustRejected)))
  #expect(fake.calls == callsBefore)
  #expect(await evaluate(fake, fingerprintB) == .success(.identityChanged(warning)))
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

@Test func repairReplacesTheRecordInAFixedOrderAndVerifiesBeforeAllowing() async throws {
  let fake = keychain(.stored(fingerprintA))
  let evaluated = await evaluate(fake, fingerprintB)
  let warning = try #require(changeWarning(in: evaluated))

  #expect(await apply(fake, .repair, warning) == .success(.allow))

  let one = account(deviceOne)
  #expect(
    fake.calls == [
      .read(account: one),  // the evaluation that produced the warning
      .read(account: one),  // the record still holds the trusted fingerprint
      .delete(account: one),  // the owner's replacement removes it
      .add(account: one),  // and inserts the presented fingerprint
      .read(account: one),  // a fresh read decides
    ])
  #expect(fake.added == [fingerprintB])
  #expect(fake.allItems == [one: .data(fingerprintB)])

  // The presented fingerprint is now the trusted one, and the old one is a change.
  let reversed = try expectedWarning(fingerprintB, fingerprintA)
  #expect(await evaluate(fake, fingerprintB) == .success(.allow))
  #expect(await evaluate(fake, fingerprintA) == .success(.identityChanged(reversed)))
}

@Test func repairIsIdempotentOnceThePresentedFingerprintIsStored() async throws {
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)

  let fake = keychain(.stored(fingerprintA))
  #expect(await apply(fake, .repair, warning) == .success(.allow))
  let callsAfterFirst = fake.calls.count
  #expect(await apply(fake, .repair, warning) == .success(.allow))
  #expect(fake.calls.count == callsAfterFirst + 1)
  #expect(fake.calls.last == .read(account: one))
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
  #expect(fake.allItems == [one: .data(fingerprintB)])

  // Already stored by someone else: one read, no write.
  let alreadyRepaired = keychain(.stored(fingerprintB))
  #expect(await apply(alreadyRepaired, .repair, warning) == .success(.allow))
  #expect(alreadyRepaired.calls == [.read(account: one)])
}

@Test func repairOnlyEverAddressesTheWarningsDevice() async throws {
  let fake = FakeKeychain(items: [
    account(deviceOne): .data(fingerprintA),
    account(deviceTwo): .data(fingerprintA),
  ])
  let evaluated = await evaluate(fake, fingerprintB, device: deviceOne)
  let warning = try #require(changeWarning(in: evaluated))

  #expect(await apply(fake, .repair, warning) == .success(.allow))
  #expect(
    fake.allItems == [
      account(deviceOne): .data(fingerprintB),
      account(deviceTwo): .data(fingerprintA),
    ])
  for call in fake.calls {
    switch call {
    case .read(let name), .add(let name), .delete(let name):
      #expect(name == account(deviceOne))
    }
  }

  let untouched = try expectedWarning(fingerprintA, fingerprintB, device: deviceTwo)
  let otherResult = await evaluate(fake, fingerprintB, device: deviceTwo)
  #expect(otherResult == .success(.identityChanged(untouched)))
}

// MARK: - A stale warning changes nothing

@Test func staleWarningRepairChangesNothingAndJudgesTheRecordAsRead() async throws {
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let current = try expectedWarning(fingerprintC, fingerprintB)
  let cases: [(Seed, CoreResult<FingerprintChangeOutcome>)] = [
    (.absent, .success(.prompt)),
    (.stored(fingerprintC), .success(.identityChanged(current))),
    (.stored(resized(fingerprintA, to: 31)), .success(.reject(.trustRejected))),
    (.stored(resized(fingerprintA, to: 33)), .success(.reject(.trustRejected))),
    (.nonData, .failure(unreadableStorageFailure)),
  ]
  for (index, (seed, expected)) in cases.enumerated() {
    let fake = keychain(seed)
    let before = fake.allItems
    #expect(await apply(fake, .repair, warning) == expected, "case \(index)")
    #expect(fake.calls == [.read(account: account(deviceOne))], "case \(index)")
    #expect(fake.allItems == before, "case \(index)")
  }
}

// MARK: - The transition fails closed at every step

@Test(arguments: readFailureStatuses)
func repairFailsClosedWhenTheRecordCannotBeRead(status: OSStatus) async throws {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptReads([.status(status)])
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  #expect(await apply(fake, .repair, warning) == .failure(storageFailure(status)))
  #expect(fake.calls == [.read(account: account(deviceOne))])
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

@Test(arguments: deleteFailureStatuses)
func repairRemovalFailureNeverInsertsAndKeepsTheTrustedRecord(status: OSStatus) async throws {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptDeletes([status])
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  #expect(await apply(fake, .repair, warning) == .failure(storageFailure(status)))
  #expect(fake.mutations == [.delete(account: account(deviceOne))])
  #expect(fake.added.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
  #expect(await evaluate(fake, fingerprintB) == .success(.identityChanged(warning)))
}

/// The one state the store cannot avoid: the old record is gone and the new
/// one could not be stored. The device is then unknown, so both fingerprints
/// prompt; neither is allowed, the old one is not restored, and nothing is
/// retried.
@Test(arguments: addFailureStatuses)
func repairInsertFailureAfterRemovalLeavesNoRecordAndNeverRestores(status: OSStatus) async throws {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptAdds([status])
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)

  #expect(await apply(fake, .repair, warning) == .failure(storageFailure(status)))
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
  #expect(fake.added == [fingerprintB])
  #expect(fake.allItems.isEmpty)

  #expect(await evaluate(fake, fingerprintB) == .success(.prompt))
  #expect(await evaluate(fake, fingerprintA) == .success(.prompt))
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
}

/// Success is reported only from a fresh read after the insert, and only when
/// that read allows the presented fingerprint.
@Test func repairSucceedsOnlyWhenTheFinalReadAllowsThePresentedFingerprint() async throws {
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let replaced = try expectedWarning(fingerprintC, fingerprintB)
  let one = account(deviceOne)
  let cases: [(KeychainItemReadReply, CoreResult<FingerprintChangeOutcome>)] = [
    (.data(fingerprintB), .success(.allow)),
    (.status(errSecItemNotFound), .success(.prompt)),
    (.data(fingerprintC), .success(.identityChanged(replaced))),
    (.data(fingerprintA), .success(.identityChanged(warning))),
    (.data(resized(fingerprintB, to: 31)), .success(.reject(.trustRejected))),
    (.nonData, .failure(unreadableStorageFailure)),
    (
      .status(errSecInteractionNotAllowed),
      .failure(storageFailure(errSecInteractionNotAllowed))
    ),
    (.status(errSecIO), .failure(storageFailure(errSecIO))),
  ]
  for (reply, expected) in cases {
    let fake = keychain(.stored(fingerprintA))
    fake.scriptReads([nil, reply])
    #expect(await apply(fake, .repair, warning) == expected, "final read: \(label(reply))")
    #expect(
      fake.calls == [
        .read(account: one), .delete(account: one), .add(account: one), .read(account: one),
      ])
    #expect(fake.allItems == [one: .data(fingerprintB)])
  }
}

/// Between removing the old record and inserting the new one the device has no
/// record. Anything that evaluates it then is prompted; nothing is allowed.
@Test(.timeLimit(.minutes(1)))
func repairGapBetweenRemovalAndInsertionNeverAllowsEitherFingerprint() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  fake.holdNext(.add)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()

  #expect(fake.item(for: account(deviceOne)) == nil)
  #expect(await evaluate(fake, fingerprintA) == .success(.prompt))
  #expect(await evaluate(fake, fingerprintB) == .success(.prompt))

  fake.releaseHeldCall()
  #expect(await task.value == .success(.allow))
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintB)])
}

@Test(.timeLimit(.minutes(1)))
func repairNeverReplacesARecordAnotherWriterStoresInTheGap() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)
  fake.holdNext(.add)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  fake.replaceItem(for: one, with: .data(fingerprintC))
  fake.releaseHeldCall()

  let current = try expectedWarning(fingerprintC, fingerprintB)
  #expect(await task.value == .success(.identityChanged(current)))
  #expect(fake.allItems == [one: .data(fingerprintC)])
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
  #expect(fake.added == [fingerprintB])
}

/// A duplicate that disappears before the store reads it back, for example
/// because a concurrent re-pair of the same warning removed it, fails closed
/// with the store's failure. Nothing is retried, and the device has no record.
@Test func repairFailsClosedWhenItsDuplicateVanishesBeforeItIsRead() async throws {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptAdds([errSecDuplicateItem])
  fake.scriptReads([nil, .status(errSecItemNotFound)])
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)

  #expect(await apply(fake, .repair, warning) == .failure(storageFailure(errSecItemNotFound)))
  #expect(
    fake.calls == [
      .read(account: one), .delete(account: one), .add(account: one), .read(account: one),
    ])
  #expect(fake.allItems.isEmpty)
  #expect(await evaluate(fake, fingerprintB) == .success(.prompt))
}

/// The store has no compare-and-delete. A record another writer stores
/// between the check and the removal is removed by it, and the presented
/// fingerprint the owner approved is stored instead. This pins the documented
/// limitation: only owner-approved fingerprints are ever stored.
@Test(.timeLimit(.minutes(1)))
func repairRemovalSupersedesARecordReplacedAfterTheCheck() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)
  fake.holdNext(.delete)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  fake.replaceItem(for: one, with: .data(fingerprintC))
  fake.releaseHeldCall()

  #expect(await task.value == .success(.allow))
  #expect(fake.allItems == [one: .data(fingerprintB)])
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
}

@Test(.timeLimit(.minutes(1)))
func repairAcceptsThePresentedFingerprintAnotherWriterStoresInTheGap() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)
  fake.holdNext(.add)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  fake.replaceItem(for: one, with: .data(fingerprintB))
  fake.releaseHeldCall()

  #expect(await task.value == .success(.allow))
  #expect(fake.allItems == [one: .data(fingerprintB)])
  #expect(fake.mutations == [.delete(account: one), .add(account: one)])
}

// MARK: - Cancellation

@Test func repairCancelledBeforeStartPerformsNoKeychainIO() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  let evaluated = await runCancelledBeforeStart {
    await flow.evaluate(deviceID: deviceOne, presentedFingerprint: fingerprintB)
  }
  let repaired = await runCancelledBeforeStart {
    await flow.apply(ownerDecision: .repair, warning: warning)
  }
  let declined = await runCancelledBeforeStart {
    await flow.apply(ownerDecision: .reject, warning: warning)
  }

  #expect(evaluated == .failure(cancellationFailure))
  #expect(repaired == .failure(cancellationFailure))
  #expect(declined == .success(.reject(.trustRejected)))
  #expect(fake.calls.isEmpty)
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

/// Removal never observes cancellation, so the flow observes it after its
/// check and before removal, while nothing has changed yet.
@Test(.timeLimit(.minutes(1)))
func repairCancelledAfterTheCheckLeavesTheTrustedRecord() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  fake.holdNext(.read)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  task.cancel()
  fake.releaseHeldCall()

  #expect(await task.value == .failure(cancellationFailure))
  #expect(fake.calls == [.read(account: account(deviceOne))])
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
}

/// Cancellation is honored only before removal. Once removal has been issued,
/// the insert of the approved fingerprint is issued too, so cancellation never
/// leaves the device without a record. The verifying read is refused for the
/// cancelled task, so the result is cancellation, never success.
@Test(.timeLimit(.minutes(1)))
func repairCancelledDuringRemovalStillStoresTheApprovedFingerprint() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)
  fake.holdNext(.delete)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  task.cancel()
  fake.releaseHeldCall()

  #expect(await task.value == .failure(cancellationFailure))
  #expect(fake.calls == [.read(account: one), .delete(account: one), .add(account: one)])
  #expect(fake.added == [fingerprintB])
  #expect(fake.allItems == [one: .data(fingerprintB)])
  #expect(await evaluate(fake, fingerprintB) == .success(.allow))
}

/// An issued insert completes and keeps its result, but the verifying read is
/// refused for the cancelled task, so the repair is never reported as a
/// success.
@Test(.timeLimit(.minutes(1)))
func repairCancelledDuringInsertionReportsCancellationNotSuccess() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)
  let one = account(deviceOne)
  fake.holdNext(.add)

  let task = Task { await flow.apply(ownerDecision: .repair, warning: warning) }
  await fake.waitUntilHeld()
  task.cancel()
  fake.releaseHeldCall()

  #expect(await task.value == .failure(cancellationFailure))
  #expect(fake.calls == [.read(account: one), .delete(account: one), .add(account: one)])
  #expect(fake.allItems == [one: .data(fingerprintB)])
}

// MARK: - Execution context, concurrency, inputs, and privacy

/// Keychain calls block their thread, so they must not run on the caller's
/// main actor.
@Test @MainActor func fingerprintChangeFlowRunsKeychainCallsOffTheCallersMainActor() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  _ = await flow.evaluate(deviceID: deviceOne, presentedFingerprint: fingerprintB)
  _ = await flow.apply(ownerDecision: .repair, warning: warning)

  #expect(fake.calls.count == 5)
  #expect(fake.mainThreadObservations == [false, false, false, false, false])
}

/// Concurrent re-pairs of one warning never store anything but the presented
/// fingerprint, and end with it stored. Each one answers `.allow`; `.prompt`
/// when a read lands in another re-pair's gap; or, when its insert finds a
/// duplicate that another re-pair removes before it is read back, the store's
/// fail-closed failure. None is rejected, and none fails any other way.
@Test func concurrentRepairsOfOneWarningConvergeOnThePresentedFingerprint() async throws {
  let fake = keychain(.stored(fingerprintA))
  let flow = makeFlow(fake)
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  let results = await withTaskGroup(of: CoreResult<FingerprintChangeOutcome>.self) { group in
    for _ in 0..<16 {
      group.addTask { await flow.apply(ownerDecision: .repair, warning: warning) }
    }
    var collected: [CoreResult<FingerprintChangeOutcome>] = []
    for await result in group { collected.append(result) }
    return collected
  }

  let permitted: [CoreResult<FingerprintChangeOutcome>] = [
    .success(.allow), .success(.prompt), .failure(storageFailure(errSecItemNotFound)),
  ]
  #expect(results.count == 16)
  #expect(results.allSatisfy { permitted.contains($0) })
  #expect(results.contains(.success(.allow)))
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintB)])
  #expect(fake.added.allSatisfy { $0 == fingerprintB })
}

@Test func concurrentChangeEvaluationsAgreeAndNeverWrite() async throws {
  let fake = FakeKeychain(items: [
    account(deviceOne): .data(fingerprintA),
    account(deviceTwo): .data(resized(fingerprintB, to: 31)),
  ])
  let flow = makeFlow(fake)
  let thirdDevice = DeviceID(rawValue: UUID(uuidString: "5EED0590-ABCD-4EF0-8A1B-C2D3E4F50003")!)
  let changed = try expectedWarning(fingerprintA, fingerprintB)
  let cases: [(DeviceID, Data)] = [
    (deviceOne, fingerprintA), (deviceOne, fingerprintB), (deviceTwo, fingerprintB),
    (thirdDevice, fingerprintA), (deviceOne, Data()),
  ]
  let expected: [CoreResult<FingerprintChangeOutcome>] = [
    .success(.allow), .success(.identityChanged(changed)), .success(.reject(.trustRejected)),
    .success(.prompt), .success(.reject(.trustRejected)),
  ]

  await withTaskGroup(of: (Int, CoreResult<FingerprintChangeOutcome>).self) { group in
    for _ in 0..<16 {
      for (index, (device, presented)) in cases.enumerated() {
        group.addTask {
          let result = await flow.evaluate(deviceID: device, presentedFingerprint: presented)
          return (index, result)
        }
      }
    }
    for await (index, result) in group {
      #expect(result == expected[index], "case \(index)")
    }
  }
  #expect(fake.mutations.isEmpty)
}

@Test func fingerprintChangeFailuresCarryNoDeviceOrFingerprintPayload() async throws {
  let warning = try expectedWarning(fingerprintA, fingerprintB)

  let readFails = keychain(.stored(fingerprintA))
  readFails.scriptReads([.status(errSecInteractionNotAllowed)])
  let removalFails = keychain(.stored(fingerprintA))
  removalFails.scriptDeletes([errSecIO])
  let insertFails = keychain(.stored(fingerprintA))
  insertFails.scriptAdds([errSecNotAvailable])
  let verificationFails = keychain(.stored(fingerprintA))
  verificationFails.scriptReads([nil, .nonData])
  let cancelled = keychain(.stored(fingerprintA))

  let evaluated = await evaluate(readFails, fingerprintB)
  let removed = await apply(removalFails, .repair, warning)
  let inserted = await apply(insertFails, .repair, warning)
  let verified = await apply(verificationFails, .repair, warning)
  let cancelledResult = await runCancelledBeforeStart {
    await apply(cancelled, .repair, warning)
  }

  let allowedKeys: Set<String> = [
    "code", "severity", "retryDisposition", "cleanupDisposition", "underlyingDiagnosticCode",
  ]
  for result in [evaluated, removed, inserted, verified, cancelledResult] {
    let error = try #require(result.failureValue)
    let encoded = try JSONEncoder().encode(error)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys).isSubset(of: allowedKeys))

    let renderings = [
      try #require(String(data: encoded, encoding: .utf8)),
      String(describing: error),
      String(reflecting: error),
    ]
    for rendering in renderings {
      for token in forbiddenRenderingTokens {
        #expect(!rendering.contains(token), "a failure carries a fingerprint or device")
      }
    }
  }
}

@Test func fingerprintChangeInputsAreNotMutatedAndSlicesAreCopiedByContent() async throws {
  let buffer = Data([0xEE, 0xEE]) + fingerprintB + Data([0xEE])
  let slice = buffer[2..<34]
  try #require(slice.startIndex == 2)

  let fake = keychain(.stored(fingerprintA))
  let evaluated = await evaluate(fake, slice)
  let warning = try #require(changeWarning(in: evaluated))
  #expect(warning == (try expectedWarning(fingerprintA, fingerprintB)))
  #expect(warning.presentedFingerprint.startIndex == 0)
  #expect(warning.presentedFingerprintDisplay == fingerprintBDisplay)

  #expect(await apply(fake, .repair, warning) == .success(.allow))
  #expect(fake.added == [fingerprintB])
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintB)])
  #expect(await evaluate(fake, slice) == .success(.allow))
  #expect(slice == fingerprintB)
  #expect(buffer == Data([0xEE, 0xEE]) + fingerprintB + Data([0xEE]))
}

/// Static audit of the flow's source. **It proves what the source names, not
/// what runs.** The flow reaches the Keychain only through the store, whose
/// seam has no update operation, and it has no way to log, print, or persist
/// anything itself.
@Test func fingerprintChangeFlowSourceNeverLogsOrBypassesTheStore() throws {
  let source = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")
    .appendingPathComponent("MacPlatform")
    .appendingPathComponent("FingerprintChangeFlow.swift")
  let text = try String(contentsOf: source, encoding: .utf8)
  try #require(text.contains("struct FingerprintChangeFlow"))

  let forbidden = [
    "Sec" + "Item", "KeychainTrustStore" + "Environment", "KeychainTrustStore" + "()",
    "NS" + "Log", "os" + "_log", "Log" + "ger", "User" + "Defaults", "File" + "Manager",
    "File" + "Handle", "Process" + "Info",
  ]
  for token in forbidden {
    #expect(!text.contains(token), "the flow source names \(token)")
  }

  // Whole identifiers only, so a call such as `loadFingerprint(` does not count.
  #expect(callsFunction(named: "print", in: "_ = 1\n  print(value)"))
  #expect(!callsFunction(named: "print", in: "await store.loadFingerprint(for: deviceID)"))
  for function in ["print", "debug" + "Print", "dump"] {
    #expect(!callsFunction(named: function, in: text), "the flow source calls \(function)")
  }
}

/// Whether `text` calls `name`: the name, not preceded by an identifier
/// character, followed by an opening parenthesis.
private func callsFunction(named name: String, in text: String) -> Bool {
  text.range(of: "(?<![A-Za-z0-9_])" + name + "\\(", options: .regularExpression) != nil
}

// MARK: - Tier-H manual probe vocabulary and sequencing

/// The exact action names the manual probe accepts. Anything else is refused.
private enum ManualProbeAction: String, CaseIterable {
  /// Runs the fingerprint change flow once against one fixed synthetic record.
  case fingerprintChangeRepairRoundTrip = "fingerprint-change-repair-round-trip"
}

private enum ManualProbeSelection: Equatable {
  case notSelected
  case selected(ManualProbeAction)
  case unknown
}

/// Parses the reviewer's selection, failing closed on anything unrecognized.
private func manualProbeSelection(from rawValue: String?) -> ManualProbeSelection {
  guard let rawValue else { return .notSelected }
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return .notSelected }
  guard let action = ManualProbeAction(rawValue: trimmed) else { return .unknown }
  return .selected(action)
}

/// A fixed synthetic device used only by the probe. It is never printed.
private let manualProbeDeviceID = DeviceID(
  rawValue: UUID(uuidString: "5EED0590-F1A5-4E05-8059-0000000F1A59")!
)
private let manualProbeTrustedFingerprint = fingerprintA
private let manualProbePresentedFingerprint = fingerprintB

/// One step's result in closed vocabulary.
private enum ManualProbeStepState: Equatable {
  case notAttempted
  case outcome(String)
  case failed(CoreError)

  init(_ result: CoreResult<FingerprintChangeOutcome>) {
    switch result {
    case .success(let outcome): self = .outcome(label(outcome))
    case .failure(let error): self = .failed(error)
    }
  }

  init(firstUse result: CoreResult<FirstUseTrustOutcome>) {
    switch result {
    case .success(let outcome): self = .outcome(label(outcome))
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .outcome(let name): name
    case .failed(let error): sanitizedFailureName(error)
    }
  }
}

/// Whether the warning showed exactly the two fingerprints involved, for the
/// probe's device. The fingerprints themselves are never reported.
private enum ManualProbeWarningState: Equatable {
  case notAttempted
  case match
  case mismatch

  init(_ warning: FingerprintChangeWarning) {
    let matches =
      warning.deviceID == manualProbeDeviceID
      && warning.trustedFingerprint == manualProbeTrustedFingerprint
      && warning.presentedFingerprint == manualProbePresentedFingerprint
      && warning.trustedFingerprintDisplay == fingerprintADisplay
      && warning.presentedFingerprintDisplay == fingerprintBDisplay
    self = matches ? .match : .mismatch
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .match: "match"
    case .mismatch: "mismatch"
    }
  }
}

private enum ManualProbeRemoveState: Equatable {
  case notAttempted
  case removed
  case failed(CoreError)

  init(_ result: CoreResult<Void>) {
    switch result {
    case .success: self = .removed
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .removed: "removed"
    case .failed(let error): sanitizedFailureName(error)
    }
  }
}

/// Whether a record exists. A present record's bytes are never reported.
private enum ManualProbeLoadState: Equatable {
  case notAttempted
  case absent
  case present
  case failed(CoreError)

  init(_ result: CoreResult<Data?>) {
    switch result {
    case .success(.none): self = .absent
    case .success(.some): self = .present
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .absent: "absent"
    case .present: "present"
    case .failed(let error): sanitizedFailureName(error)
    }
  }
}

private struct ManualProbeResult: Equatable {
  var initialCleanup: ManualProbeRemoveState = .notAttempted
  var seedTrust: ManualProbeStepState = .notAttempted
  var changed: ManualProbeStepState = .notAttempted
  var warning: ManualProbeWarningState = .notAttempted
  var declined: ManualProbeStepState = .notAttempted
  var afterDecline: ManualProbeStepState = .notAttempted
  var repair: ManualProbeStepState = .notAttempted
  var presented: ManualProbeStepState = .notAttempted
  var previous: ManualProbeStepState = .notAttempted
  var repeatRepair: ManualProbeStepState = .notAttempted
  var finalCleanup: ManualProbeRemoveState = .notAttempted
  var afterCleanup: ManualProbeLoadState = .notAttempted
}

/// The result a correct flow produces, starting from any state of the one
/// synthetic record.
private let expectedManualProbeResult = ManualProbeResult(
  initialCleanup: .removed,
  seedTrust: .outcome("allow"),
  changed: .outcome("identityChanged"),
  warning: .match,
  declined: .outcome("reject.trustRejected"),
  afterDecline: .outcome("identityChanged"),
  repair: .outcome("allow"),
  presented: .outcome("allow"),
  previous: .outcome("identityChanged"),
  repeatRepair: .outcome("allow"),
  finalCleanup: .removed,
  afterCleanup: .absent
)

/// Runs the fingerprint change round trip once, in a fixed order, against
/// `store`.
///
/// It starts by removing the synthetic record, so a leftover from an earlier
/// interrupted run cannot change the outcome. It then trusts one fingerprint
/// through the first-use flow, presents a different one, declines, re-pairs,
/// checks both fingerprints, and re-pairs again. The middle steps stop at the
/// first unexpected result, and the final cleanup and absence check run on
/// every path, so a record written by this probe is always asked to be
/// removed. Nothing sleeps, polls, or retries. Ordinary tests pass a store over
/// the in-memory fake; only the opt-in probe passes the production environment.
private func performManualFingerprintChangeProbe(
  store: KeychainTrustStore
) async -> ManualProbeResult {
  let firstUse = FirstUseTrustCoordinator(store: store)
  let flow = FingerprintChangeFlow(store: store)
  let device = manualProbeDeviceID
  let trusted = manualProbeTrustedFingerprint
  let presented = manualProbePresentedFingerprint
  let expected = expectedManualProbeResult
  var result = ManualProbeResult()

  result.initialCleanup = await ManualProbeRemoveState(store.removeFingerprint(for: device))

  steps: do {
    guard result.initialCleanup == expected.initialCleanup else { break steps }

    result.seedTrust = await ManualProbeStepState(
      firstUse: firstUse.apply(
        ownerDecision: .trust, deviceID: device, presentedFingerprint: trusted))
    guard result.seedTrust == expected.seedTrust else { break steps }

    let evaluation = await flow.evaluate(deviceID: device, presentedFingerprint: presented)
    result.changed = ManualProbeStepState(evaluation)
    guard let warning = changeWarning(in: evaluation) else { break steps }
    result.warning = ManualProbeWarningState(warning)
    guard result.warning == expected.warning else { break steps }

    result.declined = await ManualProbeStepState(
      flow.apply(ownerDecision: .reject, warning: warning))
    guard result.declined == expected.declined else { break steps }

    result.afterDecline = await ManualProbeStepState(
      flow.evaluate(deviceID: device, presentedFingerprint: presented))
    guard result.afterDecline == expected.afterDecline else { break steps }

    result.repair = await ManualProbeStepState(
      flow.apply(ownerDecision: .repair, warning: warning))
    guard result.repair == expected.repair else { break steps }

    result.presented = await ManualProbeStepState(
      flow.evaluate(deviceID: device, presentedFingerprint: presented))
    guard result.presented == expected.presented else { break steps }

    result.previous = await ManualProbeStepState(
      flow.evaluate(deviceID: device, presentedFingerprint: trusted))
    guard result.previous == expected.previous else { break steps }

    result.repeatRepair = await ManualProbeStepState(
      flow.apply(ownerDecision: .repair, warning: warning))
  }

  result.finalCleanup = await ManualProbeRemoveState(store.removeFingerprint(for: device))
  result.afterCleanup = await ManualProbeLoadState(store.loadFingerprint(for: device))
  return result
}

private let manualProbeLinePrefix = "M1-059 manual probe: "

/// Renders the one sanitized line the reviewer transcribes into `manual.md`.
///
/// Every field is a closed enum case or a closed `CoreError` taxonomy name. No
/// device identifier, account, service, status value, or fingerprint can reach
/// this output, because no such value is passed to it.
private func manualProbeLine(action: ManualProbeAction, result: ManualProbeResult) -> String {
  let fields = [
    "action=\(action.rawValue)",
    "initialCleanup=\(result.initialCleanup.closedName)",
    "seedTrust=\(result.seedTrust.closedName)",
    "changed=\(result.changed.closedName)",
    "warning=\(result.warning.closedName)",
    "declined=\(result.declined.closedName)",
    "afterDecline=\(result.afterDecline.closedName)",
    "repair=\(result.repair.closedName)",
    "presented=\(result.presented.closedName)",
    "previous=\(result.previous.closedName)",
    "repeatRepair=\(result.repeatRepair.closedName)",
    "finalCleanup=\(result.finalCleanup.closedName)",
    "afterCleanup=\(result.afterCleanup.closedName)",
  ]
  return manualProbeLinePrefix + fields.joined(separator: " ")
}

/// Maps a failure to a closed taxonomy name. The diagnostic status is
/// deliberately dropped.
private func sanitizedFailureName(_ error: CoreError) -> String {
  let retry = error.retryDisposition.rawValue
  switch error.code {
  case .security(let code): return "failed.security.\(code.rawValue).\(retry)"
  case .cancellation(let reason): return "failed.cancellation.\(reason.rawValue).\(retry)"
  default: return "failed.unexpectedDomain.\(error.domain.rawValue)"
  }
}

/// Every value a probe field other than `action` may take.
private func everyClosedProbeValue() -> Set<String> {
  var names: Set<String> = [
    "notAttempted", "prompt", "allow", "identityChanged", "removed", "absent", "present", "match",
    "mismatch",
  ]
  for code in SecurityErrorCode.allCases {
    names.insert("reject.\(code.rawValue)")
    for retry in RetryDisposition.allCases {
      names.insert("failed.security.\(code.rawValue).\(retry.rawValue)")
    }
  }
  for reason in CancellationReason.allCases {
    for retry in RetryDisposition.allCases {
      names.insert("failed.cancellation.\(reason.rawValue).\(retry.rawValue)")
    }
  }
  for domain in CoreErrorDomain.allCases {
    names.insert("failed.unexpectedDomain.\(domain.rawValue)")
  }
  return names
}

@Test func manualFingerprintChangeProbeSelectionFailsClosedAndIsSkippedByDefault() {
  #expect(manualProbeSelection(from: nil) == .notSelected)
  #expect(manualProbeSelection(from: "") == .notSelected)
  #expect(manualProbeSelection(from: " \n\t") == .notSelected)

  #expect(
    manualProbeSelection(from: " fingerprint-change-repair-round-trip\n")
      == .selected(.fingerprintChangeRepairRoundTrip))

  let rejected = [
    "FINGERPRINT-CHANGE-REPAIR-ROUND-TRIP", "fingerprint", "repair", "round-trip", "live", "1",
    "true", "keychain-first-use-round-trip", "fingerprint-change-repair-round-trip;cleanup",
    "fingerprint-change-repair-round-trip repair", "fingerprint_change_repair_round_trip",
  ]
  for value in rejected {
    #expect(manualProbeSelection(from: value) == .unknown)
  }

  #expect(ManualProbeAction.allCases.map(\.rawValue) == ["fingerprint-change-repair-round-trip"])
}

@Test func manualFingerprintChangeProbeProducesTheExpectedClosedResultOnAFake() async {
  let probeAccount = account(manualProbeDeviceID)
  // A leftover from an interrupted run, plus an unrelated record that must survive.
  let fake = FakeKeychain(items: [
    probeAccount: .data(manualProbePresentedFingerprint),
    account(deviceOne): .data(fingerprintC),
  ])

  let result = await performManualFingerprintChangeProbe(store: makeStore(fake))

  #expect(result == expectedManualProbeResult)
  #expect(
    fake.mutations == [
      .delete(account: probeAccount),  // initial cleanup
      .add(account: probeAccount),  // first-use trust
      .delete(account: probeAccount),  // re-pair: remove
      .add(account: probeAccount),  // re-pair: insert
      .delete(account: probeAccount),  // final cleanup
    ])
  #expect(fake.calls.last == .read(account: probeAccount))
  #expect(fake.added == [manualProbeTrustedFingerprint, manualProbePresentedFingerprint])
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintC)])
  for call in fake.calls {
    switch call {
    case .read(let name), .add(let name), .delete(let name): #expect(name == probeAccount)
    }
  }

  let expectedLine = """
    M1-059 manual probe: action=fingerprint-change-repair-round-trip initialCleanup=removed \
    seedTrust=allow changed=identityChanged warning=match declined=reject.trustRejected \
    afterDecline=identityChanged repair=allow presented=allow previous=identityChanged \
    repeatRepair=allow finalCleanup=removed afterCleanup=absent
    """
  #expect(
    manualProbeLine(action: .fingerprintChangeRepairRoundTrip, result: result) == expectedLine)
}

/// Every normal failure path still asks for the final cleanup and checks
/// absence, and a failure is reported by name rather than hidden.
@Test func manualFingerprintChangeProbeCleansUpOnEveryFailurePath() async {
  let probeAccount = account(manualProbeDeviceID)

  // The initial cleanup fails: nothing is written, and cleanup is asked for again at the end.
  let initialFails = FakeKeychain()
  initialFails.scriptDeletes([errSecInteractionNotAllowed])
  let first = await performManualFingerprintChangeProbe(store: makeStore(initialFails))
  #expect(first.initialCleanup == .failed(storageFailure(errSecInteractionNotAllowed)))
  #expect(first.seedTrust == .notAttempted)
  #expect(first.repair == .notAttempted)
  #expect(first.finalCleanup == .removed)
  #expect(first.afterCleanup == .absent)
  #expect(initialFails.added.isEmpty)
  #expect(
    initialFails.mutations == [.delete(account: probeAccount), .delete(account: probeAccount)])

  // The first-use trust cannot be stored.
  let seedFails = FakeKeychain()
  seedFails.scriptAdds([errSecNotAvailable])
  let second = await performManualFingerprintChangeProbe(store: makeStore(seedFails))
  #expect(second.seedTrust == .failed(storageFailure(errSecNotAvailable)))
  #expect(second.changed == .notAttempted)
  #expect(second.finalCleanup == .removed)
  #expect(second.afterCleanup == .absent)
  #expect(seedFails.allItems.isEmpty)

  // The re-pair removes the trusted record and then cannot insert the presented one.
  let repairFails = FakeKeychain()
  repairFails.scriptAdds([nil, errSecIO])
  let third = await performManualFingerprintChangeProbe(store: makeStore(repairFails))
  #expect(third.declined == .outcome("reject.trustRejected"))
  #expect(third.repair == .failed(storageFailure(errSecIO)))
  #expect(third.presented == .notAttempted)
  #expect(third.finalCleanup == .removed)
  #expect(third.afterCleanup == .absent)
  #expect(repairFails.allItems.isEmpty)

  // The final cleanup itself fails: the leftover is reported, not hidden.
  let finalFails = FakeKeychain()
  finalFails.scriptDeletes([nil, nil, errSecInteractionNotAllowed])
  let fourth = await performManualFingerprintChangeProbe(store: makeStore(finalFails))
  #expect(fourth.repeatRepair == .outcome("allow"))
  #expect(fourth.finalCleanup == .failed(storageFailure(errSecInteractionNotAllowed)))
  #expect(fourth.afterCleanup == .present)

  for result in [first, second, third, fourth] {
    #expect(result != expectedManualProbeResult)
  }
}

@Test func manualFingerprintChangeProbeOutputIsClosedVocabularyOnly() throws {
  let noisy = ManualProbeResult(
    initialCleanup: .failed(storageFailure(errSecInteractionNotAllowed)),
    seedTrust: .failed(storageFailure(Int32.min)),
    changed: .failed(cancellationFailure),
    warning: .mismatch,
    declined: .outcome("reject.trustRejected"),
    afterDecline: .failed(unreadableStorageFailure),
    repair: .failed(storageFailure(errSecMissingEntitlement)),
    presented: .failed(
      CoreError(
        code: .internalFailure(.unclassified),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .notRequired,
        underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: 4242)
      )),
    previous: .outcome("prompt"),
    repeatRepair: .failed(storageFailure(Int32.max)),
    finalCleanup: .failed(storageFailure(errSecIO)),
    afterCleanup: .present
  )
  let closed = everyClosedProbeValue()
  let forbidden =
    forbiddenRenderingTokens + [
      account(manualProbeDeviceID), account(manualProbeDeviceID).uppercased(),
      KeychainTrustStoreEnvironment.productionService, "errSec", "OSStatus",
    ]

  for result in [noisy, expectedManualProbeResult, ManualProbeResult()] {
    let line = manualProbeLine(action: .fingerprintChangeRepairRoundTrip, result: result)
    try #require(line.hasPrefix(manualProbeLinePrefix))
    let body = String(line.dropFirst(manualProbeLinePrefix.count))

    #expect(!body.contains { $0.isNumber }, "a status value or identifier reached the output")
    for token in forbidden {
      #expect(!line.contains(token))
    }

    let fields = body.split(separator: " ")
    #expect(fields.count == 13)
    for field in fields {
      let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
      try #require(parts.count == 2)
      if parts[0] == "action" {
        #expect(parts[1] == "fingerprint-change-repair-round-trip")
      } else {
        #expect(closed.contains(parts[1]), "field \(parts[0]) is outside the closed vocabulary")
      }
    }
  }
}

// MARK: - Source ownership audit

/// Static source audit of this file. **It proves what the source names, not
/// what runs.**
///
/// The file is split at the one line that opens the Tier-H live region. Every
/// ordinary test lives above it, and the text above it, comments included,
/// names no production environment, no production initializer call, no
/// platform Keychain call, and no process environment. Below it, the live
/// region names the production environment exactly once, holds exactly one
/// test gated on the reviewer's selection, prints only the closed probe line,
/// and calls no platform Keychain function directly.
///
/// Each token is assembled from two literals, so the audit's own source never
/// contains a token it forbids.
@Test func onlyTheTierHRegionNamesTheProductionSeamForTheChangeProbe() throws {
  let source = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
  let regions = source.components(separatedBy: "// MARK: - Tier-H " + "live region")
  try #require(regions.count == 2, "the live region must open exactly once")
  let ordinary = regions[0]
  let live = regions[1]

  let platformCalls = [
    "SecItem" + "CopyMatching", "SecItem" + "Add", "SecItem" + "Update", "SecItem" + "Delete",
  ]
  let ordinaryForbidden =
    platformCalls + [
      "." + "live",
      "KeychainTrustStore" + "()",
      "Process" + "Info",
      "MACKVM_M1_059_" + "MANUAL_PROBE",
    ]
  for token in ordinaryForbidden {
    #expect(!ordinary.contains(token), "an ordinary route names \(token)")
  }

  let liveForbidden =
    platformCalls + [
      "KeychainTrustStore" + "()",
      "Fake" + "Keychain",
    ]
  for token in liveForbidden {
    #expect(!live.contains(token), "the live region names \(token)")
  }
  #expect(live.components(separatedBy: "KeychainTrustStoreEnvironment." + "live").count == 2)
  #expect(live.components(separatedBy: "@" + "Test").count == 2)
  #expect(live.contains("if: selectedManualProbe() != " + ".notSelected"))
  #expect(live.components(separatedBy: "print" + "(").count == 2)
  #expect(live.contains("print" + "(manualProbeLine("))
}

// MARK: - Tier-H live region

/// Environment variable that selects the one real-Keychain action.
///
/// Unset — the case for every ordinary CI and local run — leaves the probe
/// skipped, so no automated run reads or writes the real Keychain.
private let manualProbeActionKey = "MACKVM_M1_059_MANUAL_PROBE"

private func selectedManualProbe() -> ManualProbeSelection {
  manualProbeSelection(from: ProcessInfo.processInfo.environment[manualProbeActionKey])
}

/// Reviewer-driven Tier-H probe. **Not an automated acceptance test.**
///
/// It drives the production environment, the same one the shipped initializer
/// uses, against the real data-protection Keychain, with one fixed synthetic
/// device and two published SHA-256 vectors as fingerprints.
///
/// Safety properties:
///
/// - skipped unless the reviewer names the action; an unknown value fails
///   closed and touches nothing;
/// - only the one synthetic record is ever read, written, or deleted; it is
///   removed first, so a leftover cannot skew the result, and removed again on
///   every normal path, with absence checked afterwards;
/// - no sleep, poll, retry, or timer; and
/// - output is closed vocabulary only: never the device identifier, service,
///   account, status value, fingerprint, or the environment value.
///
/// The sequencing in `performManualFingerprintChangeProbe` is covered by
/// ordinary always-running tests on the in-memory fake; this probe adds only
/// the real platform.
@Test(
  .enabled(
    if: selectedManualProbe() != .notSelected,
    "manual Tier-H probe: set MACKVM_M1_059_MANUAL_PROBE to fingerprint-change-repair-round-trip"
  )
)
func manualFingerprintChangeProbeRunsTheRealRepairRoundTrip() async {
  guard case .selected(let action) = selectedManualProbe() else {
    // The unrecognized value is deliberately not echoed.
    Issue.record("unknown manual probe action; expected fingerprint-change-repair-round-trip")
    return
  }

  let store = KeychainTrustStore(environment: KeychainTrustStoreEnvironment.live)
  let result = await performManualFingerprintChangeProbe(store: store)

  print(manualProbeLine(action: action, result: result))

  if result != expectedManualProbeResult {
    Issue.record("the real Keychain path did not produce the expected closed result")
  }
}

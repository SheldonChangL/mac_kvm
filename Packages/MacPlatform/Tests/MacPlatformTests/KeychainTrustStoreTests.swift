import Foundation
import KVMContracts
import Security
import Testing

@testable import MacPlatform

// MARK: - Expected internal/package surface
//
// These tests drive the M1-058 trust store and first-use coordinator through a
// small package/internal seam. Nothing below is public.
//
//   package enum FirstUseOwnerDecision: Equatable, Sendable { case trust; case reject }
//   package enum FirstUseTrustOutcome: Equatable, Sendable
//     { case prompt; case allow; case reject(SecurityErrorCode) }
//
//   enum KeychainItemReadReply: Equatable, Sendable {
//     case data(Data)          // the platform read succeeded with a data result
//     case nonData             // it succeeded with no result or a non-data result
//     case status(OSStatus)    // any other status, including item-not-found
//   }
//
//   struct KeychainTrustStoreEnvironment: Sendable {
//     var readItem: @Sendable (_ account: String) async -> KeychainItemReadReply
//     var addItem: @Sendable (_ account: String, _ fingerprint: Data) async -> OSStatus
//     var deleteItem: @Sendable (_ account: String) async -> OSStatus
//     static let live: KeychainTrustStoreEnvironment   // production, off the caller
//     static let productionService: String            // fixed and versioned
//     static func account(for deviceID: DeviceID) -> String
//     static func readQuery(account: String) -> [String: Any]
//     static func addQuery(account: String, fingerprint: Data) -> [String: Any]
//     static func deleteQuery(account: String) -> [String: Any]
//   }
//
//   package enum KeychainTrustInsertOutcome: Equatable, Sendable
//     { case inserted; case existing(storedFingerprint: Data) }
//
//   package struct KeychainTrustStore: Sendable {
//     package init()                                       // production
//     init(environment: KeychainTrustStoreEnvironment)
//     func loadFingerprint(for: DeviceID) async -> CoreResult<Data?>
//     func insertFingerprintIfAbsent(_: Data, for: DeviceID) async
//       -> CoreResult<KeychainTrustInsertOutcome>
//     func removeFingerprint(for: DeviceID) async -> CoreResult<Void>
//   }
//
//   package struct FirstUseTrustCoordinator: Sendable {
//     init(store: KeychainTrustStore)
//     func evaluate(deviceID:presentedFingerprint:) async
//       -> CoreResult<FirstUseTrustOutcome>
//     func apply(ownerDecision:deviceID:presentedFingerprint:) async
//       -> CoreResult<FirstUseTrustOutcome>
//   }
//
// The environment has exactly three operations: read, add and delete. There is
// no update operation, so an existing record can never be overwritten.
//
// Status mapping (store level):
//   read   success+data → the bytes as stored; item-not-found → missing (nil);
//          success without data → unreadable failure; anything else → failure.
//   add    success → inserted; duplicate-item → read the existing record and
//          report it; anything else → failure. Never retried.
//   delete success or item-not-found → success; anything else → failure.
//
// Every storage failure is `.security(.secureStorageUnavailable)`, severity
// `.error`, cleanup `.notRequired`, carrying only the raw status as
// `UnderlyingDiagnosticCode`. Interaction and authentication statuses are
// `.userActionRequired`; all others are `.never`. An unreadable (non-data)
// result carries no diagnostic code. Cancellation observed before any Keychain
// operation is `.cancellation(.requested)`, `.info`, `.never`, `.notRequired`.
//
// Coordinator:
//   evaluate  invalid presented length → reject(.trustRejected) with no I/O;
//             missing → prompt; same → allow; different → reject(.identityChanged);
//             malformed stored → reject(.trustRejected); storage failure → failure.
//   apply     .reject → reject(.trustRejected), never writes.
//             .trust  → invalid length rejects with no I/O; otherwise add-if-absent:
//             inserted → allow; existing same → allow; existing different →
//             reject(.identityChanged); existing malformed → reject(.trustRejected);
//             storage failure → failure. Once an add is issued its real result is
//             reported, even if the task is cancelled meanwhile.
//
// No automated test here touches the real Keychain. Ordinary tests only ever
// use the in-memory fake below; the static audit at the end of the ordinary
// region proves the production environment is named only in the Tier-H region.

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

private let deviceOne = DeviceID(
  rawValue: UUID(uuidString: "5EED0580-ABCD-4EF0-8A1B-C2D3E4F50001")!
)
private let deviceTwo = DeviceID(
  rawValue: UUID(uuidString: "5EED0580-ABCD-4EF0-8A1B-C2D3E4F50002")!
)

private let wrongLengths = [0, 1, 16, 20, 31, 33, 48, 64, 95, 4096]

/// Statuses that mean a person must unlock, authenticate, or allow interaction.
private let interactionStatuses: [OSStatus] = [
  errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled,
]

/// Statuses no person can resolve by interacting, plus arbitrary values.
private let nonInteractiveStatuses: [OSStatus] = [
  errSecNotAvailable, errSecMissingEntitlement, errSecParam, errSecAllocate, errSecDecode,
  errSecIO, errSecUnimplemented, -1, 1, Int32.min, Int32.max,
]

private let readFailureStatuses =
  interactionStatuses + nonInteractiveStatuses + [errSecDuplicateItem]
private let addFailureStatuses = interactionStatuses + nonInteractiveStatuses + [errSecItemNotFound]
private let deleteFailureStatuses =
  interactionStatuses + nonInteractiveStatuses + [errSecDuplicateItem]

// MARK: - Deterministic in-memory Keychain

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
/// `nil` entry means "behave normally". Each test owns its own instance, so tests
/// are deterministic and safe in parallel.
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
  private var readReplyWhileStored: KeychainItemReadReply?
  private var holdNextAddRequested = false
  private var heldAdd: CheckedContinuation<Void, Never>?
  private var addIsHeld = false
  private var heldAddWaiters: [CheckedContinuation<Void, Never>] = []

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

  func scriptReads(_ replies: [KeychainItemReadReply?]) {
    lock.withLock { readScript = replies }
  }

  func scriptAdds(_ statuses: [OSStatus?]) {
    lock.withLock { addScript = statuses }
  }

  func scriptDeletes(_ statuses: [OSStatus?]) {
    lock.withLock { deleteScript = statuses }
  }

  /// Makes every read of an account that currently holds a record answer
  /// `reply`. Reads of absent accounts behave normally.
  func failReadsWhileStored(with reply: KeychainItemReadReply) {
    lock.withLock { readReplyWhileStored = reply }
  }

  /// Makes the next add suspend, before it changes anything, until
  /// `releaseHeldAdd()` is called.
  func holdNextAdd() {
    lock.withLock { holdNextAddRequested = true }
  }

  func waitUntilAddIsHeld() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let alreadyHeld: Bool = lock.withLock {
        if addIsHeld { return true }
        heldAddWaiters.append(continuation)
        return false
      }
      if alreadyHeld { continuation.resume() }
    }
  }

  func releaseHeldAdd() {
    let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
      defer { heldAdd = nil }
      return heldAdd
    }
    continuation?.resume()
  }

  var environment: KeychainTrustStoreEnvironment {
    KeychainTrustStoreEnvironment(
      readItem: { account in self.recordRead(account) },
      addItem: { account, fingerprint in
        await self.pauseIfHoldingAdd()
        return self.recordAdd(account, fingerprint)
      },
      deleteItem: { account in self.recordDelete(account) }
    )
  }

  private func pauseIfHoldingAdd() async {
    let shouldHold: Bool = lock.withLock {
      defer { holdNextAddRequested = false }
      return holdNextAddRequested
    }
    guard shouldHold else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        heldAdd = continuation
        addIsHeld = true
        defer { heldAddWaiters = [] }
        return heldAddWaiters
      }
      for waiter in waiters { waiter.resume() }
    }
  }

  private func recordRead(_ account: String) -> KeychainItemReadReply {
    lock.withLock {
      callLog.append(.read(account: account))
      mainThreadLog.append(Thread.isMainThread)
      if let scripted = popFront(&readScript) { return scripted }
      if items[account] != nil, let reply = readReplyWhileStored { return reply }
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

private func makeCoordinator(_ fake: FakeKeychain) -> FirstUseTrustCoordinator {
  FirstUseTrustCoordinator(store: makeStore(fake))
}

private func evaluate(
  _ fake: FakeKeychain,
  _ presented: Data,
  device: DeviceID = deviceOne
) async -> CoreResult<FirstUseTrustOutcome> {
  await makeCoordinator(fake).evaluate(deviceID: device, presentedFingerprint: presented)
}

private func apply(
  _ fake: FakeKeychain,
  _ decision: FirstUseOwnerDecision,
  _ presented: Data,
  device: DeviceID = deviceOne
) async -> CoreResult<FirstUseTrustOutcome> {
  await makeCoordinator(fake).apply(
    ownerDecision: decision,
    deviceID: device,
    presentedFingerprint: presented
  )
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

  fileprivate var succeeded: Bool {
    if case .success = self { return true }
    return false
  }
}

/// An exhaustive switch: adding an outcome case breaks compilation here.
private func label(_ outcome: FirstUseTrustOutcome) -> String {
  switch outcome {
  case .prompt: "prompt"
  case .allow: "allow"
  case .reject(let code): "reject.\(code.rawValue)"
  }
}

/// An exhaustive switch: adding an owner decision breaks compilation here.
private func label(_ decision: FirstUseOwnerDecision) -> String {
  switch decision {
  case .trust: "trust"
  case .reject: "reject"
  }
}

/// An exhaustive switch: adding an insert outcome breaks compilation here.
private func label(_ outcome: KeychainTrustInsertOutcome) -> String {
  switch outcome {
  case .inserted: "inserted"
  case .existing: "existing"
  }
}

/// An exhaustive switch: adding a read reply breaks compilation here.
private func label(_ reply: KeychainItemReadReply) -> String {
  switch reply {
  case .data: "data"
  case .nonData: "nonData"
  case .status: "status"
  }
}

// MARK: - Expected failure shapes

private func expectedRetry(for status: OSStatus) -> RetryDisposition {
  interactionStatuses.contains(status) ? .userActionRequired : .never
}

private func storageFailure(_ status: OSStatus, _ retry: RetryDisposition) -> CoreError {
  CoreError(
    code: .security(.secureStorageUnavailable),
    severity: .error,
    retryDisposition: retry,
    cleanupDisposition: .notRequired,
    underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: status)
  )
}

private func storageFailure(_ status: OSStatus) -> CoreError {
  storageFailure(status, expectedRetry(for: status))
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

@Test func firstUseTypesAreClosedEquatableAndSendable() {
  requireSendable(FirstUseOwnerDecision.self)
  requireSendable(FirstUseTrustOutcome.self)
  requireSendable(FirstUseTrustCoordinator.self)
  requireSendable(KeychainTrustStore.self)
  requireSendable(KeychainTrustStoreEnvironment.self)
  requireSendable(KeychainTrustInsertOutcome.self)
  requireSendable(KeychainItemReadReply.self)

  #expect(label(FirstUseOwnerDecision.trust) == "trust")
  #expect(label(FirstUseOwnerDecision.reject) == "reject")
  #expect(label(FirstUseTrustOutcome.prompt) == "prompt")
  #expect(label(FirstUseTrustOutcome.allow) == "allow")
  #expect(label(FirstUseTrustOutcome.reject(.identityChanged)) == "reject.identityChanged")
  #expect(label(KeychainTrustInsertOutcome.inserted) == "inserted")
  #expect(label(KeychainTrustInsertOutcome.existing(storedFingerprint: fingerprintA)) == "existing")
  #expect(label(KeychainItemReadReply.nonData) == "nonData")

  #expect(FirstUseOwnerDecision.trust != .reject)
  #expect(FirstUseTrustOutcome.prompt != .allow)
  #expect(FirstUseTrustOutcome.reject(.identityChanged) != .reject(.trustRejected))
  #expect(
    KeychainTrustInsertOutcome.existing(storedFingerprint: fingerprintA)
      != .existing(storedFingerprint: fingerprintB))
}

/// The production initializer takes no arguments. It is referenced here only to
/// pin its shape; it is never called, so no ordinary test reaches the platform.
@Test func productionInitializerTakesNoArgumentsAndIsNeverCalledHere() {
  let makeProductionStore: () -> KeychainTrustStore = KeychainTrustStore.init
  _ = makeProductionStore
}

// MARK: - Production query contract
//
// The query builders are the single source of every dictionary the production
// environment hands to the platform. They are pure, so their contract is
// asserted without touching any Keychain.

private let commonQueryKeys: Set<String> = [
  kSecClass as String,
  kSecAttrService as String,
  kSecAttrAccount as String,
  kSecUseDataProtectionKeychain as String,
  kSecAttrSynchronizable as String,
]

private func expectCommonQueryContract(
  _ query: [String: Any],
  account expectedAccount: String,
  _ context: String
) {
  #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String, "\(context)")
  #expect(
    query[kSecAttrService as String] as? String == KeychainTrustStoreEnvironment.productionService,
    "\(context)")
  #expect(query[kSecAttrAccount as String] as? String == expectedAccount, "\(context)")
  #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true, "\(context)")
  #expect(query[kSecAttrSynchronizable as String] as? Bool == false, "\(context)")
  #expect(query[kSecAttrAccessGroup as String] == nil, "\(context) names an access group")
}

@Test func productionServiceIsAFixedVersionedIdentifier() {
  let service = KeychainTrustStoreEnvironment.productionService
  #expect(service == KeychainTrustStoreEnvironment.productionService)
  #expect(service.wholeMatch(of: /[a-z0-9][a-z0-9.\-]*\.v[1-9][0-9]*/) != nil)
  #expect(!service.contains(account(deviceOne)))
  #expect(!service.lowercased().contains(hex(fingerprintA, uppercase: false)))
}

@Test func accountIsTheCanonicalLowercasedDeviceUUID() {
  #expect(
    KeychainTrustStoreEnvironment.account(for: deviceOne)
      == "5eed0580-abcd-4ef0-8a1b-c2d3e4f50001")
  #expect(KeychainTrustStoreEnvironment.account(for: deviceOne) == account(deviceOne))
  #expect(KeychainTrustStoreEnvironment.account(for: deviceTwo) == account(deviceTwo))
  #expect(
    KeychainTrustStoreEnvironment.account(for: deviceOne)
      != KeychainTrustStoreEnvironment.account(for: deviceTwo))

  // Two values for the same UUID, however written, address the same record.
  let sameDevice = DeviceID(rawValue: UUID(uuidString: "5eed0580-abcd-4ef0-8a1b-c2d3e4f50001")!)
  #expect(KeychainTrustStoreEnvironment.account(for: sameDevice) == account(deviceOne))
}

@Test func readQueryAsksTheDataProtectionKeychainForExactlyOneDataResult() {
  let query = KeychainTrustStoreEnvironment.readQuery(account: account(deviceOne))
  #expect(
    Set(query.keys)
      == commonQueryKeys.union([kSecReturnData as String, kSecMatchLimit as String]))
  expectCommonQueryContract(query, account: account(deviceOne), "read")
  #expect(query[kSecReturnData as String] as? Bool == true)
  #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
}

@Test func addQueryStoresOnlyTheRawDigestAsThisDeviceOnlyWhenUnlocked() {
  let query = KeychainTrustStoreEnvironment.addQuery(
    account: account(deviceOne),
    fingerprint: fingerprintA
  )
  #expect(
    Set(query.keys)
      == commonQueryKeys.union([kSecAttrAccessible as String, kSecValueData as String]))
  expectCommonQueryContract(query, account: account(deviceOne), "add")
  #expect(
    query[kSecAttrAccessible as String] as? String
      == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
  #expect(query[kSecValueData as String] as? Data == fingerprintA)
}

@Test func deleteQueryAddressesOnlyTheOneRecord() {
  let query = KeychainTrustStoreEnvironment.deleteQuery(account: account(deviceTwo))
  #expect(Set(query.keys) == commonQueryKeys)
  expectCommonQueryContract(query, account: account(deviceTwo), "delete")
}

// MARK: - Store: load, insert-if-absent, remove

@Test func loadReportsAMissingRecordAsNilNotAsAFailure() async {
  let fake = keychain(.absent)
  let result = await makeStore(fake).loadFingerprint(for: deviceOne)
  #expect(result == .success(nil))
  #expect(fake.calls == [.read(account: account(deviceOne))])
}

/// The store returns stored bytes exactly as found. Judging their length is the
/// coordinator's job, so a malformed value is not truncated, padded, or hidden.
@Test(arguments: [0, 1, 31, 32, 33, 64])
func loadReturnsTheStoredBytesUnchanged(length: Int) async {
  let stored = resized(fingerprintA, to: length)
  let fake = keychain(.stored(stored))
  let result = await makeStore(fake).loadFingerprint(for: deviceOne)
  #expect(result == .success(stored))
  #expect(fake.mutations.isEmpty)
}

@Test func insertAddsTheFingerprintWhenNoRecordExists() async {
  let fake = keychain(.absent)
  let result = await makeStore(fake).insertFingerprintIfAbsent(fingerprintA, for: deviceOne)
  #expect(result == .success(.inserted))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(fake.calls == [.add(account: account(deviceOne))])
  #expect(fake.added == [fingerprintA])
}

/// Insert never overwrites. An existing record, equal or not, is reported with
/// the bytes actually stored and left exactly as it was.
@Test func insertNeverOverwritesAnExistingRecord() async {
  for presented in [fingerprintA, fingerprintB] {
    let fake = keychain(.stored(fingerprintA))
    let result = await makeStore(fake).insertFingerprintIfAbsent(presented, for: deviceOne)
    #expect(result == .success(.existing(storedFingerprint: fingerprintA)))
    #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
    #expect(
      fake.calls == [.add(account: account(deviceOne)), .read(account: account(deviceOne))])
  }
}

/// The store refuses to persist anything but a raw 32-byte digest, before any
/// Keychain work.
@Test(arguments: wrongLengths)
func insertRefusesAWrongLengthFingerprintWithoutKeychainIO(length: Int) async throws {
  let fake = keychain(.absent)
  let result = await makeStore(fake)
    .insertFingerprintIfAbsent(resized(fingerprintA, to: length), for: deviceOne)
  let error = try #require(result.failureValue)
  #expect(error.code == .security(.trustRejected))
  #expect(error.retryDisposition == .never)
  #expect(error.underlyingDiagnosticCode == nil)
  #expect(fake.calls.isEmpty)
  #expect(fake.allItems.isEmpty)
}

@Test func removeIsIdempotentAndTreatsAMissingRecordAsSuccess() async {
  let fake = keychain(.stored(fingerprintA))
  let store = makeStore(fake)

  #expect(await store.removeFingerprint(for: deviceOne).succeeded)
  #expect(fake.item(for: account(deviceOne)) == nil)
  #expect(await store.removeFingerprint(for: deviceOne).succeeded)
  #expect(await store.removeFingerprint(for: deviceOne).succeeded)
  #expect(
    fake.calls == Array(repeating: .delete(account: account(deviceOne)), count: 3))
}

/// A record the platform cannot return as data is still removable, so a
/// corrupt record never blocks cleanup.
@Test func removeClearsAnUnreadableRecord() async {
  let fake = keychain(.nonData)
  #expect(await makeStore(fake).removeFingerprint(for: deviceOne).succeeded)
  #expect(fake.allItems.isEmpty)
}

@Test func storeAddressesOnlyTheCanonicalAccountOfTheGivenDevice() async {
  let fake = FakeKeychain(items: [account(deviceTwo): .data(fingerprintB)])
  let store = makeStore(fake)

  #expect(await store.loadFingerprint(for: deviceOne) == .success(nil))
  #expect(
    await store.insertFingerprintIfAbsent(fingerprintA, for: deviceOne) == .success(.inserted))
  #expect(await store.removeFingerprint(for: deviceOne).succeeded)

  #expect(fake.item(for: account(deviceTwo)) == .data(fingerprintB))
  for call in fake.calls {
    switch call {
    case .read(let name), .add(let name), .delete(let name):
      #expect(name == "5eed0580-abcd-4ef0-8a1b-c2d3e4f50001")
    }
  }
}

// MARK: - Full first-use table

@Test func fullFirstUseEvaluationTable() async {
  let table: [(seed: Seed, presented: Data, expected: CoreResult<FirstUseTrustOutcome>)] = [
    (.absent, fingerprintA, .success(.prompt)),
    (.absent, fingerprintB, .success(.prompt)),
    (.stored(fingerprintA), fingerprintA, .success(.allow)),
    (.stored(fingerprintB), fingerprintB, .success(.allow)),
    (.stored(fingerprintA), fingerprintB, .success(.reject(.identityChanged))),
    (.stored(fingerprintB), fingerprintA, .success(.reject(.identityChanged))),
    (.stored(Data()), fingerprintA, .success(.reject(.trustRejected))),
    (.stored(resized(fingerprintA, to: 31)), fingerprintA, .success(.reject(.trustRejected))),
    (.stored(resized(fingerprintA, to: 33)), fingerprintA, .success(.reject(.trustRejected))),
    (.stored(fingerprintA + fingerprintA), fingerprintA, .success(.reject(.trustRejected))),
    (.nonData, fingerprintA, .failure(unreadableStorageFailure)),
    (.absent, Data(), .success(.reject(.trustRejected))),
    (.stored(fingerprintA), resized(fingerprintA, to: 33), .success(.reject(.trustRejected))),
    (.nonData, Data(), .success(.reject(.trustRejected))),
  ]
  for (index, row) in table.enumerated() {
    let fake = keychain(row.seed)
    let before = fake.allItems
    #expect(await evaluate(fake, row.presented) == row.expected, "row \(index)")
    #expect(fake.mutations.isEmpty, "row \(index) wrote")
    #expect(fake.allItems == before, "row \(index) changed the record")
  }
}

@Test func fullOwnerApplicationTable() async {
  let malformed = resized(fingerprintA, to: 33)
  let table:
    [(
      seed: Seed, decision: FirstUseOwnerDecision, presented: Data,
      expected: CoreResult<FirstUseTrustOutcome>, after: FakeKeychainItem?
    )] = [
      (.absent, .reject, fingerprintA, .success(.reject(.trustRejected)), nil),
      (
        .stored(fingerprintA), .reject, fingerprintA, .success(.reject(.trustRejected)),
        .data(fingerprintA)
      ),
      (
        .stored(fingerprintA), .reject, fingerprintB, .success(.reject(.trustRejected)),
        .data(fingerprintA)
      ),
      (.absent, .reject, Data(), .success(.reject(.trustRejected)), nil),
      (.absent, .trust, fingerprintA, .success(.allow), .data(fingerprintA)),
      (.stored(fingerprintA), .trust, fingerprintA, .success(.allow), .data(fingerprintA)),
      (
        .stored(fingerprintA), .trust, fingerprintB, .success(.reject(.identityChanged)),
        .data(fingerprintA)
      ),
      (
        .stored(malformed), .trust, fingerprintA, .success(.reject(.trustRejected)),
        .data(malformed)
      ),
      (.nonData, .trust, fingerprintA, .failure(unreadableStorageFailure), .nonData),
      (.absent, .trust, Data(), .success(.reject(.trustRejected)), nil),
      (.absent, .trust, resized(fingerprintA, to: 31), .success(.reject(.trustRejected)), nil),
    ]
  for (index, row) in table.enumerated() {
    let fake = keychain(row.seed)
    let result = await apply(fake, row.decision, row.presented)
    #expect(result == row.expected, "row \(index) \(label(row.decision))")
    #expect(fake.item(for: account(deviceOne)) == row.after, "row \(index) record")
    #expect(!fake.calls.contains { if case .delete = $0 { true } else { false } }, "row \(index)")
  }
}

// MARK: - Evaluate

/// A prompt is not trust-on-first-use: asking never persists anything, and the
/// same unknown identity keeps prompting until an owner decides.
@Test func missingRecordPromptsAndPromptingNeverPersists() async {
  let fake = keychain(.absent)
  for _ in 0..<3 {
    #expect(await evaluate(fake, fingerprintA) == .success(.prompt))
  }
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems.isEmpty)
  #expect(fake.calls == Array(repeating: .read(account: account(deviceOne)), count: 3))
}

@Test func sameStoredFingerprintAllowsByContentNotStorage() async throws {
  let fake = keychain(.stored(fingerprintA))
  #expect(await evaluate(fake, fingerprintA) == .success(.allow))
  #expect(await evaluate(fake, Data(Array(fingerprintA))) == .success(.allow))

  let buffer = Data([0xEE, 0xEE, 0xEE]) + fingerprintA
  let slice = buffer[3..<35]
  try #require(slice.startIndex == 3)
  #expect(await evaluate(fake, slice) == .success(.allow))
}

@Test func changedFingerprintRejectsAndLeavesTheRecord() async {
  let fake = keychain(.stored(fingerprintA))
  #expect(await evaluate(fake, fingerprintB) == .success(.reject(.identityChanged)))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(fake.mutations.isEmpty)
}

@Test(arguments: wrongLengths)
func malformedStoredValueRejectsEvenAgainstIdenticalBytes(length: Int) async {
  let stored = resized(fingerprintA, to: length)
  let fake = keychain(.stored(stored))
  #expect(await evaluate(fake, fingerprintA) == .success(.reject(.trustRejected)))
  #expect(await evaluate(fake, fingerprintB) == .success(.reject(.trustRejected)))
  #expect(fake.item(for: account(deviceOne)) == .data(stored))
  #expect(fake.mutations.isEmpty)
}

/// Length validation outranks storage: a wrong-length presented fingerprint is
/// rejected by both entry points before any Keychain work, whatever is stored.
@Test(arguments: wrongLengths)
func invalidPresentedLengthRejectsWithoutKeychainIO(length: Int) async {
  let presentations = [Data(repeating: 0xAB, count: length), resized(fingerprintA, to: length)]
  for seed in [Seed.absent, .stored(fingerprintA), .nonData] {
    for presented in presentations {
      let fake = keychain(seed)
      #expect(await evaluate(fake, presented) == .success(.reject(.trustRejected)))
      #expect(await apply(fake, .trust, presented) == .success(.reject(.trustRejected)))
      #expect(await apply(fake, .reject, presented) == .success(.reject(.trustRejected)))
      #expect(fake.calls.isEmpty, "\(length)-byte input reached the Keychain")
    }
  }
}

@Test func exactlyThirtyTwoBytesIsTheOnlyAcceptedLength() async {
  #expect(validLength == 32)
  let short = resized(fingerprintA, to: 31)
  let long = resized(fingerprintA, to: 33)

  #expect(await evaluate(keychain(.absent), short) == .success(.reject(.trustRejected)))
  #expect(await evaluate(keychain(.absent), fingerprintA) == .success(.prompt))
  #expect(await evaluate(keychain(.absent), long) == .success(.reject(.trustRejected)))

  let trusting = keychain(.absent)
  #expect(await apply(trusting, .trust, short) == .success(.reject(.trustRejected)))
  #expect(await apply(trusting, .trust, long) == .success(.reject(.trustRejected)))
  #expect(trusting.allItems.isEmpty)
  #expect(await apply(trusting, .trust, fingerprintA) == .success(.allow))
  #expect(trusting.added == [fingerprintA])
}

@Test func everySingleBitChangeOfThePresentedFingerprintIsAnIdentityChange() async {
  let fake = keychain(.stored(fingerprintA))
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let flipped = flipping(fingerprintA, byte: offset, bit: bit)
      #expect(
        await evaluate(fake, flipped) == .success(.reject(.identityChanged)),
        "byte \(offset) bit \(bit)")
    }
  }
  #expect(fake.mutations.isEmpty)
}

@Test func everySingleBitChangeOfTheStoredFingerprintIsAnIdentityChange() async {
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let fake = keychain(.stored(flipping(fingerprintA, byte: offset, bit: bit)))
      #expect(
        await evaluate(fake, fingerprintA) == .success(.reject(.identityChanged)),
        "byte \(offset) bit \(bit)")
    }
  }
}

/// An owner's trust cannot replace a different stored identity, not even one
/// that differs by a single bit.
@Test func everySingleBitChangeOnDuplicateTrustRejectsAndKeepsTheRecord() async {
  let fake = keychain(.stored(fingerprintA))
  for offset in 0..<validLength {
    for bit in 0..<8 {
      let flipped = flipping(fingerprintA, byte: offset, bit: bit)
      #expect(
        await apply(fake, .trust, flipped) == .success(.reject(.identityChanged)),
        "byte \(offset) bit \(bit)")
    }
  }
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(!fake.calls.contains { if case .delete = $0 { true } else { false } })
}

// MARK: - Owner application

@Test func explicitRejectRejectsAndNeverWrites() async {
  let absent = keychain(.absent)
  #expect(await apply(absent, .reject, fingerprintA) == .success(.reject(.trustRejected)))
  #expect(absent.mutations.isEmpty)
  #expect(absent.allItems.isEmpty)
  #expect(await evaluate(absent, fingerprintA) == .success(.prompt))

  let trusted = keychain(.stored(fingerprintA))
  #expect(await apply(trusted, .reject, fingerprintA) == .success(.reject(.trustRejected)))
  #expect(trusted.mutations.isEmpty)
  #expect(trusted.item(for: account(deviceOne)) == .data(fingerprintA))
}

@Test func explicitTrustInsertsOnceAndLaterEvaluationAllows() async {
  let fake = keychain(.absent)
  #expect(await evaluate(fake, fingerprintA) == .success(.prompt))
  #expect(await apply(fake, .trust, fingerprintA) == .success(.allow))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(await evaluate(fake, fingerprintA) == .success(.allow))
  #expect(await evaluate(fake, fingerprintB) == .success(.reject(.identityChanged)))
  #expect(fake.added == [fingerprintA])
}

@Test func duplicateTrustWithTheSameFingerprintAllowsWithoutRewriting() async {
  let fake = keychain(.stored(fingerprintA))
  #expect(await apply(fake, .trust, fingerprintA) == .success(.allow))
  #expect(await apply(fake, .trust, Data(Array(fingerprintA))) == .success(.allow))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(fake.mutations == Array(repeating: .add(account: account(deviceOne)), count: 2))
}

@Test func duplicateTrustWithADifferentFingerprintRejectsAndKeepsTheOriginal() async {
  let fake = keychain(.stored(fingerprintA))
  #expect(await apply(fake, .trust, fingerprintB) == .success(.reject(.identityChanged)))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(await evaluate(fake, fingerprintA) == .success(.allow))
  #expect(await evaluate(fake, fingerprintB) == .success(.reject(.identityChanged)))
}

@Test(arguments: wrongLengths)
func duplicateTrustWithAMalformedStoredValueRejects(length: Int) async {
  let stored = resized(fingerprintA, to: length)
  let fake = keychain(.stored(stored))
  #expect(await apply(fake, .trust, fingerprintA) == .success(.reject(.trustRejected)))
  #expect(fake.item(for: account(deviceOne)) == .data(stored))
}

/// Add reported a duplicate, but the record was gone by the time it was read.
/// The coordinator fails closed instead of adding again.
@Test func duplicateWhoseRecordVanishedFailsClosedWithoutRetrying() async throws {
  let fake = keychain(.absent)
  fake.scriptAdds([errSecDuplicateItem])
  let result = await apply(fake, .trust, fingerprintA)

  let error = try #require(result.failureValue)
  #expect(error.code == .security(.secureStorageUnavailable))
  #expect(error.retryDisposition.allowsAutomaticRetry == false)
  #expect(
    fake.calls == [.add(account: account(deviceOne)), .read(account: account(deviceOne))])
  #expect(fake.allItems.isEmpty)
}

@Test func duplicateWhoseRecordCannotBeReadFailsClosed() async {
  for reply in [KeychainItemReadReply.nonData, .status(errSecSuccess)] {
    let fake = keychain(.stored(fingerprintA))
    fake.failReadsWhileStored(with: reply)
    #expect(await apply(fake, .trust, fingerprintA) == .failure(unreadableStorageFailure))
  }
  for status in [errSecInteractionNotAllowed, errSecIO] {
    let fake = keychain(.stored(fingerprintA))
    fake.failReadsWhileStored(with: .status(status))
    #expect(await apply(fake, .trust, fingerprintA) == .failure(storageFailure(status)))
    #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  }
}

@Test(arguments: addFailureStatuses)
func addFailurePropagatesFailClosedWithoutRetrying(status: OSStatus) async {
  let fake = keychain(.absent)
  fake.scriptAdds([status])
  #expect(await apply(fake, .trust, fingerprintA) == .failure(storageFailure(status)))
  #expect(fake.calls == [.add(account: account(deviceOne))])
  #expect(fake.allItems.isEmpty)

  let storeFake = keychain(.absent)
  storeFake.scriptAdds([status])
  #expect(
    await makeStore(storeFake).insertFingerprintIfAbsent(fingerprintA, for: deviceOne)
      == .failure(storageFailure(status)))
  #expect(storeFake.calls == [.add(account: account(deviceOne))])
}

/// Insert-if-absent is one add; it is never a read followed by a write, which
/// would race another writer. Nothing ever deletes, and nothing updates.
@Test func operationOrderingIsFixed() async {
  let acct = account(deviceOne)

  let evaluating = keychain(.stored(fingerprintA))
  _ = await evaluate(evaluating, fingerprintA)
  #expect(evaluating.calls == [.read(account: acct)])

  let fresh = keychain(.absent)
  _ = await apply(fresh, .trust, fingerprintA)
  #expect(fresh.calls == [.add(account: acct)])

  let duplicate = keychain(.stored(fingerprintA))
  _ = await apply(duplicate, .trust, fingerprintB)
  #expect(duplicate.calls == [.add(account: acct), .read(account: acct)])

  let rejecting = keychain(.stored(fingerprintA))
  _ = await apply(rejecting, .reject, fingerprintA)
  #expect(rejecting.mutations.isEmpty)

  let removing = keychain(.stored(fingerprintA))
  _ = await makeStore(removing).removeFingerprint(for: deviceOne)
  #expect(removing.calls == [.delete(account: acct)])
}

// MARK: - Storage failures and diagnostics

@Test(arguments: readFailureStatuses)
func readFailureMapsToSecureStorageUnavailableWithOnlyTheStatus(status: OSStatus) async {
  let evaluating = keychain(.stored(fingerprintA))
  evaluating.scriptReads([.status(status)])
  let expected = storageFailure(status)
  #expect(await evaluate(evaluating, fingerprintA) == .failure(expected))
  #expect(evaluating.calls == [.read(account: account(deviceOne))])
  #expect(evaluating.item(for: account(deviceOne)) == .data(fingerprintA))

  let loading = keychain(.absent)
  loading.scriptReads([.status(status)])
  #expect(await makeStore(loading).loadFingerprint(for: deviceOne) == .failure(expected))
  #expect(loading.calls.count == 1)

  #expect(expected.domain == .security)
  #expect(expected.underlyingDiagnosticCode?.rawValue == status)
  #expect(expected.retryDisposition.allowsAutomaticRetry == false)
}

@Test(arguments: deleteFailureStatuses)
func deleteFailureMapsToSecureStorageUnavailableAndKeepsTheRecord(status: OSStatus) async {
  let fake = keychain(.stored(fingerprintA))
  fake.scriptDeletes([status])
  let result = await makeStore(fake).removeFingerprint(for: deviceOne)
  #expect(result.failureValue == storageFailure(status))
  #expect(fake.calls == [.delete(account: account(deviceOne))])
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
}

@Test func interactionAndAuthenticationFailuresNeedAPersonAndOthersNeverRetry() {
  for status in interactionStatuses {
    #expect(storageFailure(status).retryDisposition == .userActionRequired)
  }
  for status in nonInteractiveStatuses {
    #expect(storageFailure(status).retryDisposition == .never)
  }
  for status in interactionStatuses + nonInteractiveStatuses {
    #expect(storageFailure(status).retryDisposition.allowsAutomaticRetry == false)
  }
}

/// A successful read that yields no data is not a missing record: it must not
/// prompt, and it carries no invented status.
@Test func readSuccessWithoutDataFailsClosed() async {
  for reply in [KeychainItemReadReply.nonData, .status(errSecSuccess)] {
    let evaluating = keychain(.absent)
    evaluating.scriptReads([reply])
    #expect(await evaluate(evaluating, fingerprintA) == .failure(unreadableStorageFailure))

    let loading = keychain(.absent)
    loading.scriptReads([reply])
    #expect(
      await makeStore(loading).loadFingerprint(for: deviceOne)
        == .failure(unreadableStorageFailure), "\(label(reply))")
  }
}

/// Failures are equal for every device and fingerprint, so none of them can
/// carry a device identifier, account, service, or digest.
@Test func failuresCarryNoDeviceOrFingerprintPayload() async {
  var failures: [CoreError] = []
  for device in [deviceOne, deviceTwo] {
    for presented in [fingerprintA, fingerprintB] {
      let fake = keychain(.stored(presented), device: device)
      fake.scriptReads([.status(errSecInteractionNotAllowed)])
      if let error = await evaluate(fake, presented, device: device).failureValue {
        failures.append(error)
      }
      let adding = keychain(.absent, device: device)
      adding.scriptAdds([errSecInteractionNotAllowed])
      if let error = await apply(adding, .trust, presented, device: device).failureValue {
        failures.append(error)
      }
    }
  }
  #expect(failures.count == 8)
  #expect(Set(failures) == [storageFailure(errSecInteractionNotAllowed, .userActionRequired)])
}

/// Outcomes carry no fingerprint, so outcomes for different fingerprints are equal.
@Test func outcomesForDifferentFingerprintsAreIndistinguishable() async {
  #expect(
    await evaluate(keychain(.absent), fingerprintA) == evaluate(keychain(.absent), fingerprintB))
  #expect(
    await evaluate(keychain(.stored(fingerprintA)), fingerprintB)
      == evaluate(keychain(.stored(fingerprintA)), flipping(fingerprintA, byte: 0, bit: 0)))
  #expect(
    await apply(keychain(.absent), .trust, fingerprintA)
      == apply(keychain(.absent), .trust, fingerprintB))
}

@Test func aFailureDoesNotPoisonLaterCalls() async {
  let fake = keychain(.absent)
  fake.scriptReads([.status(errSecInteractionNotAllowed)])
  fake.scriptAdds([errSecNotAvailable])

  #expect(
    await evaluate(fake, fingerprintA)
      == .failure(storageFailure(errSecInteractionNotAllowed, .userActionRequired)))
  #expect(await evaluate(fake, fingerprintA) == .success(.prompt))
  #expect(
    await apply(fake, .trust, fingerprintA) == .failure(storageFailure(errSecNotAvailable, .never)))
  #expect(fake.allItems.isEmpty)
  #expect(await apply(fake, .trust, fingerprintA) == .success(.allow))
  #expect(await evaluate(fake, fingerprintA) == .success(.allow))
}

// MARK: - Inputs, concurrency, and cancellation

@Test func callerInputsAreNotMutatedAndSlicesAreStoredByContent() async throws {
  let buffer = Data([0xEE, 0xEE]) + fingerprintA + Data([0xEE])
  let slice = buffer[2..<34]
  try #require(slice.startIndex == 2)

  let fake = keychain(.absent)
  #expect(await apply(fake, .trust, slice) == .success(.allow))
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
  #expect(fake.added == [fingerprintA])
  #expect(await evaluate(fake, slice) == .success(.allow))
  #expect(slice == fingerprintA)
  #expect(buffer == Data([0xEE, 0xEE]) + fingerprintA + Data([0xEE]))

  // Changing the caller's value afterwards does not reach the stored record.
  var callerValue = Data(Array(fingerprintB))
  let other = keychain(.absent)
  #expect(await apply(other, .trust, callerValue) == .success(.allow))
  callerValue[0] ^= 0xFF
  #expect(other.item(for: account(deviceOne)) == .data(fingerprintB))
  #expect(await evaluate(other, fingerprintB) == .success(.allow))
}

/// Keychain calls block their thread, so the store must not run them on the
/// caller's main actor.
@Test @MainActor func keychainOperationsRunOffTheCallersMainActor() async {
  let fake = keychain(.absent)
  let coordinator = makeCoordinator(fake)
  _ = await coordinator.evaluate(deviceID: deviceOne, presentedFingerprint: fingerprintA)
  _ = await coordinator.apply(
    ownerDecision: .trust, deviceID: deviceOne, presentedFingerprint: fingerprintA)
  _ = await makeStore(fake).removeFingerprint(for: deviceOne)

  #expect(fake.calls.count == 3)
  #expect(fake.mainThreadObservations == [false, false, false])
}

@Test func concurrentTrustOfTheSameFingerprintInsertsExactlyOnce() async {
  let fake = keychain(.absent)
  let coordinator = makeCoordinator(fake)
  let results = await withTaskGroup(of: CoreResult<FirstUseTrustOutcome>.self) { group in
    for _ in 0..<32 {
      group.addTask {
        await coordinator.apply(
          ownerDecision: .trust, deviceID: deviceOne, presentedFingerprint: fingerprintA)
      }
    }
    var collected: [CoreResult<FirstUseTrustOutcome>] = []
    for await result in group { collected.append(result) }
    return collected
  }
  #expect(results.count == 32)
  #expect(results.allSatisfy { $0 == .success(.allow) })
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintA)])
  #expect(fake.calls.filter { if case .add = $0 { true } else { false } }.count == 32)
  #expect(fake.calls.filter { if case .read = $0 { true } else { false } }.count == 31)
}

/// Two owners trusting different fingerprints at once: exactly one record wins,
/// and every caller's outcome agrees with that record.
@Test func concurrentTrustOfCompetingFingerprintsHasExactlyOneWinner() async throws {
  let fake = keychain(.absent)
  let coordinator = makeCoordinator(fake)
  let results = await withTaskGroup(of: (Data, CoreResult<FirstUseTrustOutcome>).self) { group in
    for index in 0..<32 {
      let presented = index.isMultiple(of: 2) ? fingerprintA : fingerprintB
      group.addTask {
        let result = await coordinator.apply(
          ownerDecision: .trust, deviceID: deviceOne, presentedFingerprint: presented)
        return (presented, result)
      }
    }
    var collected: [(Data, CoreResult<FirstUseTrustOutcome>)] = []
    for await result in group { collected.append(result) }
    return collected
  }

  guard case .data(let winner) = try #require(fake.item(for: account(deviceOne))) else {
    Issue.record("the record is not data")
    return
  }
  #expect(winner == fingerprintA || winner == fingerprintB)
  #expect(results.count == 32)
  for (presented, result) in results {
    let expected: CoreResult<FirstUseTrustOutcome> =
      presented == winner ? .success(.allow) : .success(.reject(.identityChanged))
    #expect(result == expected)
  }
}

@Test func concurrentEvaluationsAgreeWithSerialEvaluations() async {
  let fake = FakeKeychain(items: [
    account(deviceOne): .data(fingerprintA),
    account(deviceTwo): .data(resized(fingerprintB, to: 31)),
  ])
  let coordinator = makeCoordinator(fake)
  let thirdDevice = DeviceID(rawValue: UUID(uuidString: "5EED0580-ABCD-4EF0-8A1B-C2D3E4F50003")!)
  let cases: [(DeviceID, Data)] = [
    (deviceOne, fingerprintA), (deviceOne, fingerprintB), (deviceTwo, fingerprintB),
    (thirdDevice, fingerprintA), (deviceOne, Data()),
  ]
  var expected: [CoreResult<FirstUseTrustOutcome>] = []
  for (device, presented) in cases {
    expected.append(await coordinator.evaluate(deviceID: device, presentedFingerprint: presented))
  }
  #expect(
    expected == [
      .success(.allow), .success(.reject(.identityChanged)), .success(.reject(.trustRejected)),
      .success(.prompt), .success(.reject(.trustRejected)),
    ])

  await withTaskGroup(of: (Int, CoreResult<FirstUseTrustOutcome>).self) { group in
    for _ in 0..<16 {
      for (index, (device, presented)) in cases.enumerated() {
        group.addTask {
          let result = await coordinator.evaluate(deviceID: device, presentedFingerprint: presented)
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

@Test func cancellationBeforeStartPerformsNoKeychainIO() async {
  let fake = keychain(.absent)
  let coordinator = makeCoordinator(fake)
  let store = makeStore(fake)

  let evaluated = await runCancelledBeforeStart {
    await coordinator.evaluate(deviceID: deviceOne, presentedFingerprint: fingerprintA)
  }
  let trusted = await runCancelledBeforeStart {
    await coordinator.apply(
      ownerDecision: .trust, deviceID: deviceOne, presentedFingerprint: fingerprintA)
  }
  let loaded = await runCancelledBeforeStart {
    await store.loadFingerprint(for: deviceOne)
  }
  let inserted = await runCancelledBeforeStart {
    await store.insertFingerprintIfAbsent(fingerprintA, for: deviceOne)
  }

  #expect(evaluated == .failure(cancellationFailure))
  #expect(trusted == .failure(cancellationFailure))
  #expect(loaded == .failure(cancellationFailure))
  #expect(inserted == .failure(cancellationFailure))
  #expect(fake.calls.isEmpty)
  #expect(fake.allItems.isEmpty)
}

/// Cancellation never turns an explicit rejection into acceptance.
@Test func cancelledExplicitRejectNeverAllowsOrWrites() async {
  let fake = keychain(.absent)
  let coordinator = makeCoordinator(fake)
  let result = await runCancelledBeforeStart {
    await coordinator.apply(
      ownerDecision: .reject, deviceID: deviceOne, presentedFingerprint: fingerprintA)
  }
  #expect(result != .success(.allow))
  #expect(result != .success(.prompt))
  #expect(fake.mutations.isEmpty)
  #expect(fake.allItems.isEmpty)
}

/// Once the owner's add has been issued, cancelling the task neither hides its
/// real result nor triggers a compensating delete or a second add.
@Test func cancellingDuringTheOwnersAddReportsTheAddsRealResult() async {
  let fake = keychain(.absent)
  fake.holdNextAdd()
  let coordinator = makeCoordinator(fake)

  let task = Task {
    await coordinator.apply(
      ownerDecision: .trust, deviceID: deviceOne, presentedFingerprint: fingerprintA)
  }
  await fake.waitUntilAddIsHeld()
  task.cancel()
  fake.releaseHeldAdd()

  #expect(await task.value == .success(.allow))
  #expect(fake.calls == [.add(account: account(deviceOne))])
  #expect(fake.item(for: account(deviceOne)) == .data(fingerprintA))
}

// MARK: - Tier-H manual probe vocabulary and sequencing

/// The exact action names the manual probe accepts. Anything else is refused.
private enum ManualKeychainProbeAction: String, CaseIterable {
  /// Runs the first-use flow once against one fixed synthetic record.
  case keychainFirstUseRoundTrip = "keychain-first-use-round-trip"
}

private enum ManualKeychainProbeSelection: Equatable {
  case notSelected
  case selected(ManualKeychainProbeAction)
  case unknown
}

/// Parses the reviewer's selection, failing closed on anything unrecognized.
private func manualKeychainProbeSelection(from rawValue: String?) -> ManualKeychainProbeSelection {
  guard let rawValue else { return .notSelected }
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return .notSelected }
  guard let action = ManualKeychainProbeAction(rawValue: trimmed) else { return .unknown }
  return .selected(action)
}

/// A fixed synthetic device used only by the probe. It is never printed.
private let manualProbeDeviceID = DeviceID(
  rawValue: UUID(uuidString: "5EED0580-F1A5-4E05-8058-0000000F1A58")!
)
private let manualProbeTrustedFingerprint = fingerprintA
private let manualProbeChangedFingerprint = fingerprintB

private enum ManualKeychainOutcomeState: Equatable {
  case notAttempted
  case outcome(FirstUseTrustOutcome)
  case failed(CoreError)

  init(_ result: CoreResult<FirstUseTrustOutcome>) {
    switch result {
    case .success(let outcome): self = .outcome(outcome)
    case .failure(let error): self = .failed(error)
    }
  }

  var closedName: String {
    switch self {
    case .notAttempted: "notAttempted"
    case .outcome(let outcome): label(outcome)
    case .failed(let error): sanitizedKeychainFailureName(error)
    }
  }
}

private enum ManualKeychainRemoveState: Equatable {
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
    case .failed(let error): sanitizedKeychainFailureName(error)
    }
  }
}

/// Whether a record exists. A present record's bytes are never reported.
private enum ManualKeychainLoadState: Equatable {
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
    case .failed(let error): sanitizedKeychainFailureName(error)
    }
  }
}

private struct ManualKeychainProbeResult: Equatable {
  var initialCleanup: ManualKeychainRemoveState = .notAttempted
  var absentEvaluation: ManualKeychainOutcomeState = .notAttempted
  var explicitReject: ManualKeychainOutcomeState = .notAttempted
  var afterRejectEvaluation: ManualKeychainOutcomeState = .notAttempted
  var explicitTrust: ManualKeychainOutcomeState = .notAttempted
  var sameEvaluation: ManualKeychainOutcomeState = .notAttempted
  var changedEvaluation: ManualKeychainOutcomeState = .notAttempted
  var finalCleanup: ManualKeychainRemoveState = .notAttempted
  var afterCleanupLoad: ManualKeychainLoadState = .notAttempted
}

/// The result a correct store produces, starting from any state of the one
/// synthetic record.
private let expectedManualKeychainProbeResult = ManualKeychainProbeResult(
  initialCleanup: .removed,
  absentEvaluation: .outcome(.prompt),
  explicitReject: .outcome(.reject(.trustRejected)),
  afterRejectEvaluation: .outcome(.prompt),
  explicitTrust: .outcome(.allow),
  sameEvaluation: .outcome(.allow),
  changedEvaluation: .outcome(.reject(.identityChanged)),
  finalCleanup: .removed,
  afterCleanupLoad: .absent
)

/// Runs the first-use round trip once, in a fixed order, against `store`.
///
/// It starts by removing the synthetic record, so a leftover from an earlier
/// interrupted run cannot change the outcome. The middle steps stop at the first
/// unexpected result, and the final cleanup and absence check run on every path,
/// so a record written by this probe is always asked to be removed. Nothing
/// sleeps, polls, or retries. Ordinary tests pass a store over the in-memory
/// fake; only the opt-in probe passes the production environment.
private func performManualKeychainProbe(
  store: KeychainTrustStore
) async -> ManualKeychainProbeResult {
  let coordinator = FirstUseTrustCoordinator(store: store)
  let device = manualProbeDeviceID
  let expected = expectedManualKeychainProbeResult
  var result = ManualKeychainProbeResult()

  result.initialCleanup = await ManualKeychainRemoveState(store.removeFingerprint(for: device))

  steps: do {
    guard result.initialCleanup == expected.initialCleanup else { break steps }

    result.absentEvaluation = await ManualKeychainOutcomeState(
      coordinator.evaluate(deviceID: device, presentedFingerprint: manualProbeTrustedFingerprint))
    guard result.absentEvaluation == expected.absentEvaluation else { break steps }

    result.explicitReject = await ManualKeychainOutcomeState(
      coordinator.apply(
        ownerDecision: .reject, deviceID: device,
        presentedFingerprint: manualProbeTrustedFingerprint))
    guard result.explicitReject == expected.explicitReject else { break steps }

    result.afterRejectEvaluation = await ManualKeychainOutcomeState(
      coordinator.evaluate(deviceID: device, presentedFingerprint: manualProbeTrustedFingerprint))
    guard result.afterRejectEvaluation == expected.afterRejectEvaluation else { break steps }

    result.explicitTrust = await ManualKeychainOutcomeState(
      coordinator.apply(
        ownerDecision: .trust, deviceID: device,
        presentedFingerprint: manualProbeTrustedFingerprint))
    guard result.explicitTrust == expected.explicitTrust else { break steps }

    result.sameEvaluation = await ManualKeychainOutcomeState(
      coordinator.evaluate(deviceID: device, presentedFingerprint: manualProbeTrustedFingerprint))
    guard result.sameEvaluation == expected.sameEvaluation else { break steps }

    result.changedEvaluation = await ManualKeychainOutcomeState(
      coordinator.evaluate(deviceID: device, presentedFingerprint: manualProbeChangedFingerprint))
  }

  result.finalCleanup = await ManualKeychainRemoveState(store.removeFingerprint(for: device))
  result.afterCleanupLoad = await ManualKeychainLoadState(store.loadFingerprint(for: device))
  return result
}

/// Renders the one sanitized line the reviewer transcribes into `manual.md`.
///
/// Every field is a closed enum case or a closed `CoreError` taxonomy name. No
/// device identifier, account, service, status value, or fingerprint can reach
/// this output, because no such value is passed to it.
private func manualKeychainProbeLine(
  action: ManualKeychainProbeAction,
  result: ManualKeychainProbeResult
) -> String {
  let fields = [
    "action=\(action.rawValue)",
    "initialCleanup=\(result.initialCleanup.closedName)",
    "absent=\(result.absentEvaluation.closedName)",
    "explicitReject=\(result.explicitReject.closedName)",
    "afterReject=\(result.afterRejectEvaluation.closedName)",
    "explicitTrust=\(result.explicitTrust.closedName)",
    "same=\(result.sameEvaluation.closedName)",
    "changed=\(result.changedEvaluation.closedName)",
    "finalCleanup=\(result.finalCleanup.closedName)",
    "afterCleanup=\(result.afterCleanupLoad.closedName)",
  ]
  return "M1-058 manual probe: " + fields.joined(separator: " ")
}

/// Maps a failure to a closed taxonomy name. The diagnostic status is
/// deliberately dropped.
private func sanitizedKeychainFailureName(_ error: CoreError) -> String {
  let retry = error.retryDisposition.rawValue
  switch error.code {
  case .security(let code): return "failed.security.\(code.rawValue).\(retry)"
  case .cancellation(let reason): return "failed.cancellation.\(reason.rawValue).\(retry)"
  default: return "failed.unexpectedDomain.\(error.domain.rawValue)"
  }
}

/// Every value a probe field other than `action` may take.
private func everyClosedProbeValue() -> Set<String> {
  var names: Set<String> = ["notAttempted", "prompt", "allow", "removed", "absent", "present"]
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

private let manualProbeLinePrefix = "M1-058 manual probe: "

@Test func manualKeychainProbeSelectionFailsClosedAndIsSkippedByDefault() {
  #expect(manualKeychainProbeSelection(from: nil) == .notSelected)
  #expect(manualKeychainProbeSelection(from: "") == .notSelected)
  #expect(manualKeychainProbeSelection(from: " \n\t") == .notSelected)

  #expect(
    manualKeychainProbeSelection(from: " keychain-first-use-round-trip\n")
      == .selected(.keychainFirstUseRoundTrip))

  let rejected = [
    "KEYCHAIN-FIRST-USE-ROUND-TRIP", "keychain", "round-trip", "first-use", "live", "1", "true",
    "keychain-first-use-round-trip;cleanup", "keychain-first-use-round-trip keychain",
    "keychain_first_use_round_trip",
  ]
  for value in rejected {
    #expect(manualKeychainProbeSelection(from: value) == .unknown)
  }

  #expect(
    ManualKeychainProbeAction.allCases.map(\.rawValue) == ["keychain-first-use-round-trip"])
}

@Test func manualKeychainProbeSequenceProducesTheExpectedClosedResultOnAFake() async {
  let probeAccount = account(manualProbeDeviceID)
  // A leftover from an interrupted run, plus an unrelated record that must survive.
  let fake = FakeKeychain(items: [
    probeAccount: .data(manualProbeChangedFingerprint),
    account(deviceOne): .data(fingerprintB),
  ])

  let result = await performManualKeychainProbe(store: makeStore(fake))

  #expect(result == expectedManualKeychainProbeResult)
  #expect(
    fake.mutations == [
      .delete(account: probeAccount), .add(account: probeAccount), .delete(account: probeAccount),
    ])
  #expect(fake.calls.last == .read(account: probeAccount))
  #expect(fake.added == [manualProbeTrustedFingerprint])
  #expect(fake.allItems == [account(deviceOne): .data(fingerprintB)])
  for call in fake.calls {
    switch call {
    case .read(let name), .add(let name), .delete(let name): #expect(name == probeAccount)
    }
  }

  let expectedLine = """
    M1-058 manual probe: action=keychain-first-use-round-trip initialCleanup=removed \
    absent=prompt explicitReject=reject.trustRejected afterReject=prompt explicitTrust=allow \
    same=allow changed=reject.identityChanged finalCleanup=removed afterCleanup=absent
    """
  #expect(
    manualKeychainProbeLine(action: .keychainFirstUseRoundTrip, result: result) == expectedLine)
}

/// Every normal failure path still asks for the final cleanup and checks
/// absence, and a failure is reported by name rather than hidden.
@Test func manualKeychainProbeCleansUpOnEveryFailurePath() async {
  let probeAccount = account(manualProbeDeviceID)

  // The initial cleanup fails: nothing is written, cleanup is still retried once at the end.
  let initialFails = FakeKeychain()
  initialFails.scriptDeletes([errSecInteractionNotAllowed])
  let first = await performManualKeychainProbe(store: makeStore(initialFails))
  #expect(first.initialCleanup == .failed(storageFailure(errSecInteractionNotAllowed)))
  #expect(first.absentEvaluation == .notAttempted)
  #expect(first.explicitTrust == .notAttempted)
  #expect(first.finalCleanup == .removed)
  #expect(first.afterCleanupLoad == .absent)
  #expect(initialFails.added.isEmpty)
  #expect(
    initialFails.mutations == [.delete(account: probeAccount), .delete(account: probeAccount)])

  // The owner's trust cannot be stored.
  let trustFails = FakeKeychain()
  trustFails.scriptAdds([errSecNotAvailable])
  let second = await performManualKeychainProbe(store: makeStore(trustFails))
  #expect(second.explicitTrust == .failed(storageFailure(errSecNotAvailable)))
  #expect(second.sameEvaluation == .notAttempted)
  #expect(second.changedEvaluation == .notAttempted)
  #expect(second.finalCleanup == .removed)
  #expect(second.afterCleanupLoad == .absent)
  #expect(trustFails.allItems.isEmpty)

  // The trusted record was written and then could not be read back.
  let readBackFails = FakeKeychain()
  readBackFails.failReadsWhileStored(with: .status(errSecIO))
  let third = await performManualKeychainProbe(store: makeStore(readBackFails))
  #expect(third.explicitTrust == .outcome(.allow))
  #expect(third.sameEvaluation == .failed(storageFailure(errSecIO)))
  #expect(third.changedEvaluation == .notAttempted)
  #expect(third.finalCleanup == .removed)
  #expect(third.afterCleanupLoad == .absent)
  #expect(readBackFails.allItems.isEmpty)
  #expect(readBackFails.mutations.last == .delete(account: probeAccount))

  // The final cleanup itself fails: the leftover is reported, not hidden.
  let finalFails = FakeKeychain()
  finalFails.scriptDeletes([nil, errSecInteractionNotAllowed])
  let fourth = await performManualKeychainProbe(store: makeStore(finalFails))
  #expect(fourth.changedEvaluation == .outcome(.reject(.identityChanged)))
  #expect(fourth.finalCleanup == .failed(storageFailure(errSecInteractionNotAllowed)))
  #expect(fourth.afterCleanupLoad == .present)

  for result in [first, second, third, fourth] {
    #expect(result != expectedManualKeychainProbeResult)
  }
}

@Test func manualKeychainProbeOutputIsClosedVocabularyOnly() throws {
  let noisy = ManualKeychainProbeResult(
    initialCleanup: .failed(storageFailure(errSecInteractionNotAllowed)),
    absentEvaluation: .failed(storageFailure(Int32.min)),
    explicitReject: .outcome(.reject(.trustRejected)),
    afterRejectEvaluation: .failed(cancellationFailure),
    explicitTrust: .failed(storageFailure(errSecMissingEntitlement)),
    sameEvaluation: .failed(
      CoreError(
        code: .internalFailure(.unclassified),
        severity: .error,
        retryDisposition: .never,
        cleanupDisposition: .notRequired,
        underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: 4242)
      )),
    changedEvaluation: .failed(unreadableStorageFailure),
    finalCleanup: .failed(storageFailure(Int32.max)),
    afterCleanupLoad: .present
  )
  let closed = everyClosedProbeValue()

  for result in [noisy, expectedManualKeychainProbeResult, ManualKeychainProbeResult()] {
    let line = manualKeychainProbeLine(action: .keychainFirstUseRoundTrip, result: result)
    try #require(line.hasPrefix(manualProbeLinePrefix))
    let body = String(line.dropFirst(manualProbeLinePrefix.count))

    #expect(!body.contains { $0.isNumber }, "a status value or identifier reached the output")
    let forbidden = [
      account(manualProbeDeviceID), account(manualProbeDeviceID).uppercased(),
      KeychainTrustStoreEnvironment.productionService,
      hex(manualProbeTrustedFingerprint, uppercase: false),
      hex(manualProbeTrustedFingerprint, uppercase: true),
      hex(manualProbeChangedFingerprint, uppercase: false),
      hex(manualProbeChangedFingerprint, uppercase: true),
      "errSec", "OSStatus",
    ]
    for token in forbidden {
      #expect(!line.contains(token))
    }

    let fields = body.split(separator: " ")
    #expect(fields.count == 10)
    for field in fields {
      let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
      try #require(parts.count == 2)
      if parts[0] == "action" {
        #expect(parts[1] == "keychain-first-use-round-trip")
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
@Test func onlyTheTierHLiveRegionNamesTheProductionKeychainSeam() throws {
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
      "MACKVM_M1_058_" + "MANUAL_PROBE",
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
  #expect(live.contains("if: selectedManualKeychainProbe() != " + ".notSelected"))
  #expect(live.components(separatedBy: "print" + "(").count == 2)
  #expect(live.contains("print" + "(manualKeychainProbeLine("))
}

// MARK: - Tier-H live region

/// Environment variable that selects the one real-Keychain action.
///
/// Unset — the case for every ordinary CI and local run — leaves the probe
/// skipped, so no automated run reads or writes the real Keychain.
private let manualKeychainProbeActionKey = "MACKVM_M1_058_MANUAL_PROBE"

private func selectedManualKeychainProbe() -> ManualKeychainProbeSelection {
  manualKeychainProbeSelection(
    from: ProcessInfo.processInfo.environment[manualKeychainProbeActionKey])
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
/// The sequencing in `performManualKeychainProbe` is covered by ordinary
/// always-running tests on the in-memory fake; this probe adds only the real
/// platform.
@Test(
  .enabled(
    if: selectedManualKeychainProbe() != .notSelected,
    "manual Tier-H probe: set MACKVM_M1_058_MANUAL_PROBE to keychain-first-use-round-trip"
  )
)
func manualKeychainProbeRunsTheRealFirstUseRoundTrip() async {
  guard case .selected(let action) = selectedManualKeychainProbe() else {
    // The unrecognized value is deliberately not echoed.
    Issue.record("unknown manual probe action; expected keychain-first-use-round-trip")
    return
  }

  let store = KeychainTrustStore(environment: KeychainTrustStoreEnvironment.live)
  let result = await performManualKeychainProbe(store: store)

  print(manualKeychainProbeLine(action: action, result: result))

  if result != expectedManualKeychainProbeResult {
    Issue.record("the real Keychain path did not produce the expected closed result")
  }
}

import Foundation
import KVMContracts
import Security

/// The device owner's explicit answer to a first-use trust prompt.
///
/// Only a person supplies this value. Nothing in this file derives it from a
/// prompt, a stored record, a timeout, or a cancellation.
package enum FirstUseOwnerDecision: Equatable, Sendable {
  /// Trust the presented fingerprint for this device.
  case trust

  /// Refuse the presented fingerprint. Nothing is stored.
  case reject
}

/// What the first-use flow concluded for one presented fingerprint.
///
/// The cases carry no fingerprint, account, or device identifier, so an outcome
/// can be reported or rendered without exposing any of them.
package enum FirstUseTrustOutcome: Equatable, Sendable {
  /// No trust record exists. The caller must ask the owner and then call
  /// `FirstUseTrustCoordinator.apply`; this is not an acceptance and must never
  /// be treated as one.
  case prompt

  /// The presented fingerprint equals the stored one.
  case allow

  /// The connection must not proceed, for the given reason.
  case reject(SecurityErrorCode)
}

/// What an insert-if-absent did.
package enum KeychainTrustInsertOutcome: Equatable, Sendable {
  /// No record existed, and the presented fingerprint is now stored.
  case inserted

  /// A record already existed and was left exactly as it was.
  ///
  /// `storedFingerprint` is the value actually stored, which may differ from
  /// the presented one or be malformed. Judging it is the caller's job.
  case existing(storedFingerprint: Data)
}

/// One platform read, reduced to the three shapes the store acts on.
///
/// No platform object, error, or message crosses the seam.
enum KeychainItemReadReply: Equatable, Sendable {
  /// The read succeeded with a data result.
  case data(Data)

  /// The read succeeded with no result or with a result that is not data.
  case nonData

  /// Any other status, including item-not-found.
  case status(OSStatus)
}

/// Deterministic seam for the three Keychain operations the store makes.
///
/// There are exactly three operations: read, add, and delete. There is no
/// update operation, so no path can overwrite an existing record. Tests
/// substitute every closure with an in-memory Keychain, so no automated run
/// touches the real Keychain. `live` is the production default.
///
/// Each closure receives only the account and, for add, the raw digest. No
/// signature carries a platform error, message, or object; only an `OSStatus`
/// comes back.
struct KeychainTrustStoreEnvironment: Sendable {
  /// Reads the one record for `account`. Never mutates.
  var readItem: @Sendable (_ account: String) async -> KeychainItemReadReply

  /// Atomically adds a record for `account` holding `fingerprint`, or answers
  /// duplicate-item and leaves an existing record untouched.
  var addItem: @Sendable (_ account: String, _ fingerprint: Data) async -> OSStatus

  /// Deletes the one record for `account`.
  var deleteItem: @Sendable (_ account: String) async -> OSStatus
}

extension KeychainTrustStoreEnvironment {
  /// The fixed, versioned generic-password service under which every trust
  /// record is stored.
  ///
  /// A change to the record format takes a new version rather than
  /// reinterpreting records stored under this one.
  static let productionService = "mackvm.trust-store.peer-fingerprint.v1"

  /// Production default: the macOS data-protection Keychain.
  ///
  /// Every platform call blocks its thread, so each one runs on a global
  /// dispatch queue: never on the calling thread or actor, and never on a
  /// Swift concurrency cooperative thread. Waiting for the reply is not
  /// cancellation-aware, so once a call has been issued its actual status is
  /// returned. Creating this value performs no Keychain work.
  static let live = Self(
    readItem: { account in
      await Self.performOffCaller { Self.copyItem(account: account) }
    },
    addItem: { account, fingerprint in
      await Self.performOffCaller {
        let query = Self.addQuery(account: account, fingerprint: fingerprint)
        return SecItemAdd(query as CFDictionary, nil)
      }
    },
    deleteItem: { account in
      await Self.performOffCaller {
        SecItemDelete(Self.deleteQuery(account: account) as CFDictionary)
      }
    }
  )

  /// The record's account: the device's UUID in canonical lowercased form.
  ///
  /// Two `DeviceID` values for the same UUID always address the same record.
  static func account(for deviceID: DeviceID) -> String {
    deviceID.rawValue.uuidString.lowercased()
  }

  /// Asks for exactly one data result for `account`.
  static func readQuery(account: String) -> [String: Any] {
    var query = recordQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    return query
  }

  /// Adds `fingerprint` as the record's only data, readable only while the
  /// device is unlocked and never migrated to another device.
  static func addQuery(account: String, fingerprint: Data) -> [String: Any] {
    var query = recordQuery(account: account)
    query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    query[kSecValueData as String] = fingerprint
    return query
  }

  /// Addresses only the one record for `account`.
  static func deleteQuery(account: String) -> [String: Any] {
    recordQuery(account: account)
  }

  /// The attributes every query shares. No access group is named, so the
  /// platform applies the application's default group.
  private static func recordQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: productionService,
      kSecAttrAccount as String: account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private static func copyItem(account: String) -> KeychainItemReadReply {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(readQuery(account: account) as CFDictionary, &result)
    guard status == errSecSuccess else { return .status(status) }
    guard let data = result as? Data else { return .nonData }
    return .data(data)
  }

  /// Runs the blocking `operation` on a global dispatch queue and resumes the
  /// awaiting task with its result.
  private static func performOffCaller<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
  ) async -> Value {
    await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: operation())
      }
    }
  }
}

/// Stores one raw SHA-256 certificate fingerprint per device in the macOS
/// data-protection Keychain.
///
/// The store is insert-if-absent only. It never updates and never silently
/// overwrites a record: an add that finds an existing record leaves it as it
/// was and reports what is stored. The atomic platform add is the concurrency
/// boundary, so concurrent inserts for one device produce exactly one record.
///
/// Every operation is `@concurrent`, so it never runs on the caller's actor,
/// and cancellation is observed once, before any Keychain operation. After an
/// operation has been issued the call reports its actual result; it never
/// compensates with a delete or retries.
///
/// Every storage failure is `security.secureStorageUnavailable` carrying only
/// the raw status as its diagnostic code. No failure, outcome, or log carries
/// the service, account, device identifier, or fingerprint. Nothing logs.
///
/// The store is an immutable `Sendable` struct with no cache: every read goes
/// to the Keychain.
package struct KeychainTrustStore: Sendable {
  /// Platform statuses that a person can resolve by unlocking,
  /// authenticating, or allowing interaction.
  private static let userActionStatuses: Set<OSStatus> = [
    errSecInteractionNotAllowed,
    errSecInteractionRequired,
    errSecAuthFailed,
    errSecUserCanceled,
  ]

  /// The task was cancelled before any Keychain operation was issued, so
  /// nothing was read or written.
  private static let cancellationFailure = CoreError(
    code: .cancellation(.requested),
    severity: .info,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// The read succeeded but returned no data. There is no failing status to
  /// report, so no diagnostic code is invented.
  private static let unreadableFailure = CoreError(
    code: .security(.secureStorageUnavailable),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  /// The value to insert is not a raw SHA-256 digest. Refused before any
  /// Keychain work, so nothing malformed is ever persisted.
  private static let invalidFingerprintFailure = CoreError(
    code: .security(.trustRejected),
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private let environment: KeychainTrustStoreEnvironment

  /// Production initializer: the data-protection Keychain. Performs no
  /// Keychain work.
  package init() {
    self.init(environment: .live)
  }

  init(environment: KeychainTrustStoreEnvironment) {
    self.environment = environment
  }

  /// Returns the fingerprint stored for `deviceID` exactly as found, `nil` when
  /// no record exists, or a failure.
  ///
  /// The stored length is not judged here; a malformed value is returned
  /// unchanged so the caller can fail closed on it. A successful read that
  /// yields no data is a failure, never a missing record.
  @concurrent
  package func loadFingerprint(for deviceID: DeviceID) async -> CoreResult<Data?> {
    guard !Task.isCancelled else { return .failure(Self.cancellationFailure) }
    let account = KeychainTrustStoreEnvironment.account(for: deviceID)
    let reply = await environment.readItem(account)
    return Self.interpret(reply)
  }

  /// Stores `fingerprint` for `deviceID` unless a record already exists.
  ///
  /// The order is fixed:
  ///
  /// 1. refuse a fingerprint that is not exactly
  ///    `CertificateFingerprint.sha256DigestLength` bytes with
  ///    `security.trustRejected`;
  /// 2. fail with `cancellation.requested` if the task is already cancelled;
  /// 3. issue one atomic add. Success is `.inserted`;
  /// 4. on duplicate-item, read the existing record and report it as
  ///    `.existing`. A record that vanished in between, or cannot be read,
  ///    fails closed; the add is never repeated.
  ///
  /// Once the add has been issued, its result is reported even if the task is
  /// cancelled meanwhile.
  @concurrent
  package func insertFingerprintIfAbsent(
    _ fingerprint: Data,
    for deviceID: DeviceID
  ) async -> CoreResult<KeychainTrustInsertOutcome> {
    guard fingerprint.count == CertificateFingerprint.sha256DigestLength else {
      return .failure(Self.invalidFingerprintFailure)
    }
    guard !Task.isCancelled else { return .failure(Self.cancellationFailure) }

    let account = KeychainTrustStoreEnvironment.account(for: deviceID)
    let status = await environment.addItem(account, Data(fingerprint))
    switch status {
    case errSecSuccess:
      return .success(.inserted)
    case errSecDuplicateItem:
      return await existingRecord(account: account)
    default:
      return .failure(Self.storageFailure(status))
    }
  }

  /// Removes the record for `deviceID`. A missing record is success, so the
  /// call is idempotent; any other failure is reported.
  ///
  /// Removal is cleanup and only ever withdraws trust, so it runs even from a
  /// cancelled task rather than leaving behind a record the caller asked to
  /// remove. A record that cannot be read is still removable.
  @concurrent
  package func removeFingerprint(for deviceID: DeviceID) async -> CoreResult<Void> {
    let account = KeychainTrustStoreEnvironment.account(for: deviceID)
    let status = await environment.deleteItem(account)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      return .failure(Self.storageFailure(status))
    }
    return .success(())
  }

  /// Reads the record an add reported as a duplicate. This completes the add
  /// already issued, so cancellation is not observed again.
  private func existingRecord(account: String) async -> CoreResult<KeychainTrustInsertOutcome> {
    let reply = await environment.readItem(account)
    switch Self.interpret(reply) {
    case .success(let stored?):
      return .success(.existing(storedFingerprint: stored))
    case .success(.none):
      return .failure(Self.storageFailure(errSecItemNotFound))
    case .failure(let error):
      return .failure(error)
    }
  }

  private static func interpret(_ reply: KeychainItemReadReply) -> CoreResult<Data?> {
    switch reply {
    case .data(let stored):
      return .success(stored)
    case .status(errSecItemNotFound):
      return .success(nil)
    case .nonData, .status(errSecSuccess):
      return .failure(unreadableFailure)
    case .status(let status):
      return .failure(storageFailure(status))
    }
  }

  /// A Keychain failure carrying only `status`. Statuses a person can resolve
  /// require user action; nothing is retried automatically.
  private static func storageFailure(_ status: OSStatus) -> CoreError {
    CoreError(
      code: .security(.secureStorageUnavailable),
      severity: .error,
      retryDisposition: userActionStatuses.contains(status) ? .userActionRequired : .never,
      cleanupDisposition: .notRequired,
      underlyingDiagnosticCode: UnderlyingDiagnosticCode(rawValue: status)
    )
  }
}

/// The two-phase first-use flow over a `KeychainTrustStore`.
///
/// `evaluate` only reads: a missing record answers `.prompt` and writes
/// nothing, so prompting is never trust-on-first-use. Only `apply` with an
/// explicit `.trust` from the owner writes, and only if no record exists. An
/// explicit `.reject` never writes.
///
/// Decisions follow the C-009 `TrustPolicy`: the same fingerprint allows, a
/// different one rejects with `identityChanged`, and a fingerprint of the
/// wrong length, presented or stored, rejects with `trustRejected`. A storage
/// failure is reported as a failure, never turned into a prompt or an
/// acceptance.
///
/// A presented fingerprint of the wrong length is rejected before any
/// Keychain work, whatever is stored and whatever the owner decided.
package struct FirstUseTrustCoordinator: Sendable {
  private let store: KeychainTrustStore

  package init(store: KeychainTrustStore) {
    self.store = store
  }

  /// Decides whether `presentedFingerprint` may proceed for `deviceID` from
  /// what is stored. Never writes.
  package func evaluate(
    deviceID: DeviceID,
    presentedFingerprint: Data
  ) async -> CoreResult<FirstUseTrustOutcome> {
    guard Self.isSHA256Digest(presentedFingerprint) else {
      return .success(.reject(.trustRejected))
    }
    switch await store.loadFingerprint(for: deviceID) {
    case .success(.none):
      return .success(Self.decide(state: .unknown, presented: presentedFingerprint))
    case .success(let stored?):
      let state = TrustPolicyState.trusted(fingerprint: stored)
      return .success(Self.decide(state: state, presented: presentedFingerprint))
    case .failure(let error):
      return .failure(error)
    }
  }

  /// Applies the owner's explicit answer to a prompt for `presentedFingerprint`.
  ///
  /// `.reject` answers `.reject(.trustRejected)` and never writes. `.trust`
  /// inserts the fingerprint if no record exists and answers `.allow`. If a
  /// record already exists it is never replaced: the same fingerprint allows,
  /// a different one rejects with `identityChanged`, and a malformed one
  /// rejects with `trustRejected`.
  package func apply(
    ownerDecision: FirstUseOwnerDecision,
    deviceID: DeviceID,
    presentedFingerprint: Data
  ) async -> CoreResult<FirstUseTrustOutcome> {
    guard Self.isSHA256Digest(presentedFingerprint) else {
      return .success(.reject(.trustRejected))
    }
    switch ownerDecision {
    case .reject:
      return .success(.reject(.trustRejected))
    case .trust:
      return await trust(deviceID: deviceID, presentedFingerprint: presentedFingerprint)
    }
  }

  private func trust(
    deviceID: DeviceID,
    presentedFingerprint: Data
  ) async -> CoreResult<FirstUseTrustOutcome> {
    switch await store.insertFingerprintIfAbsent(presentedFingerprint, for: deviceID) {
    case .success(.inserted):
      return .success(.allow)
    case .success(.existing(let stored)):
      let state = TrustPolicyState.trusted(fingerprint: stored)
      return .success(Self.decide(state: state, presented: presentedFingerprint))
    case .failure(let error):
      return .failure(error)
    }
  }

  private static func decide(state: TrustPolicyState, presented: Data) -> FirstUseTrustOutcome {
    switch TrustPolicy.decide(state: state, presentedFingerprint: presented) {
    case .prompt:
      return .prompt
    case .allow:
      return .allow
    case .reject(let code):
      return .reject(code)
    }
  }

  private static func isSHA256Digest(_ fingerprint: Data) -> Bool {
    fingerprint.count == CertificateFingerprint.sha256DigestLength
  }
}

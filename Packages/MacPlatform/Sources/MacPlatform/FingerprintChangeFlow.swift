import Foundation
import KVMContracts

/// The device owner's explicit answer to a fingerprint change warning.
///
/// Only a person supplies this value. Nothing in this file derives it from a
/// warning, a stored record, a timeout, or a cancellation.
package enum FingerprintChangeOwnerDecision: Equatable, Sendable {
  /// Replace the trusted fingerprint with the one the device presented.
  case repair

  /// Keep the trusted fingerprint. Nothing is read, removed, or stored.
  case reject
}

/// What the owner is shown when a trusted device presents a different
/// fingerprint: the one deliberate presentation of both fingerprints.
///
/// Only `trustedFingerprintDisplay` and `presentedFingerprintDisplay` carry
/// them, as `CertificateFingerprint.canonicalDisplay` text for a person to
/// compare. Every other rendering of the value — `description`,
/// `debugDescription`, interpolation, `dump`, and reflection — is redacted, so
/// logging or printing it by accident cannot leak either fingerprint or the
/// device. No outcome other than `.identityChanged`, and no error, carries a
/// warning.
///
/// A warning exists only for two different raw SHA-256 digests. Package callers
/// receive it only from `FingerprintChangeFlow`, so a re-pair always names the
/// exact device and fingerprints the owner was shown.
package struct FingerprintChangeWarning: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  /// The fingerprint trusted for the device, as canonical display text.
  package let trustedFingerprintDisplay: String

  /// The fingerprint the device presented, as canonical display text.
  package let presentedFingerprintDisplay: String

  /// The device whose identity changed.
  let deviceID: DeviceID

  /// The trusted raw digest. A re-pair replaces only a record holding exactly
  /// these bytes.
  let trustedFingerprint: Data

  /// The presented raw digest. A re-pair stores exactly these bytes.
  let presentedFingerprint: Data

  /// Returns `nil` unless both fingerprints are raw digests of exactly
  /// `CertificateFingerprint.sha256DigestLength` bytes and they differ.
  ///
  /// Both digests are copied by content, so a warning never keeps a caller's
  /// larger buffer alive.
  init?(deviceID: DeviceID, trustedFingerprint: Data, presentedFingerprint: Data) {
    guard trustedFingerprint != presentedFingerprint,
      case .success(let trustedDisplay) = CertificateFingerprint.canonicalDisplay(
        ofSHA256Digest: trustedFingerprint),
      case .success(let presentedDisplay) = CertificateFingerprint.canonicalDisplay(
        ofSHA256Digest: presentedFingerprint)
    else { return nil }
    self.trustedFingerprintDisplay = trustedDisplay
    self.presentedFingerprintDisplay = presentedDisplay
    self.deviceID = deviceID
    self.trustedFingerprint = Data(trustedFingerprint)
    self.presentedFingerprint = Data(presentedFingerprint)
  }

  package var description: String { "FingerprintChangeWarning(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

/// What the fingerprint change flow concluded for one presented fingerprint.
///
/// Only `.allow` lets a connection proceed. Every other case, `.prompt`
/// included, leaves the connection at hand rejected.
package enum FingerprintChangeOutcome: Equatable, Sendable {
  /// No trust record exists. The caller must ask the owner through
  /// `FirstUseTrustCoordinator`; this is not an acceptance and must never be
  /// treated as one.
  case prompt

  /// The presented fingerprint equals the trusted one.
  case allow

  /// The connection must not proceed, for the given reason. Nothing is
  /// offered to the owner.
  case reject(SecurityErrorCode)

  /// The device presented a fingerprint other than the trusted one. The
  /// connection is rejected now, exactly as for `.reject(.identityChanged)`;
  /// the warning only lets the owner compare both fingerprints and, by an
  /// explicit decision, re-pair.
  case identityChanged(FingerprintChangeWarning)
}

/// The fingerprint change warning and reject flow over a `KeychainTrustStore`.
///
/// `evaluate` only reads. Decisions follow the C-009 `TrustPolicy`: a missing
/// record prompts, the same fingerprint allows, and a fingerprint of the wrong
/// length, presented or stored, rejects with `trustRejected`. A different
/// fingerprint for the same device is rejected at once as `.identityChanged`,
/// carrying the warning; it is never stored, never overwrites the trusted
/// record, and is never accepted automatically.
///
/// `apply` records the owner's explicit answer to a warning. `.reject` keeps
/// the trusted record and performs no Keychain work. `.repair` is the only path
/// that writes, and moves through these states in order:
///
/// 1. **Check.** Read the record. Unless it still holds the warning's trusted
///    fingerprint, nothing changes and the outcome describes the presented
///    fingerprint against the record as read: already stored → `.allow`;
///    missing → `.prompt`; another fingerprint → `.identityChanged` with a new
///    warning; malformed → `.reject(.trustRejected)`.
/// 2. **Last point without change.** A cancelled task stops here with
///    `cancellation.requested`. This is where cancellation is honored;
///    removal never observes it.
/// 3. **Remove** the trusted record. If removal fails, nothing is inserted.
/// 4. **Insert** the presented fingerprint if no record exists. Once removal
///    has been issued, the insert is issued too, even for a task cancelled
///    meanwhile, so cancellation alone never leaves the device without a
///    record. From the removal until this insert, the device has no record:
///    it evaluates as `.prompt`, never `.allow`. If the insert fails, the
///    device is left that way. The replaced fingerprint is never restored,
///    because trusting it again is the owner's decision alone, and nothing is
///    retried. A record another writer stored meanwhile is never replaced.
/// 5. **Verify.** Read again and report the presented fingerprint against
///    this read. A read that fails, or that the store refuses because the
///    task was cancelled before the read was issued, is a failure: a re-pair
///    cancelled before this point is never reported as a success, even when
///    the presented fingerprint was stored.
///
/// `.allow` comes only from a read that allows the presented fingerprint: the
/// verifying read, or the check when the presented fingerprint is already
/// stored. A failure says why the flow stopped, not what the record holds: it
/// can come before anything changed, after the trusted record was removed, or
/// after the presented fingerprint was stored. After any failure, and any
/// outcome other than `.allow`, the caller keeps the connection rejected and
/// calls `evaluate` to learn the current state.
///
/// Every Keychain failure is the store's `security.secureStorageUnavailable`
/// failure, and cancellation is `cancellation.requested`; neither is ever
/// turned into a prompt or an acceptance. No outcome other than
/// `.identityChanged`, and no failure, carries a fingerprint, account, or
/// device identifier. Nothing logs.
///
/// The flow is an immutable `Sendable` struct with no cache or lock. It reaches
/// the Keychain only through the store, which never updates a record and runs
/// every Keychain call off the caller's actor.
package struct FingerprintChangeFlow: Sendable {
  /// The task was cancelled before the trusted record was removed, so nothing
  /// was changed.
  private static let cancellationFailure = CoreError(
    code: .cancellation(.requested),
    severity: .info,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private let store: KeychainTrustStore

  package init(store: KeychainTrustStore) {
    self.store = store
  }

  /// Decides whether `presentedFingerprint` may proceed for `deviceID` from
  /// what is stored. Never writes.
  ///
  /// A presented fingerprint of the wrong length is rejected before any
  /// Keychain work. `presentedFingerprint` may be a slice with a non-zero
  /// start index; only its own bytes are compared.
  package func evaluate(
    deviceID: DeviceID,
    presentedFingerprint: Data
  ) async -> CoreResult<FingerprintChangeOutcome> {
    guard presentedFingerprint.count == CertificateFingerprint.sha256DigestLength else {
      return .success(.reject(.trustRejected))
    }
    return await currentOutcome(deviceID: deviceID, presented: presentedFingerprint)
  }

  /// Applies the owner's explicit answer to `warning`.
  ///
  /// `.reject` answers `.reject(.trustRejected)` and performs no Keychain
  /// work, whether or not the task is cancelled. `.repair` replaces the
  /// trusted record with the presented fingerprint in the order documented on
  /// the type. After a failure, or any outcome other than `.allow`, keep the
  /// connection rejected and call `evaluate` to learn what the record holds.
  package func apply(
    ownerDecision: FingerprintChangeOwnerDecision,
    warning: FingerprintChangeWarning
  ) async -> CoreResult<FingerprintChangeOutcome> {
    switch ownerDecision {
    case .reject:
      return .success(.reject(.trustRejected))
    case .repair:
      return await repair(warning)
    }
  }

  private func repair(
    _ warning: FingerprintChangeWarning
  ) async -> CoreResult<FingerprintChangeOutcome> {
    let deviceID = warning.deviceID
    let presented = warning.presentedFingerprint

    let current: Data?
    switch await store.loadFingerprint(for: deviceID) {
    case .success(let stored):
      current = stored
    case .failure(let error):
      return .failure(error)
    }
    guard current == warning.trustedFingerprint else {
      return .success(Self.outcome(deviceID: deviceID, stored: current, presented: presented))
    }

    guard !Task.isCancelled else { return .failure(Self.cancellationFailure) }

    if case .failure(let error) = await store.removeFingerprint(for: deviceID) {
      return .failure(error)
    }
    // Removal has been issued, so the insert is issued too: cancellation alone
    // must never leave the device without a record. The store refuses an
    // insert from a cancelled task, so it runs in a task of its own, which
    // cancelling the caller does not cancel.
    let insertion = await Task { [store] in
      await store.insertFingerprintIfAbsent(presented, for: deviceID)
    }.value
    if case .failure(let error) = insertion {
      return .failure(error)
    }
    return await currentOutcome(deviceID: deviceID, presented: presented)
  }

  /// Reads the record for `deviceID` and judges `presented` against it.
  private func currentOutcome(
    deviceID: DeviceID,
    presented: Data
  ) async -> CoreResult<FingerprintChangeOutcome> {
    switch await store.loadFingerprint(for: deviceID) {
    case .success(let stored):
      return .success(Self.outcome(deviceID: deviceID, stored: stored, presented: presented))
    case .failure(let error):
      return .failure(error)
    }
  }

  /// The C-009 decision for `presented` against `stored`, carrying the
  /// warning when the identity changed.
  ///
  /// `TrustPolicy` decides; the warning is only attached to its
  /// `identityChanged` rejection.
  private static func outcome(
    deviceID: DeviceID,
    stored: Data?,
    presented: Data
  ) -> FingerprintChangeOutcome {
    let state: TrustPolicyState = stored.map { .trusted(fingerprint: $0) } ?? .unknown
    let decision = TrustPolicy.decide(state: state, presentedFingerprint: presented)
    if decision == .reject(.identityChanged), let stored,
      let warning = FingerprintChangeWarning(
        deviceID: deviceID, trustedFingerprint: stored, presentedFingerprint: presented)
    {
      return .identityChanged(warning)
    }
    switch decision {
    case .prompt:
      return .prompt
    case .allow:
      return .allow
    case .reject(let code):
      return .reject(code)
    }
  }
}

import KVMContracts

/// Clipboard rejections carry the frozen taxonomy value and nothing else.
///
/// The dispositions match the M1-052 codec exactly: the rejection is terminal
/// for this payload, retrying the same payload can only be rejected the same
/// way, and nothing was acquired before the check. No text, byte count, hash,
/// transaction ID, or device ID can escape through the value.
private func clipboardRejection(_ code: ClipboardErrorCode) -> CoreError {
  CoreError(
    code: .clipboard(code),
    severity: .warning,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

/// Caller-owned loop and size admission state for clipboard transfers.
///
/// The guard remembers exactly one synchronized payload identity: the
/// transaction ID and opaque content hash of the last payload it admitted in
/// either direction. It never stores text, holds no collection, and grows with
/// nothing, so there is no capacity, eviction, or expiry policy to choose.
///
/// Admission rules, checked in this fixed order:
///
/// 1. Size: a payload over the caller-supplied `ClipboardByteLimit` is
///    rejected as `clipboard.oversized` before any other check.
/// 2. Origin: outbound payloads must be `.local` and inbound payloads must be
///    `.remote`. Anything else is a payload travelling back toward where it
///    came from and is rejected as `clipboard.loopRejected`.
/// 3. Transaction: a payload whose transaction ID equals the remembered one is
///    a replay or echo of that transaction and is rejected as
///    `clipboard.loopRejected`.
/// 4. Hash: a payload whose content hash equals the remembered one carries
///    content that is already synchronized, such as the local pasteboard
///    change caused by applying an inbound payload, and is rejected as
///    `clipboard.loopRejected`.
///
/// Only an admitted payload replaces the remembered identity. A rejection
/// leaves the state unchanged.
///
/// `contentHash` is treated as opaque identity metadata and compared for exact
/// equality. No algorithm is frozen for it, so the guard neither computes nor
/// verifies it; the caller must produce it the same way for both directions.
///
/// The type is a `Sendable` value with no locks, clock, randomness, or shared
/// state. Concurrency safety comes from ownership: the single owner, such as a
/// session actor, mutates its own copy.
package struct ClipboardLoopGuard: Equatable, Sendable {
  private struct Identity: Equatable, Sendable {
    let transactionID: ClipboardTransactionID
    let contentHash: String
  }

  private var lastSynchronized: Identity?

  /// Creates a guard that remembers no payload.
  package init() {}

  /// Admits a payload about to be sent to a peer and remembers it.
  package mutating func admitOutbound(
    _ payload: ClipboardPayload,
    limit: ClipboardByteLimit
  ) throws(CoreError) {
    try Self.checkSize(of: payload, limit: limit)
    guard case .local = payload.origin else {
      throw clipboardRejection(.loopRejected)
    }
    try admit(payload)
  }

  /// Admits a payload received from a peer before it is applied locally and
  /// remembers it.
  package mutating func admitInbound(
    _ payload: ClipboardPayload,
    limit: ClipboardByteLimit
  ) throws(CoreError) {
    try Self.checkSize(of: payload, limit: limit)
    guard case .remote = payload.origin else {
      throw clipboardRejection(.loopRejected)
    }
    try admit(payload)
  }

  /// Forgets the remembered payload.
  ///
  /// Repeated calls are no-ops.
  package mutating func reset() {
    lastSynchronized = nil
  }

  private mutating func admit(_ payload: ClipboardPayload) throws(CoreError) {
    if let lastSynchronized {
      guard payload.transactionID != lastSynchronized.transactionID,
        payload.contentHash != lastSynchronized.contentHash
      else {
        throw clipboardRejection(.loopRejected)
      }
    }
    lastSynchronized = Identity(
      transactionID: payload.transactionID,
      contentHash: payload.contentHash
    )
  }

  private static func checkSize(
    of payload: ClipboardPayload,
    limit: ClipboardByteLimit
  ) throws(CoreError) {
    guard payload.utf8ByteCount <= limit.byteCount else {
      throw clipboardRejection(.oversized)
    }
  }
}

// Every rendering is redacted so that printing the guard by accident cannot
// reveal a remembered transaction ID or content hash.

extension ClipboardLoopGuard: CustomStringConvertible {
  package var description: String { "ClipboardLoopGuard(redacted)" }
}

extension ClipboardLoopGuard: CustomDebugStringConvertible {
  package var debugDescription: String { description }
}

extension ClipboardLoopGuard: CustomReflectable {
  package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

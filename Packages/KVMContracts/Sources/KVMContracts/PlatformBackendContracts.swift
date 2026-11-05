import Foundation

// C-015 PlatformBackend (M4-002): six independent contracts between the KVM core and one
// platform, namely input injection, screen, clipboard, secure storage, lifecycle and capture.
// Their inputs and outputs are KVM contract values (`KVMEvent`, `CoreResult`, `CoreError`,
// `ClipboardByteLimit`) and the small values declared here; no operating-system type, key code
// or handle crosses them. The rules in each protocol's documentation are part of its contract:
// a conformer that breaks one is wrong even when it compiles. Conformers live in platform
// modules; nothing in this file does platform work.

// MARK: - Input injection

/// What an injection backend did with one input event.
public enum InjectionOutcome: Equatable, Sendable {
  /// The platform accepted the event.
  case injected

  /// The platform cannot express the event. Nothing was injected, and the backend holds
  /// nothing new.
  case unsupported(InjectionUnsupportedReason)
}

/// Why an injection backend could not express an event.
///
/// The set is closed: a new reason is a contract change, never a backend's choice.
public enum InjectionUnsupportedReason: String, Codable, CaseIterable, Sendable {
  /// The key is `unknown`, or a `letter`, `digit` or `function` whose payload is outside its
  /// C-005 catalog domain (M1-042). Its value is never used as a platform key code.
  case unknownKey

  /// The key is a catalog member, but the platform's current keyboard mapping has no key code
  /// for it.
  case noPlatformKeyCode

  /// The platform's pointer has no such button.
  case buttonUnavailable

  /// A key repeat, declined by a backend whose platform repeats held keys itself.
  case repeatNotInjected
}

/// Injects platform-neutral input into the local platform.
///
/// Rules:
///
/// - Input is `.mouseMove`, `.mouseButton`, `.scroll` and `.key`. `.clipboard`, `.enterScreen`
///   and `.leaveScreen` are not input: `inject(_:)` changes nothing and fails with
///   `internal.preconditionFailed`.
/// - A `.key` whose key is `unknown`, or a `letter`, `digit` or `function` outside its catalog
///   domain, is `.unsupported(.unknownKey)` in every phase.
/// - Releasing a key or button this backend pressed releases exactly the platform key or button
///   it pressed, even when the keyboard mapping or the pointer changed in between, so such a
///   release is never `.unsupported`. A release of input the backend does not hold is injected
///   like any other event; releasing what is not pressed leaves nothing held.
/// - `.unsupported` means nothing was injected. By the release rule, a caller that recorded such
///   input as held can still release it safely.
/// - Calls are synchronous and bounded: they return without awaiting and never wait on the
///   network or a person. The backend hands each event to the platform before returning and
///   keeps no queue of events; the caller owns queueing.
/// - Calls may come from any thread. A conformer applies them one at a time, and calls made one
///   after another take effect in that order.
/// - The backend's record of what it pressed is the authority for what the platform holds.
///   Terminal paths call `releaseAllHeld()` after their own releases, because a release the
///   caller already counted may have been dropped before it reached the backend.
/// - A conformer never logs or persists key identities or typed text (Frozen Decision 8). It
///   keeps the platform codes of the input it holds in memory only, for the release rule and
///   `releaseAllHeld()`.
public protocol InputInjectionBackend: Sendable {
  /// Injects one input event, or reports why it could not.
  ///
  /// Every `.failure` is terminal for the caller, and its code tells the cases apart:
  /// `internal.preconditionFailed` for an event that is not input, or a platform code such as
  /// `lifecycle.subsystemUnavailable` when the platform cannot take input at all.
  func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome>

  /// Returns once the platform has processed every event injected before the call.
  ///
  /// Terminal paths call it after their releases, so that cleanup is reported complete only
  /// once the releases took effect. It may be called any number of times.
  func flush() -> CoreResult<Void>

  /// Releases every key and button this backend pressed and has not released: keys other than
  /// modifiers first, then buttons, then modifier keys (`shift`, `control`, `option`, `command`
  /// and `capsLock`, the catalog's modifier group), each group in reverse press order, each with
  /// the platform code it was pressed with.
  ///
  /// It hands the releases to the platform as `inject(_:)` does; terminal paths call `flush()`
  /// after it. It succeeds only when nothing this backend pressed is still pressed, and
  /// otherwise fails with `inputSafety.cleanupPartial`. Input whose release failed stays
  /// recorded, so a later call tries it again; input already released is never released again,
  /// so a second call after a success releases nothing.
  func releaseAllHeld() -> CoreResult<Void>
}

// MARK: - Screen

/// The local desktop and pointer, in the platform's pixel coordinates.
///
/// `originX` and `originY` are the desktop's top-left corner, `width` and `height` its size, and
/// `cursorX` and `cursorY` the pointer's position in the same coordinates.
public struct PlatformScreenGeometry: Equatable, Codable, Sendable {
  public let originX: Int
  public let originY: Int
  public let width: Int
  public let height: Int
  public let cursorX: Int
  public let cursorY: Int

  public init(originX: Int, originY: Int, width: Int, height: Int, cursorX: Int, cursorY: Int) {
    self.originX = originX
    self.originY = originY
    self.width = width
    self.height = height
    self.cursorX = cursorX
    self.cursorY = cursorY
  }
}

/// Reports the local desktop's geometry and its changes.
///
/// Rules:
///
/// - `currentGeometry()` is synchronous and bounded. It never succeeds with a width or height
///   below 1; it fails instead.
/// - `changes` is one stream for the backend's lifetime, with one consumer. It observes from the
///   backend's creation, so a consumer that reads `currentGeometry()` first misses no later
///   change. A change is a change of the desktop's origin or size; pointer movement alone is
///   not one. It yields the new geometry, never one with a width or height below 1, and may
///   coalesce: a consumer that falls behind receives the newest geometry, not every one in
///   between.
/// - `stop()` is idempotent and bounded, also from a cancelled task. It finishes `changes`, and
///   every later `currentGeometry()` fails with `lifecycle.subsystemUnavailable`.
public protocol ScreenBackend: Sendable {
  func currentGeometry() -> CoreResult<PlatformScreenGeometry>
  var changes: AsyncStream<PlatformScreenGeometry> { get }
  func stop() async
}

// MARK: - Clipboard

/// Plain text read from the local clipboard, with its hash.
///
/// `contentHash` is the lowercase hexadecimal SHA-256 digest of the text's UTF-8 bytes (64
/// characters), so every producer computes the same value from the same text. It is only ever
/// compared.
///
/// Every rendering of the value (`description`, `debugDescription`, interpolation, `dump` and
/// reflection) is redacted, so printing it by accident shows neither the text nor the hash
/// (Frozen Decision 8). Only the two properties carry them, and the value is not `Encodable`.
public struct PlatformClipboardText: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let text: String
  public let contentHash: String

  public init(text: String, contentHash: String) {
    self.text = text
    self.contentHash = contentHash
  }

  public var description: String { "PlatformClipboardText(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

/// The local clipboard, as UTF-8 plain text only (C-007).
///
/// Rules:
///
/// - Both directions bound content by the caller's `ClipboardByteLimit`. A read never holds
///   more than `limit` bytes of content: it refuses as soon as the size the platform states, or
///   the content received so far, would pass the limit, and it measures content that a platform
///   hands over whole before returning any of it. A write measures the text before encoding it.
///   Content over the limit fails with `clipboard.oversized` and leaves the clipboard as it was.
/// - A read is bounded in time: when the clipboard's owner does not hand the content over in
///   time, the read fails with `timeout.read` and changes nothing.
/// - `readPlainText(limit:)` succeeds with `nil` when the clipboard holds no text. Bytes that
///   are not well-formed UTF-8 fail with `clipboard.invalidUTF8` and are never repaired.
/// - After a successful `writePlainText(_:limit:)` the backend owns the clipboard with exactly
///   the text, until another application takes it.
/// - `ownerChanges` has one consumer. It yields when another application takes the clipboard,
///   never for this backend's own writes, carries no content and may coalesce.
/// - A call made from an already cancelled task fails with `cancellation.requested` and changes
///   nothing.
/// - `stop()` is idempotent and bounded, also from a cancelled task. It finishes
///   `ownerChanges`, and every later read or write fails with `lifecycle.subsystemUnavailable`.
/// - A conformer never logs clipboard text or hashes (Frozen Decision 8).
public protocol ClipboardBackend: Sendable {
  func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?>
  func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void>
  var ownerChanges: AsyncStream<Void> { get }
  func stop() async
}

// MARK: - Secure storage

/// The key under which a client keeps its trust in one peer: `host:port`, normalized.
///
/// A host is printable ASCII, `!` to `~`: no space, control character or non-ASCII letter, so an
/// internationalized name is given in its ASCII form. Normalization lowercases the host's
/// letters, the case host names ignore (RFC 4343), and writes the port in decimal without
/// leading zeros. Spellings of one peer that differ in more than letter case, such as a name and
/// an address or a trailing dot, are different keys: the second one is an unknown peer and
/// prompts, it never borrows trust.
///
/// `init?(rawValue:)` and decoding apply the same rules to a stored `host:port`: an uppercase
/// host is lowercased, and anything else that is not a valid key is refused. Comparing a value
/// with the parsed key's `rawValue` tells whether it was already normalized.
public struct PeerKey: Hashable, Codable, Sendable {
  public let rawValue: String

  /// Returns `nil` for an empty host, a host with a character outside printable ASCII, or port
  /// 0. Such a key could not name a peer, and could not be written to a line-based store or
  /// shown to a person unambiguously.
  public init?(host: String, port: UInt16) {
    guard port != 0, Self.isUsableHost(host) else { return nil }
    rawValue = "\(Self.lowercasingASCII(host)):\(port)"
  }

  /// Parses `host:port` with the rules of `init?(host:port:)`. It splits at the last colon, so a
  /// host may itself contain colons (an IPv6 address), and takes the port only as `String(port)`
  /// writes it: decimal digits, no sign and no leading zero.
  public init?(rawValue: String) {
    guard let separator = rawValue.lastIndex(of: ":"),
      let port = Self.decimalPort(rawValue[rawValue.index(after: separator)...])
    else { return nil }
    self.init(host: String(rawValue[..<separator]), port: port)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let stored = try container.decode(String.self, forKey: .rawValue)
    guard let key = PeerKey(rawValue: stored) else {
      throw DecodingError.dataCorruptedError(
        forKey: .rawValue,
        in: container,
        debugDescription: "not a host:port peer key"
      )
    }
    self = key
  }

  private enum CodingKeys: String, CodingKey {
    case rawValue
  }

  private static let printableASCII = UInt8(ascii: "!")...UInt8(ascii: "~")
  private static let uppercaseASCII = UInt8(ascii: "A")...UInt8(ascii: "Z")
  private static let decimalDigits = UInt8(ascii: "0")...UInt8(ascii: "9")

  private static func isUsableHost(_ host: String) -> Bool {
    !host.isEmpty && host.utf8.allSatisfy { printableASCII.contains($0) }
  }

  private static func lowercasingASCII(_ host: String) -> String {
    let distance = UInt8(ascii: "a") - UInt8(ascii: "A")
    let bytes = host.utf8.map { uppercaseASCII.contains($0) ? $0 + distance : $0 }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Range and port 0 are left to `UInt16` and `init?(host:port:)`.
  private static func decimalPort(_ text: Substring) -> UInt16? {
    guard let first = text.utf8.first, first != UInt8(ascii: "0"),
      text.utf8.allSatisfy({ decimalDigits.contains($0) })
    else { return nil }
    return UInt16(text)
  }
}

/// What `insertTrustedFingerprintIfAbsent(_:for:)` did.
public enum TrustInsertOutcome: Equatable, Sendable {
  /// No record existed; the fingerprint is now stored.
  case inserted

  /// A record already existed and was left exactly as it was. `storedFingerprint` is what is
  /// stored, which may differ from the presented value or be malformed: judging it is the C-009
  /// trust policy's job, not the store's.
  case existing(storedFingerprint: Data)
}

/// A client's store of trusted peer fingerprints, the trust state of C-009.
///
/// This is the client role's trust-record store only. It holds no private key, certificate or
/// revocation state: keeping a local identity, or revoked and rotated trust (M3-014), needs a
/// contract of its own.
///
/// Rules:
///
/// - The store holds raw SHA-256 certificate fingerprints, one per `PeerKey`, and nothing else.
/// - Its records are kept where only the user can change them. A store that cannot ensure that,
///   for example because its record file is writable by other users or has been replaced by a
///   link, fails every operation with `security.secureStorageUnavailable` and reads or writes no
///   record.
/// - `loadTrustedFingerprint(for:)` returns the stored value exactly as found and never repairs
///   it; the trust policy judges its length. It returns `nil` only when no record exists. A
///   store that cannot read its records, or finds them malformed, fails with
///   `security.secureStorageUnavailable`, never `nil`, so a storage problem never looks like an
///   unknown peer.
/// - `insertTrustedFingerprintIfAbsent(_:for:)` refuses a value that is not exactly 32 bytes
///   with `security.trustRejected` before any storage work, also from a cancelled task. It never
///   replaces a record: an existing one is left as it was and reported as `.existing`. Of
///   concurrent inserts for one peer exactly one reports `.inserted`, and every other one
///   reports `.existing` with the value that one stored.
/// - `removeTrustedFingerprint(for:)` is idempotent: a missing record is success. It only
///   withdraws trust, so it runs even from a cancelled task.
/// - A load or insert made from an already cancelled task fails with `cancellation.requested`
///   and reads or writes nothing.
/// - A conformer never logs a fingerprint.
public protocol SecureStorageBackend: Sendable {
  func loadTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Data?>
  func insertTrustedFingerprintIfAbsent(
    _ fingerprint: Data,
    for peer: PeerKey
  ) async -> CoreResult<TrustInsertOutcome>
  func removeTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Void>
}

// MARK: - Lifecycle

/// A change in the local platform that the client reacts to. No signal carries data.
public enum LifecycleSignal: Equatable, Sendable {
  /// The machine is about to sleep.
  case willSuspend

  /// The machine woke from sleep.
  case didResume

  /// A network path became available.
  case networkAvailable

  /// No network path is available any more.
  case networkUnavailable

  /// The platform asked the application to terminate.
  case terminationRequested
}

/// Reports platform lifecycle changes.
///
/// Rules:
///
/// - `signals` has one consumer and yields each change once, in the order it was observed.
/// - Nothing is dropped silently. Network edges may be merged so that only the newest network
///   state remains, but `willSuspend`, `didResume` and `terminationRequested` are never merged
///   or dropped. A backend that cannot deliver a signal finishes `signals` instead, and the
///   consumer treats that end as the monitor's failure.
/// - `stop()` is synchronous, idempotent and bounded, and finishes `signals`.
public protocol LifecycleBackend: Sendable {
  var signals: AsyncStream<LifecycleSignal> { get }
  func stop()
}

// MARK: - Capture

/// Captures local input as platform-neutral events. C-015 names it; the first-party Linux
/// client, which only injects, has no conformer.
///
/// Rules:
///
/// - An instance is single-use: only the first `start()` can succeed, and every later one fails
///   with `internal.preconditionFailed`. When the platform refuses capture, `start()` fails
///   closed with a typed `CoreError` (for example `permission.capabilityUnavailable`),
///   suppresses nothing and finishes `events`.
/// - `events` has one consumer and yields captured input in capture order. As in the M2-003
///   capture queue, pointer moves may be merged, and a move that does not fit may be dropped,
///   because a later move carries the newer absolute position; consecutive scrolls may be
///   summed. Any other event is never dropped or reordered: a backend that cannot deliver one
///   stops capture as `stop()` does, and the consumer treats the end of the stream as a
///   terminal path.
/// - `stop()` is synchronous, idempotent and bounded, and may be called before `start()`. It
///   ends capture and any suppression of local input before it returns (Frozen Decision 7), and
///   finishes `events`.
public protocol CaptureBackend: Sendable {
  func start() throws(CoreError)
  func stop()
  var events: AsyncStream<KVMEvent> { get }
}

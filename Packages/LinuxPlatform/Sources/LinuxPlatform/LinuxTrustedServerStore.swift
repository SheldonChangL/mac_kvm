import Dispatch
import Foundation
import Glibc
import KVMContracts

// M4-021-FOLLOWUP-001: the interim Linux trusted-server store (C-015 `SecureStorageBackend`,
// C-009 trust state) and the client's trust policy over it.
//
// First-party design (plan b.15, decision 9):
// - One file, `${XDG_CONFIG_HOME:-~/.config}/mackvm/trusted-servers`, in a 0700 directory. The
//   file is 0600 and holds one `<host:port> <64 lowercase hex>` record per line, nothing else.
//   There is no private key, certificate or revoked state anywhere.
// - Every operation first checks the directory and the file with `lstat`. A symbolic link, a
//   mode wider than 0700 (directory) or 0600 (file), another owner than the effective user, or
//   an object of the wrong type fails the operation with `security(.secureStorageUnavailable)`.
//   The opened descriptors are checked again with `fstat` and must be the objects `lstat` saw.
// - A file that is not exactly a list of well-formed, normalized, distinct records is refused
//   as a whole (fail closed); nothing is repaired.
// - Writes go to a fresh 0600 file in the same directory, created with `O_CREAT|O_EXCL`, which
//   is synced and then renamed over the record file. A reader sees the old or the new file,
//   never a partial one; a temporary file left by a crash is never read.
// - Operations on one directory are serialized across threads and processes by `flock` on the
//   directory itself: shared for reads, exclusive for read-modify-write.
// - Nothing here logs. Fingerprints leave this file only as the canonical displays of the
//   deliberate change warning (plan a.7).

// MARK: - Fingerprint text

/// The text forms of a SHA-256 certificate fingerprint used by the Linux client.
package enum LinuxFingerprintText {
  /// The length in bytes of a raw SHA-256 fingerprint.
  package static let sha256DigestLength = 32

  private static let lowercaseDigits = Array("0123456789abcdef".utf8)
  private static let uppercaseDigits: [Character] = Array("0123456789ABCDEF")

  /// The 64 lowercase hex digits of the record file, or `nil` unless `digest` is 32 bytes.
  package static func lowercaseHex(of digest: Data) -> String? {
    guard digest.count == sha256DigestLength else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(sha256DigestLength * 2)
    for byte in digest {
      bytes.append(lowercaseDigits[Int(byte >> 4)])
      bytes.append(lowercaseDigits[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Parses exactly 64 lowercase hex digits. Anything else, uppercase included, is `nil`.
  package static func digest(fromLowercaseHex text: some StringProtocol) -> Data? {
    digest(fromLowercaseHexBytes: Array(text.utf8))
  }

  static func digest(fromLowercaseHexBytes bytes: [UInt8]) -> Data? {
    guard bytes.count == sha256DigestLength * 2 else { return nil }
    var digest = Data(capacity: sha256DigestLength)
    var index = 0
    while index < bytes.count {
      guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
      digest.append(high << 4 | low)
      index += 2
    }
    return digest
  }

  /// `AA:BB:…`: 32 uppercase two-digit groups joined by colons, the rule of the Mac app's
  /// `CertificateFingerprint.canonicalDisplay`, or `nil` unless `digest` is 32 bytes.
  package static func canonicalDisplay(of digest: Data) -> String? {
    guard digest.count == sha256DigestLength else { return nil }
    return digest.map { byte in
      String([uppercaseDigits[Int(byte >> 4)], uppercaseDigits[Int(byte & 0x0F)]])
    }.joined(separator: ":")
  }

  private static func nibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    default: return nil
    }
  }
}

// MARK: - Record file format

/// The record file's format: one `<host:port> <64 lowercase hex>` line per trusted server.
package enum LinuxTrustedServerRecordFile {
  /// A larger file is refused before it is read in full.
  package static let maximumByteCount = 1 << 20

  /// The records of `bytes`, or `nil` when the file is not exactly a list of records.
  ///
  /// An empty file has no records. Otherwise every line ends with `\n` and is a normalized
  /// `PeerKey` (its own `rawValue`), one space, and 64 lowercase hex digits. A blank line, a
  /// comment, a missing final newline, a second record for one key, or any other byte makes
  /// the whole file invalid.
  package static func parse(_ bytes: [UInt8]) -> [PeerKey: Data]? {
    guard bytes.count <= maximumByteCount else { return nil }
    guard !bytes.isEmpty else { return [:] }
    guard bytes.last == UInt8(ascii: "\n") else { return nil }
    var records: [PeerKey: Data] = [:]
    for line in bytes.dropLast().split(
      separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
    {
      let fields = line.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
      guard fields.count == 2 else { return nil }
      let keyText = String(decoding: fields[0], as: UTF8.self)
      guard let key = PeerKey(rawValue: keyText), key.rawValue == keyText,
        Array(key.rawValue.utf8) == Array(fields[0]),
        let digest = LinuxFingerprintText.digest(fromLowercaseHexBytes: Array(fields[1])),
        records[key] == nil
      else { return nil }
      records[key] = digest
    }
    return records
  }

  /// The file content for `records`, one line per record in key order. Records whose value is
  /// not a 32-byte digest are never written: the store refuses them before this point.
  package static func serialize(_ records: [PeerKey: Data]) -> [UInt8] {
    var bytes: [UInt8] = []
    for key in records.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      guard let value = records[key], let hex = LinuxFingerprintText.lowercaseHex(of: value)
      else { continue }
      bytes += Array(key.rawValue.utf8)
      bytes.append(UInt8(ascii: " "))
      bytes += Array(hex.utf8)
      bytes.append(UInt8(ascii: "\n"))
    }
    return bytes
  }
}

// MARK: - Environment

/// Which object of the store a status describes.
package enum LinuxTrustedStoreObject: Equatable, Sendable {
  /// The `mackvm` directory.
  case directory
  /// The `trusted-servers` file.
  case recordFile
}

/// What the store reads from the process: its environment variables, its effective user, and
/// a hook over every `lstat`/`fstat` result, which tests use to simulate another owner.
package struct LinuxTrustedServerStoreEnvironment: Sendable {
  package var variables: [String: String]
  package var effectiveUserID: @Sendable () -> uid_t
  package var adjustStatus: @Sendable (LinuxTrustedStoreObject, inout stat) -> Void

  package init(
    variables: [String: String],
    effectiveUserID: @escaping @Sendable () -> uid_t = { geteuid() },
    adjustStatus: @escaping @Sendable (LinuxTrustedStoreObject, inout stat) -> Void = { _, _ in }
  ) {
    self.variables = variables
    self.effectiveUserID = effectiveUserID
    self.adjustStatus = adjustStatus
  }

  /// The running process: `ProcessInfo` environment, `geteuid()`, statuses unchanged.
  package static var live: Self {
    Self(variables: ProcessInfo.processInfo.environment)
  }
}

// MARK: - Store

/// The Linux client's trusted-server store: a 0600 record file in a 0700 directory.
///
/// It conforms to `SecureStorageBackend` with the rules that contract documents; see the file
/// header for the file rules. It is an immutable value: two instances over one directory
/// share nothing but the file system, and `flock` serializes them.
package struct LinuxTrustedServerStore: SecureStorageBackend {
  /// The store's directory below the configuration directory.
  package static let directoryName = "mackvm"
  /// The record file's name inside the store's directory.
  package static let fileName = "trusted-servers"

  private static let directoryForbiddenBits: mode_t = 0o7077
  private static let fileForbiddenBits: mode_t = 0o7177

  /// The store's directory, or `nil` when neither `configDirectory`, an absolute
  /// `XDG_CONFIG_HOME`, nor an absolute `HOME` names one; every operation then fails with
  /// `security(.secureStorageUnavailable)`.
  package let directoryPath: String?
  private let configurationPath: String?
  private let environment: LinuxTrustedServerStoreEnvironment

  /// `configDirectory` replaces `$XDG_CONFIG_HOME` (default `~/.config`); the store keeps
  /// `mackvm/trusted-servers` below it. A relative `XDG_CONFIG_HOME` is ignored, as the XDG
  /// base directory specification requires.
  package init(
    configDirectory: URL? = nil,
    environment: LinuxTrustedServerStoreEnvironment = .live
  ) {
    let base: String?
    if let configDirectory {
      base = configDirectory.path
    } else if let xdg = environment.variables["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
      base = xdg
    } else if let home = environment.variables["HOME"], home.hasPrefix("/") {
      base = home + "/.config"
    } else {
      base = nil
    }
    self.configurationPath = base
    self.directoryPath = base.map { $0 + "/" + Self.directoryName }
    self.environment = environment
  }

  /// The record file's path, or `nil` as for `directoryPath`.
  package var filePath: String? {
    directoryPath.map { $0 + "/" + Self.fileName }
  }

  package func loadTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Data?> {
    guard !Task.isCancelled else { return .failure(Self.cancelled) }
    return await offload {
      self.withDirectory(create: false, exclusive: false) { directory in
        self.readRecords(in: directory).map { $0[peer] }
      } ?? .success(nil)
    }
  }

  package func insertTrustedFingerprintIfAbsent(
    _ fingerprint: Data,
    for peer: PeerKey
  ) async -> CoreResult<TrustInsertOutcome> {
    guard fingerprint.count == LinuxFingerprintText.sha256DigestLength else {
      return .failure(Self.failure(.security(.trustRejected), retry: .userActionRequired))
    }
    guard !Task.isCancelled else { return .failure(Self.cancelled) }
    let value = Data(fingerprint)
    return await offload {
      self.withDirectory(create: true, exclusive: true) { directory in
        switch self.readRecords(in: directory) {
        case .failure(let error):
          return .failure(error)
        case .success(var records):
          if let stored = records[peer] {
            return .success(.existing(storedFingerprint: stored))
          }
          records[peer] = value
          return self.replaceRecords(records, in: directory).map { .inserted }
        }
      } ?? .failure(Self.unavailable)
    }
  }

  package func removeTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Void> {
    await offload {
      self.withDirectory(create: false, exclusive: true) { directory in
        switch self.readRecords(in: directory) {
        case .failure(let error):
          return .failure(error)
        case .success(var records):
          guard records.removeValue(forKey: peer) != nil else { return .success(()) }
          return self.replaceRecords(records, in: directory)
        }
      } ?? .success(())
    }
  }

  // MARK: Errors

  private static let cancelled = CoreError(
    code: .cancellation(.requested),
    severity: .info,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )

  private static let unavailable = failure(
    .security(.secureStorageUnavailable),
    retry: .userActionRequired
  )

  private static func failure(_ code: CoreErrorCode, retry: RetryDisposition) -> CoreError {
    CoreError(
      code: code, severity: .error, retryDisposition: retry, cleanupDisposition: .notRequired)
  }

  // MARK: File system

  /// Runs blocking file work off the caller's executor.
  private func offload<T: Sendable>(
    _ work: @escaping @Sendable () -> CoreResult<T>
  ) async -> CoreResult<T> {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: work())
      }
    }
  }

  /// Opens, checks and locks the store's directory and runs `body` with its descriptor.
  /// Returns `nil` only when the directory does not exist and `create` is false.
  private func withDirectory<T>(
    create: Bool,
    exclusive: Bool,
    _ body: (Int32) -> CoreResult<T>
  ) -> CoreResult<T>? {
    guard let configurationPath, let directoryPath else { return .failure(Self.unavailable) }
    var seen = stat()
    if lstat(directoryPath, &seen) != 0 {
      guard errno == ENOENT else { return .failure(Self.unavailable) }
      guard create else { return nil }
      guard makeDirectory(configurationPath), makeDirectory(directoryPath),
        lstat(directoryPath, &seen) == 0
      else { return .failure(Self.unavailable) }
    }
    guard isParentProtected(configurationPath) else { return .failure(Self.unavailable) }
    seen = adjusted(seen, as: .directory)
    guard isProtected(seen, as: .directory) else { return .failure(Self.unavailable) }

    let descriptor = open(directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return .failure(Self.unavailable) }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else { return .failure(Self.unavailable) }
    opened = adjusted(opened, as: .directory)
    guard isProtected(opened, as: .directory), Self.isSameObject(seen, opened),
      lock(descriptor, exclusive: exclusive)
    else { return .failure(Self.unavailable) }
    return body(descriptor)
  }

  /// Creates one 0700 directory level; an existing one is left for the checks that follow.
  /// Intermediate directories are never created: a missing parent of the configuration
  /// directory fails closed.
  private func makeDirectory(_ path: String) -> Bool {
    mkdir(path, 0o700) == 0 || errno == EEXIST
  }

  /// The configuration directory (followed if it is a link, as `~/.config` often is) must be a
  /// directory that group and other cannot write, unless it is sticky: otherwise another user
  /// could rename `mackvm` away and put their own in its place. Its own parents are not
  /// checked.
  private func isParentProtected(_ path: String) -> Bool {
    var status = stat()
    guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return false }
    return status.st_mode & 0o022 == 0 || status.st_mode & S_ISVTX != 0
  }

  /// `status` after the environment's test hook.
  private func adjusted(_ status: stat, as object: LinuxTrustedStoreObject) -> stat {
    var status = status
    environment.adjustStatus(object, &status)
    return status
  }

  private func lock(_ descriptor: Int32, exclusive: Bool) -> Bool {
    while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
      guard errno == EINTR else { return false }
    }
    return true
  }

  private func isProtected(_ status: stat, as object: LinuxTrustedStoreObject) -> Bool {
    let type: mode_t
    let forbidden: mode_t
    switch object {
    case .directory:
      type = S_IFDIR
      forbidden = Self.directoryForbiddenBits
    case .recordFile:
      type = S_IFREG
      forbidden = Self.fileForbiddenBits
    }
    return status.st_mode & S_IFMT == type && status.st_mode & forbidden == 0
      && status.st_uid == environment.effectiveUserID()
  }

  private static func isSameObject(_ first: stat, _ second: stat) -> Bool {
    first.st_dev == second.st_dev && first.st_ino == second.st_ino
  }

  /// The records in `directory`; no file means no records.
  private func readRecords(in directory: Int32) -> CoreResult<[PeerKey: Data]> {
    var seen = stat()
    if fstatat(directory, Self.fileName, &seen, AT_SYMLINK_NOFOLLOW) != 0 {
      return errno == ENOENT ? .success([:]) : .failure(Self.unavailable)
    }
    seen = adjusted(seen, as: .recordFile)
    guard isProtected(seen, as: .recordFile) else { return .failure(Self.unavailable) }
    let descriptor = openat(
      directory, Self.fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return .failure(Self.unavailable) }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else { return .failure(Self.unavailable) }
    opened = adjusted(opened, as: .recordFile)
    guard isProtected(opened, as: .recordFile), Self.isSameObject(seen, opened),
      let bytes = readAll(descriptor),
      let records = LinuxTrustedServerRecordFile.parse(bytes)
    else { return .failure(Self.unavailable) }
    return .success(records)
  }

  /// Up to the format's maximum; `nil` on an error or a larger file.
  private func readAll(_ descriptor: Int32) -> [UInt8]? {
    let limit = LinuxTrustedServerRecordFile.maximumByteCount
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        guard errno == EINTR else { return nil }
        continue
      }
      if count == 0 { return bytes }
      bytes += chunk[0..<count]
      guard bytes.count <= limit else { return nil }
    }
  }

  /// Writes `records` to a new 0600 file in `directory` and renames it over the record file.
  private func replaceRecords(_ records: [PeerKey: Data], in directory: Int32) -> CoreResult<Void> {
    removeStaleTemporaryFiles(in: directory)
    let temporary = ".\(Self.fileName).\(String(UInt64.random(in: .min ... .max), radix: 16)).tmp"
    let descriptor = openat(
      directory,
      temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else { return .failure(Self.unavailable) }
    let written =
      fchmod(descriptor, 0o600) == 0
      && writeAll(LinuxTrustedServerRecordFile.serialize(records), to: descriptor)
      && fsync(descriptor) == 0
    let closed = close(descriptor) == 0
    guard written, closed, renameat(directory, temporary, directory, Self.fileName) == 0 else {
      unlinkat(directory, temporary, 0)
      return .failure(Self.unavailable)
    }
    // The rename is durable once the directory is synced; a failure here leaves the new file
    // in place, so it is not reported as a failed write.
    _ = fsync(directory)
    return .success(())
  }

  /// Removes temporary files a crashed writer left behind. Every writer holds the exclusive
  /// lock while its temporary file exists, so under that lock any such file is stale.
  private func removeStaleTemporaryFiles(in directory: Int32) {
    guard let directoryPath,
      let names = try? FileManager.default.contentsOfDirectory(atPath: directoryPath)
    else { return }
    for name in names where Self.isTemporaryName(name) {
      unlinkat(directory, name, 0)
    }
  }

  static func isTemporaryName(_ name: String) -> Bool {
    name.hasPrefix("." + fileName + ".") && name.hasSuffix(".tmp")
  }

  private func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if count < 0 {
        guard errno == EINTR else { return false }
        continue
      }
      offset += count
    }
    return true
  }
}

// MARK: - Trust policy

/// What the owner is shown when a trusted server presents a different fingerprint: the one
/// deliberate presentation of both fingerprints (plan a.7).
///
/// Only `trustedFingerprintDisplay` and `presentedFingerprintDisplay` are readable, as
/// canonical `AA:BB:…` text. `description`, `debugDescription`, interpolation, `dump` and
/// reflection are redacted. The raw digests are not kept.
package struct LinuxFingerprintChangeWarning: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  /// The trusted fingerprint, as canonical display text.
  package let trustedFingerprintDisplay: String
  /// The presented fingerprint, as canonical display text.
  package let presentedFingerprintDisplay: String

  /// `nil` unless both are 32-byte digests and they differ.
  init?(trustedFingerprint: Data, presentedFingerprint: Data) {
    guard trustedFingerprint != presentedFingerprint,
      let trusted = LinuxFingerprintText.canonicalDisplay(of: trustedFingerprint),
      let presented = LinuxFingerprintText.canonicalDisplay(of: presentedFingerprint)
    else { return nil }
    trustedFingerprintDisplay = trusted
    presentedFingerprintDisplay = presented
  }

  package var description: String { "LinuxFingerprintChangeWarning(redacted)" }
  package var debugDescription: String { description }
  package var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

/// The client's C-009 decision for one presented fingerprint. Only `.allow` lets a connection
/// proceed; `.prompt` is not an acceptance.
package enum LinuxTrustDecision: Equatable, Sendable {
  /// No record: ask the owner (interactive) or print instructions (systemd).
  case prompt
  /// The presented fingerprint equals the trusted one.
  case allow
  /// The connection must not proceed, for the given reason.
  case reject(SecurityErrorCode)
  /// A different fingerprint than the trusted one: rejected, never stored, never replaced.
  case identityChanged(LinuxFingerprintChangeWarning)
}

/// C-009 for the Linux client, a first-party copy of the Mac app's internal `TrustPolicy`.
///
/// Precedence: a presented fingerprint that is not 32 bytes rejects with `.trustRejected`; no
/// record prompts; a stored value that is not 32 bytes rejects with `.trustRejected`; equal
/// bytes allow; otherwise `.identityChanged` with the warning. V1 has no revoked state.
package enum LinuxTrustPolicy {
  package static func decide(stored: Data?, presented: Data) -> LinuxTrustDecision {
    guard presented.count == LinuxFingerprintText.sha256DigestLength else {
      return .reject(.trustRejected)
    }
    guard let stored else { return .prompt }
    guard stored.count == LinuxFingerprintText.sha256DigestLength else {
      return .reject(.trustRejected)
    }
    if stored == presented { return .allow }
    guard
      let warning = LinuxFingerprintChangeWarning(
        trustedFingerprint: stored,
        presentedFingerprint: presented
      )
    else { return .reject(.identityChanged) }
    return .identityChanged(warning)
  }
}

// MARK: - First use

/// The owner's explicit answer to a first-use prompt. Only a person supplies it.
package enum LinuxFirstUseOwnerDecision: Equatable, Sendable {
  /// Trust the presented fingerprint for this server.
  case trust
  /// Refuse it. Nothing is stored.
  case reject
}

/// Evaluates a presented fingerprint against the store and applies the owner's decision.
package struct LinuxFirstUseTrust: Sendable {
  private let store: any SecureStorageBackend

  package init(store: any SecureStorageBackend) {
    self.store = store
  }

  /// Reads the record and decides. Never writes. A storage failure is a failure, never a prompt.
  package func evaluate(
    peer: PeerKey,
    presentedFingerprint: Data
  ) async -> CoreResult<LinuxTrustDecision> {
    guard presentedFingerprint.count == LinuxFingerprintText.sha256DigestLength else {
      return .success(.reject(.trustRejected))
    }
    return await store.loadTrustedFingerprint(for: peer).map {
      LinuxTrustPolicy.decide(stored: $0, presented: presentedFingerprint)
    }
  }

  /// `.reject` answers `.reject(.trustRejected)` and never writes. `.trust` inserts the
  /// fingerprint if no record exists, never replacing one, then reads the record again and
  /// decides from that read: `.allow` only when the record now holds the presented value.
  package func apply(
    ownerDecision: LinuxFirstUseOwnerDecision,
    peer: PeerKey,
    presentedFingerprint: Data
  ) async -> CoreResult<LinuxTrustDecision> {
    guard presentedFingerprint.count == LinuxFingerprintText.sha256DigestLength else {
      return .success(.reject(.trustRejected))
    }
    switch ownerDecision {
    case .reject:
      return .success(.reject(.trustRejected))
    case .trust:
      if case .failure(let error) = await store.insertTrustedFingerprintIfAbsent(
        presentedFingerprint,
        for: peer
      ) {
        return .failure(error)
      }
      return await evaluate(peer: peer, presentedFingerprint: presentedFingerprint)
    }
  }
}

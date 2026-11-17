import Foundation
import Glibc
import KVMContracts
import LinuxPlatform
import Testing

// M4-021-FOLLOWUP-001: the Linux trusted-server store, trust policy and first-use trust.
// Every test uses its own temporary XDG_CONFIG_HOME, passed through the store's environment.

private let server = PeerKey(host: "mac.local", port: 24800)!
private let otherServer = PeerKey(host: "10.0.0.2", port: 24800)!

private func fingerprint(_ byte: UInt8, count: Int = 32) -> Data {
  Data(repeating: byte, count: count)
}

private func failureCode<T>(_ result: CoreResult<T>) -> CoreErrorCode? {
  if case .failure(let error) = result { return error.code }
  return nil
}

private let unavailable = CoreErrorCode.security(.secureStorageUnavailable)

/// A temporary configuration home, removed when the test ends.
private final class TemporaryConfig {
  let base: String

  init() {
    let name = "mackvm-trust-\(UUID().uuidString)"
    base = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
    precondition(mkdir(base, 0o700) == 0)
  }

  deinit {
    try? FileManager.default.removeItem(atPath: base)
  }

  var directory: String { base + "/mackvm" }
  var file: String { directory + "/trusted-servers" }

  func store(
    adjustStatus: @escaping @Sendable (LinuxTrustedStoreObject, inout stat) -> Void = { _, _ in }
  ) -> LinuxTrustedServerStore {
    LinuxTrustedServerStore(
      environment: LinuxTrustedServerStoreEnvironment(
        variables: ["XDG_CONFIG_HOME": base, "HOME": "/nonexistent-home"],
        adjustStatus: adjustStatus
      )
    )
  }

  /// Creates the directory (0700) and the record file (0600) with `content`.
  func write(_ content: String) {
    _ = mkdir(directory, 0o700)
    precondition(FileManager.default.createFile(atPath: file, contents: Data(content.utf8)))
    precondition(chmod(file, 0o600) == 0)
  }

  func content() -> String? {
    FileManager.default.contents(atPath: file).map { String(decoding: $0, as: UTF8.self) }
  }

  func entries() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted() ?? []
  }

  func exists(_ path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0
  }
}

/// A status hook that changes the inode of the second status seen for `object`: the object
/// opened is then not the one checked.
private func secondStatusChanged(
  for object: LinuxTrustedStoreObject
) -> @Sendable (LinuxTrustedStoreObject, inout stat) -> Void {
  let calls = StatusCallCounter()
  return { seen, status in
    if seen == object, calls.next() == 2 { status.st_ino &+= 1 }
  }
}

private final class StatusCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}

private func permissions(_ path: String) -> mode_t {
  var status = stat()
  precondition(lstat(path, &status) == 0)
  return status.st_mode & 0o7777
}

private func inode(_ path: String) -> ino_t {
  var status = stat()
  precondition(lstat(path, &status) == 0)
  return status.st_ino
}

private let hex5A = String(repeating: "5a", count: 32)
private let hexA5 = String(repeating: "a5", count: 32)

/// Runs all three operations and expects each to fail with `code`.
private func expectEveryOperationFails(
  _ store: LinuxTrustedServerStore,
  with code: CoreErrorCode,
  sourceLocation: SourceLocation = #_sourceLocation
) async {
  let load = await store.loadTrustedFingerprint(for: server)
  let insert = await store.insertTrustedFingerprintIfAbsent(fingerprint(0x11), for: otherServer)
  let remove = await store.removeTrustedFingerprint(for: server)
  #expect(failureCode(load) == code, sourceLocation: sourceLocation)
  #expect(failureCode(insert) == code, sourceLocation: sourceLocation)
  #expect(failureCode(remove) == code, sourceLocation: sourceLocation)
}

@Suite("M4-021-FOLLOWUP-001 trusted-server store: records")
struct LinuxTrustedServerStoreRecordTests {
  @Test("insert, load and remove round-trip through a 0600 file in a 0700 directory")
  func roundTrip() async throws {
    let config = TemporaryConfig()
    let store = config.store()
    #expect(store.filePath == config.file)

    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    let outcome = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server)
      .get()
    #expect(outcome == .inserted)
    #expect(permissions(config.directory) == 0o700)
    #expect(permissions(config.file) == 0o600)
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")

    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA5), for: otherServer).get()
    #expect(config.content() == "10.0.0.2:24800 \(hexA5)\nmac.local:24800 \(hex5A)\n")
    #expect(permissions(config.file) == 0o600)

    #expect(try await store.loadTrustedFingerprint(for: server).get() == fingerprint(0x5A))
    #expect(try await store.loadTrustedFingerprint(for: otherServer).get() == fingerprint(0xA5))

    try await store.removeTrustedFingerprint(for: server).get()
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    #expect(try await store.loadTrustedFingerprint(for: otherServer).get() == fingerprint(0xA5))
    #expect(config.content() == "10.0.0.2:24800 \(hexA5)\n")

    try await store.removeTrustedFingerprint(for: server).get()
    #expect(config.content() == "10.0.0.2:24800 \(hexA5)\n")
  }

  @Test("a second instance over the same directory reads what the first stored")
  func secondInstance() async throws {
    let config = TemporaryConfig()
    _ = try await config.store().insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server)
      .get()
    #expect(try await config.store().loadTrustedFingerprint(for: server).get() == fingerprint(0x5A))
  }

  @Test("a duplicate insert returns the existing record and changes nothing")
  func duplicateInsert() async throws {
    let config = TemporaryConfig()
    let store = config.store()
    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server).get()
    let before = inode(config.file)

    let same = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server)
      .get()
    let different = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA5), for: server)
      .get()
    #expect(same == .existing(storedFingerprint: fingerprint(0x5A)))
    #expect(different == .existing(storedFingerprint: fingerprint(0x5A)))
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
    #expect(inode(config.file) == before)
  }

  @Test("load and remove without a directory create nothing")
  func nothingStored() async throws {
    let config = TemporaryConfig()
    let store = config.store()
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    try await store.removeTrustedFingerprint(for: server).get()
    #expect(!config.exists(config.directory))
  }

  @Test("an existing empty file holds no records")
  func emptyFile() async throws {
    let config = TemporaryConfig()
    config.write("")
    let store = config.store()
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    #expect(
      try await store.insertTrustedFingerprintIfAbsent(fingerprint(1), for: server).get()
        == .inserted)
  }

  @Test("a fingerprint that is not 32 bytes is refused before any storage work")
  func wrongLengthInsert() async {
    let config = TemporaryConfig()
    let store = config.store()
    for count in [0, 31, 33, 64] {
      let outcome = await store.insertTrustedFingerprintIfAbsent(
        fingerprint(0x5A, count: count),
        for: server
      )
      #expect(failureCode(outcome) == .security(.trustRejected))
    }
    #expect(!config.exists(config.directory))
  }

  @Test("load and insert from a cancelled task do nothing; remove still runs")
  func cancellation() async throws {
    let config = TemporaryConfig()
    let store = config.store()
    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server).get()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let load = await store.loadTrustedFingerprint(for: server)
      let insert = await store.insertTrustedFingerprintIfAbsent(fingerprint(1), for: otherServer)
      let short = await store.insertTrustedFingerprintIfAbsent(
        fingerprint(1, count: 31), for: otherServer)
      let remove = await store.removeTrustedFingerprint(for: server)
      return (failureCode(load), failureCode(insert), failureCode(short), failureCode(remove))
    }
    let (load, insert, short, remove) = await task.value
    #expect(load == .cancellation(.requested))
    #expect(insert == .cancellation(.requested))
    #expect(short == .security(.trustRejected))
    #expect(remove == nil)
    #expect(config.content() == "")
  }

  @Test("the directory comes from configDirectory, an absolute XDG_CONFIG_HOME, or HOME")
  func directoryResolution() async {
    let explicit = LinuxTrustedServerStore(
      configDirectory: URL(fileURLWithPath: "/explicit"),
      environment: LinuxTrustedServerStoreEnvironment(variables: ["XDG_CONFIG_HOME": "/xdg"])
    )
    #expect(explicit.filePath == "/explicit/mackvm/trusted-servers")

    let xdg = LinuxTrustedServerStore(
      environment: LinuxTrustedServerStoreEnvironment(
        variables: ["XDG_CONFIG_HOME": "/xdg", "HOME": "/home/user"]
      )
    )
    #expect(xdg.filePath == "/xdg/mackvm/trusted-servers")

    for relative in ["", "relative/config"] {
      let home = LinuxTrustedServerStore(
        environment: LinuxTrustedServerStoreEnvironment(
          variables: ["XDG_CONFIG_HOME": relative, "HOME": "/home/user"]
        )
      )
      #expect(home.filePath == "/home/user/.config/mackvm/trusted-servers")
    }

    let none = LinuxTrustedServerStore(
      environment: LinuxTrustedServerStoreEnvironment(variables: ["HOME": "relative"])
    )
    #expect(none.filePath == nil)
    await expectEveryOperationFails(none, with: unavailable)
  }
}

@Suite("M4-021-FOLLOWUP-001 trusted-server store: refusals")
struct LinuxTrustedServerStoreRefusalTests {
  @Test(
    "a record file with a mode wider than 0600 is refused",
    arguments: [0o644, 0o640, 0o604, 0o700, 0o4600, 0o620])
  func wideFile(mode: Int) async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    #expect(chmod(config.file, mode_t(mode)) == 0)
    await expectEveryOperationFails(config.store(), with: unavailable)
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
  }

  @Test("a narrower record file mode is accepted", arguments: [0o600, 0o400, 0o200])
  func narrowFile(mode: Int) async throws {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    #expect(chmod(config.file, mode_t(mode)) == 0)
    // Root ignores the missing read bit, so only the mode checks matter here.
    let loaded = await config.store().loadTrustedFingerprint(for: server)
    if geteuid() == 0 {
      #expect(try loaded.get() == fingerprint(0x5A))
    }
  }

  @Test(
    "a directory with a mode wider than 0700 is refused",
    arguments: [0o750, 0o705, 0o755, 0o770, 0o1700])
  func wideDirectory(mode: Int) async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    #expect(chmod(config.directory, mode_t(mode)) == 0)
    await expectEveryOperationFails(config.store(), with: unavailable)
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
  }

  @Test("a symbolic link in place of the record file is refused")
  func symlinkFile() async {
    let config = TemporaryConfig()
    config.write("")
    let elsewhere = config.base + "/elsewhere"
    #expect(
      FileManager.default.createFile(
        atPath: elsewhere, contents: Data("mac.local:24800 \(hex5A)\n".utf8)))
    #expect(chmod(elsewhere, 0o600) == 0)
    #expect(unlink(config.file) == 0)
    #expect(symlink(elsewhere, config.file) == 0)
    await expectEveryOperationFails(config.store(), with: unavailable)
    #expect(
      FileManager.default.contents(atPath: elsewhere) == Data("mac.local:24800 \(hex5A)\n".utf8))
  }

  @Test("a symbolic link in place of the directory is refused")
  func symlinkDirectory() async {
    let config = TemporaryConfig()
    let real = config.base + "/real"
    #expect(mkdir(real, 0o700) == 0)
    let file = real + "/trusted-servers"
    #expect(
      FileManager.default.createFile(
        atPath: file, contents: Data("mac.local:24800 \(hex5A)\n".utf8)))
    #expect(chmod(file, 0o600) == 0)
    #expect(symlink(real, config.directory) == 0)
    await expectEveryOperationFails(config.store(), with: unavailable)
    #expect(FileManager.default.contents(atPath: file) == Data("mac.local:24800 \(hex5A)\n".utf8))
  }

  @Test("a directory or record file in the wrong type is refused")
  func wrongTypes() async {
    let config = TemporaryConfig()
    #expect(mkdir(config.directory, 0o700) == 0)
    #expect(mkdir(config.file, 0o700) == 0)
    await expectEveryOperationFails(config.store(), with: unavailable)

    let other = TemporaryConfig()
    #expect(FileManager.default.createFile(atPath: other.directory, contents: Data()))
    #expect(chmod(other.directory, 0o600) == 0)
    await expectEveryOperationFails(other.store(), with: unavailable)
  }

  @Test("a record file owned by another user is refused (injected stat)")
  func foreignFileOwner() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let store = config.store { object, status in
      if object == .recordFile { status.st_uid = geteuid() &+ 1 }
    }
    await expectEveryOperationFails(store, with: unavailable)
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
  }

  @Test("a directory owned by another user is refused (injected stat)")
  func foreignDirectoryOwner() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let store = config.store { object, status in
      if object == .directory { status.st_uid = geteuid() &+ 1 }
    }
    await expectEveryOperationFails(store, with: unavailable)

    let empty = TemporaryConfig()
    let emptyStore = empty.store { object, status in
      if object == .directory { status.st_uid = geteuid() &+ 1 }
    }
    let insert = await emptyStore.insertTrustedFingerprintIfAbsent(fingerprint(1), for: server)
    #expect(failureCode(insert) == unavailable)
    #expect(!empty.exists(empty.file))
  }

  @Test("an injected wide mode is refused even when the file is 0600")
  func injectedWideMode() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let store = config.store { object, status in
      if object == .recordFile { status.st_mode |= 0o004 }
    }
    await expectEveryOperationFails(store, with: unavailable)
  }

  @Test("a record file replaced between lstat and open is refused (injected stat)")
  func fileSwappedAfterCheck() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let store = config.store(adjustStatus: secondStatusChanged(for: .recordFile))
    let load = await store.loadTrustedFingerprint(for: server)
    #expect(failureCode(load) == unavailable)
  }

  @Test("a directory replaced between lstat and open is refused (injected stat)")
  func directorySwappedAfterCheck() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let store = config.store(adjustStatus: secondStatusChanged(for: .directory))
    let load = await store.loadTrustedFingerprint(for: server)
    #expect(failureCode(load) == unavailable)
  }

  @Test("a configuration directory writable by group or other is refused unless sticky")
  func writableParent() async throws {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    for mode in [0o777, 0o770, 0o722] {
      #expect(chmod(config.base, mode_t(mode)) == 0)
      await expectEveryOperationFails(config.store(), with: unavailable)
    }
    #expect(chmod(config.base, 0o1777) == 0)
    #expect(try await config.store().loadTrustedFingerprint(for: server).get() == fingerprint(0x5A))
    #expect(chmod(config.base, 0o755) == 0)
    #expect(try await config.store().loadTrustedFingerprint(for: server).get() == fingerprint(0x5A))
    #expect(chmod(config.base, 0o700) == 0)
  }

  @Test("a missing parent of the configuration directory fails closed and creates nothing")
  func missingParent() async {
    let config = TemporaryConfig()
    let store = LinuxTrustedServerStore(
      environment: LinuxTrustedServerStoreEnvironment(
        variables: ["XDG_CONFIG_HOME": config.base + "/missing/config"]))
    let insert = await store.insertTrustedFingerprintIfAbsent(fingerprint(1), for: server)
    #expect(failureCode(insert) == unavailable)
    #expect(!config.exists(config.base + "/missing"))
  }

  @Test("a malformed line rejects the whole file and nothing is rewritten")
  func malformedLine() async {
    let lines = [
      "mac.local:24800 \(hex5A)\nnot a record\n",
      "# comment\nmac.local:24800 \(hex5A)\n",
      "mac.local:24800 \(hex5A)\n\n",
      "mac.local:24800 \(hex5A)",
      "MAC.local:24800 \(hex5A)\n",
      "mac.local:24800 \(hex5A.uppercased())\n",
      "mac.local:24800  \(hex5A)\n",
      "mac.local:24800 \(hex5A)\r\n",
      "mac.local:24800 \(hex5A)\nmac.local:24800 \(hexA5)\n",
    ]
    for content in lines {
      let config = TemporaryConfig()
      config.write(content)
      await expectEveryOperationFails(config.store(), with: unavailable)
      #expect(config.content() == content)
    }
  }
}

@Suite("M4-021-FOLLOWUP-001 trusted-server store: record format")
struct LinuxTrustedServerRecordFileTests {
  private func parse(_ text: String) -> [PeerKey: Data]? {
    LinuxTrustedServerRecordFile.parse(Array(text.utf8))
  }

  @Test("well-formed records parse and serialize back byte for byte")
  func wellFormed() {
    let text = "10.0.0.2:24800 \(hexA5)\n[::1]:1 \(hex5A)\nmac.local:24800 \(hex5A)\n"
    let records = parse(text)
    #expect(records?.count == 3)
    #expect(records?[server] == fingerprint(0x5A))
    #expect(records.map { LinuxTrustedServerRecordFile.serialize($0) } == Array(text.utf8))
    #expect(parse("") == [:])
  }

  @Test("anything that is not exactly a list of records is refused")
  func refused() {
    let refused = [
      "\n",
      "mac.local:24800 \(hex5A)",
      "mac.local:24800 \(hex5A)\n\n",
      "mac.local:24800 \(hex5A) extra\n",
      "mac.local:24800\t\(hex5A)\n",
      "mac.local:24800 \(hex5A.dropLast())\n",
      "mac.local:24800 \(hex5A)5a\n",
      "mac.local:24800 \(String(repeating: "g", count: 64))\n",
      "Mac.local:24800 \(hex5A)\n",
      "mac.local:024800 \(hex5A)\n",
      "mac.local:0 \(hex5A)\n",
      "mac.local \(hex5A)\n",
      ":24800 \(hex5A)\n",
      "mac.local:24800 \(hex5A)\nmac.local:24800 \(hex5A)\n",
    ]
    for text in refused {
      #expect(parse(text) == nil, "\(text.debugDescription) parsed")
    }
  }

  @Test("a file over the size limit is refused")
  func oversized() {
    let line = Array("mac.local:24800 \(hex5A)\n".utf8)
    var bytes: [UInt8] = []
    while bytes.count <= LinuxTrustedServerRecordFile.maximumByteCount { bytes += line }
    #expect(LinuxTrustedServerRecordFile.parse(bytes) == nil)
  }

  @Test("fingerprint text: lowercase hex both ways, canonical display, 32 bytes only")
  func fingerprintText() {
    let digest = Data((0..<32).map { UInt8($0 * 8) })
    let hex = LinuxFingerprintText.lowercaseHex(of: digest)
    #expect(hex == "0008101820283038404850586068707880889098a0a8b0b8c0c8d0d8e0e8f0f8")
    #expect(hex.flatMap { LinuxFingerprintText.digest(fromLowercaseHex: $0) } == digest)
    #expect(
      LinuxFingerprintText.canonicalDisplay(of: fingerprint(0xAB))
        == Array(repeating: "AB", count: 32).joined(separator: ":"))
    #expect(LinuxFingerprintText.lowercaseHex(of: fingerprint(1, count: 31)) == nil)
    #expect(LinuxFingerprintText.canonicalDisplay(of: fingerprint(1, count: 33)) == nil)
    #expect(LinuxFingerprintText.digest(fromLowercaseHex: hex5A.uppercased()) == nil)
  }
}

private let helperBaseVariable = "MACKVM_TRUST_HELPER_BASE"
private let helperByteVariable = "MACKVM_TRUST_HELPER_BYTE"
private let helperGoVariable = "MACKVM_TRUST_HELPER_GO"

/// Starts this test binary again, running only the helper test, which inserts `byte` into the
/// store under `base` once `go` exists. Returns the child's pid, or -1.
private func spawnHelper(base: String, byte: UInt8, go: String) -> pid_t {
  let executable = "/proc/self/exe"
  let arguments = [
    executable, "--testing-library", "swift-testing", "--filter", "twoProcessHelper",
  ]
  var variables = ProcessInfo.processInfo.environment
  variables[helperBaseVariable] = base
  variables[helperByteVariable] = String(byte)
  variables[helperGoVariable] = go
  let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
  let envp: [UnsafeMutablePointer<CChar>?] =
    variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer {
    for pointer in argv + envp { free(pointer) }
  }
  var actions = posix_spawn_file_actions_t()
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
  var pid: pid_t = -1
  guard posix_spawn(&pid, executable, &actions, nil, argv, envp) == 0 else { return -1 }
  return pid
}

@Suite("M4-021-FOLLOWUP-001 trusted-server store: atomic replace and concurrency")
struct LinuxTrustedServerStoreAtomicTests {
  @Test("a write replaces the file by rename and leaves no temporary file")
  func renameReplace() async throws {
    let config = TemporaryConfig()
    let store = config.store()
    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server).get()
    let first = inode(config.file)
    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA5), for: otherServer).get()
    #expect(inode(config.file) != first)
    #expect(permissions(config.file) == 0o600)
    #expect(config.entries() == ["trusted-servers"])
    let second = inode(config.file)
    try await store.removeTrustedFingerprint(for: server).get()
    #expect(inode(config.file) != second)
    #expect(config.entries() == ["trusted-servers"])
  }

  @Test("a temporary file left behind by a crash is ignored")
  func leftoverTemporary() async throws {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let leftover = config.directory + "/.trusted-servers.0123456789abcdef.tmp"
    #expect(
      FileManager.default.createFile(atPath: leftover, contents: Data("garbage\n10.0.0.2".utf8)))
    let store = config.store()
    #expect(try await store.loadTrustedFingerprint(for: server).get() == fingerprint(0x5A))
    #expect(try await store.loadTrustedFingerprint(for: otherServer).get() == nil)
    _ = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA5), for: otherServer).get()
    #expect(config.content() == "10.0.0.2:24800 \(hexA5)\nmac.local:24800 \(hex5A)\n")
    #expect(config.entries() == ["trusted-servers"])
  }

  @Test("concurrent inserts from separate processes for one server keep exactly one record")
  func twoProcesses() throws {
    for _ in 0..<3 {
      let config = TemporaryConfig()
      let bytes: [UInt8] = [1, 2, 3, 4]
      let go = config.base + "/go"
      let children = bytes.map { spawnHelper(base: config.base, byte: $0, go: go) }
      #expect(children.allSatisfy { $0 > 0 })
      #expect(FileManager.default.createFile(atPath: go, contents: Data()))
      for child in children where child > 0 {
        var status: Int32 = 0
        _ = waitpid(child, &status, 0)
        #expect(status == 0, "helper process failed")
      }
      let results = bytes.map { byte in
        FileManager.default.contents(atPath: config.base + "/result-\(byte)")
          .map { String(decoding: $0, as: UTF8.self) } ?? "missing"
      }
      let winners = bytes.indices.filter { results[$0] == "inserted" }
      #expect(winners.count == 1, "\(results)")
      guard winners.count == 1 else { continue }
      let winnerHex = LinuxFingerprintText.lowercaseHex(of: fingerprint(bytes[winners[0]]))!
      for index in bytes.indices where index != winners[0] {
        #expect(results[index] == "existing " + winnerHex)
      }
      #expect(config.content() == "mac.local:24800 \(winnerHex)\n")
    }
  }

  @Test("helper for the two-process test: one insert, only when spawned by it")
  func twoProcessHelper() async {
    let environment = ProcessInfo.processInfo.environment
    guard let base = environment[helperBaseVariable], let go = environment[helperGoVariable],
      let text = environment[helperByteVariable], let byte = UInt8(text)
    else { return }
    let deadline = Date().addingTimeInterval(20)
    while !FileManager.default.fileExists(atPath: go), Date() < deadline {
      usleep(1000)
    }
    let store = LinuxTrustedServerStore(
      environment: LinuxTrustedServerStoreEnvironment(variables: ["XDG_CONFIG_HOME": base]))
    let result: String
    switch await store.insertTrustedFingerprintIfAbsent(fingerprint(byte), for: server) {
    case .success(.inserted): result = "inserted"
    case .success(.existing(let stored)):
      result = "existing " + (LinuxFingerprintText.lowercaseHex(of: stored) ?? "?")
    case .failure: result = "failure"
    }
    _ = FileManager.default.createFile(
      atPath: base + "/result-\(byte)", contents: Data(result.utf8))
  }

  @Test("concurrent inserts for one server from separate instances keep exactly one record")
  func concurrentSamePeer() async throws {
    for _ in 0..<5 {
      let config = TemporaryConfig()
      let outcomes = await withTaskGroup(of: (UInt8, TrustInsertOutcome?).self) { group in
        for byte in UInt8(1)...16 {
          let store = config.store()
          group.addTask {
            (
              byte,
              try? await store.insertTrustedFingerprintIfAbsent(fingerprint(byte), for: server)
                .get()
            )
          }
        }
        return await group.reduce(into: []) { $0.append($1) }
      }
      let winners = outcomes.filter { $0.1 == .inserted }.map(\.0)
      #expect(winners.count == 1)
      guard let winner = winners.first else { continue }
      for (_, outcome) in outcomes where outcome != .inserted {
        #expect(outcome == .existing(storedFingerprint: fingerprint(winner)))
      }
      #expect(
        config.content()
          == "mac.local:24800 \(LinuxFingerprintText.lowercaseHex(of: fingerprint(winner))!)\n")
    }
  }

  @Test("concurrent inserts for different servers lose no record")
  func concurrentDifferentPeers() async throws {
    for _ in 0..<5 {
      let config = TemporaryConfig()
      await withTaskGroup(of: Void.self) { group in
        for port in UInt16(1)...24 {
          let store = config.store()
          group.addTask {
            _ = await store.insertTrustedFingerprintIfAbsent(
              fingerprint(UInt8(port)),
              for: PeerKey(host: "host", port: port)!
            )
          }
        }
      }
      let records = LinuxTrustedServerRecordFile.parse(Array((config.content() ?? "").utf8))
      #expect(records?.count == 24)
      #expect(config.entries() == ["trusted-servers"])
    }
  }
}

@Suite("M4-021-FOLLOWUP-001 trust policy and first-use trust")
struct LinuxTrustPolicyTests {
  @Test("the policy table")
  func table() {
    let a = fingerprint(0x5A)
    let b = fingerprint(0xA5)
    #expect(LinuxTrustPolicy.decide(stored: nil, presented: a) == .prompt)
    #expect(LinuxTrustPolicy.decide(stored: a, presented: a) == .allow)
    #expect(
      LinuxTrustPolicy.decide(stored: nil, presented: fingerprint(1, count: 31))
        == .reject(.trustRejected))
    #expect(
      LinuxTrustPolicy.decide(stored: a, presented: fingerprint(0x5A, count: 31))
        == .reject(.trustRejected))
    #expect(
      LinuxTrustPolicy.decide(stored: nil, presented: fingerprint(1, count: 33))
        == .reject(.trustRejected))
    #expect(LinuxTrustPolicy.decide(stored: nil, presented: Data()) == .reject(.trustRejected))
    #expect(
      LinuxTrustPolicy.decide(stored: fingerprint(0x5A, count: 31), presented: a)
        == .reject(.trustRejected))
    let slice = Data([0] + Array(a)).dropFirst()
    #expect(LinuxTrustPolicy.decide(stored: a, presented: slice) == .allow)
    guard case .identityChanged(let warning) = LinuxTrustPolicy.decide(stored: a, presented: b)
    else {
      Issue.record("a different fingerprint is not identityChanged")
      return
    }
    #expect(warning.trustedFingerprintDisplay == LinuxFingerprintText.canonicalDisplay(of: a))
    #expect(warning.presentedFingerprintDisplay == LinuxFingerprintText.canonicalDisplay(of: b))
  }

  @Test("the change warning is redacted everywhere but its two display fields")
  func warningRedaction() {
    guard
      case .identityChanged(let warning) = LinuxTrustPolicy.decide(
        stored: fingerprint(0x5A), presented: fingerprint(0xA5))
    else {
      Issue.record("no warning")
      return
    }
    let decision = LinuxTrustDecision.identityChanged(warning)
    var dumped = ""
    dump(warning, to: &dumped)
    var dumpedDecision = ""
    dump(decision, to: &dumpedDecision)
    let renderings = [
      String(describing: warning), String(reflecting: warning), "\(warning)",
      warning.debugDescription,
      dumped, String(describing: decision), String(reflecting: decision), dumpedDecision,
    ]
    for text in renderings {
      for secret in ["5A", "5a", "A5", "a5"] {
        #expect(!text.contains(secret), "\(text) leaks a fingerprint")
      }
    }
    #expect(Mirror(reflecting: warning).children.isEmpty)
    let labels = Set(
      Mirror(reflecting: decision).children.flatMap { Mirror(reflecting: $0.value).children }
        .compactMap(\.label))
    #expect(labels.isEmpty)
  }

  @Test("first use: evaluate never writes; reject never writes; trust stores and allows")
  func firstUse() async throws {
    let config = TemporaryConfig()
    let trust = LinuxFirstUseTrust(store: config.store())
    #expect(
      try await trust.evaluate(peer: server, presentedFingerprint: fingerprint(0x5A)).get()
        == .prompt)
    #expect(!config.exists(config.directory))
    #expect(
      try await trust.apply(
        ownerDecision: .reject, peer: server, presentedFingerprint: fingerprint(0x5A)
      ).get() == .reject(.trustRejected))
    #expect(!config.exists(config.directory))
    #expect(
      try await trust.apply(
        ownerDecision: .trust, peer: server, presentedFingerprint: fingerprint(1, count: 31)
      ).get() == .reject(.trustRejected))
    #expect(!config.exists(config.directory))

    #expect(
      try await trust.apply(
        ownerDecision: .trust, peer: server, presentedFingerprint: fingerprint(0x5A)
      ).get() == .allow)
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
    #expect(
      try await trust.evaluate(peer: server, presentedFingerprint: fingerprint(0x5A)).get()
        == .allow)
  }

  @Test("first use: trust never replaces a different record and reports the change")
  func firstUseExisting() async throws {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    let trust = LinuxFirstUseTrust(store: config.store())
    let applied = try await trust.apply(
      ownerDecision: .trust, peer: server, presentedFingerprint: fingerprint(0xA5)
    ).get()
    guard case .identityChanged = applied else {
      Issue.record("trusting over a different record was \(applied)")
      return
    }
    #expect(config.content() == "mac.local:24800 \(hex5A)\n")
    let evaluated = try await trust.evaluate(peer: server, presentedFingerprint: fingerprint(0xA5))
      .get()
    guard case .identityChanged = evaluated else {
      Issue.record("a changed fingerprint evaluated as \(evaluated)")
      return
    }
  }

  @Test("first use: a storage failure is a failure, never a prompt")
  func firstUseStorageFailure() async {
    let config = TemporaryConfig()
    config.write("mac.local:24800 \(hex5A)\n")
    #expect(chmod(config.file, 0o644) == 0)
    let trust = LinuxFirstUseTrust(store: config.store())
    let evaluated = await trust.evaluate(peer: otherServer, presentedFingerprint: fingerprint(0xA5))
    let applied = await trust.apply(
      ownerDecision: .trust, peer: otherServer, presentedFingerprint: fingerprint(0xA5))
    #expect(failureCode(evaluated) == unavailable)
    #expect(failureCode(applied) == unavailable)
  }
}

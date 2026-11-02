// M4-002: C-015 platform backend contracts.
//
// Value tests check the production declarations directly: the closed InjectionUnsupportedReason
// set, the frozen JSON shapes, PeerKey normalization, validation and parsing, the redacted
// PlatformClipboardText renderings and the public surface itself. Rule tests run the reference
// conformers below through the rules each protocol documents. The conformers are test code
// written against the public API alone (plain `import`): they show that every rule can be met
// with these shapes and they are the pattern a platform backend follows. They are not product
// code.

import Foundation
import KVMContracts
import Testing

// MARK: - Fixtures

/// Synthetic sentinels that exist only so a privacy assertion has something distinctive to
/// search for. They are test fixtures, never clipboard content.
private let probeText = "m4-002-probe-\u{1F600}-\u{6E2C}"
private let probeHash = "m4-002-probe-hash"

/// One-, two-, three- and four-byte UTF-8 sequences in one value: ten bytes in total.
private let mixedWidthText = "a\u{00E9}\u{6E2C}\u{1F600}"
private let mixedWidthByteCount = 10

private let sha256DigestLength = 32

private let desktop = PlatformScreenGeometry(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

/// A raw SHA-256-sized fingerprint whose every byte is `seed`.
private func fingerprint(_ seed: UInt8) -> Data {
  Data(repeating: seed, count: sha256DigestLength)
}

private func byteLimit(_ byteCount: Int) throws -> ClipboardByteLimit {
  try #require(ClipboardByteLimit(byteCount: byteCount))
}

/// Hosts in these tests are synthetic: names under the reserved `.example` domain (RFC 2606) and
/// colon-bearing strings that are not addresses, so no output ever names a real host or address.
private func peer(_ host: String = "server.example", port: UInt16 = 24_800) throws -> PeerKey {
  try #require(PeerKey(host: host, port: port))
}

/// Stored `host:port` values that are not peer keys, for both the parser and the decoder.
private let refusedRawValues = [
  "", "server.example", ":24800", "server.example:", "server.example:0",
  "server.example:65536", "server.example:+24800", "server.example:024800",
  "server.example:24 800", "server name.example:24800", "server.example\n:24800",
  "caf\u{00E9}.example:24800",
]

/// The code of a failed result, or `nil` for a success.
private func failureCode<Success>(_ result: CoreResult<Success>) -> CoreErrorCode? {
  guard case .failure(let error) = result else { return nil }
  return error.code
}

/// Exhaustive by construction (no `default`): a fifth reason fails to compile here first.
private func frozenName(of reason: InjectionUnsupportedReason) -> String {
  switch reason {
  case .unknownKey: "unknownKey"
  case .noPlatformKeyCode: "noPlatformKeyCode"
  case .buttonUnavailable: "buttonUnavailable"
  case .repeatNotInjected: "repeatNotInjected"
  }
}

/// Exhaustive by construction: a sixth signal fails to compile here first.
private func frozenName(of signal: LifecycleSignal) -> String {
  switch signal {
  case .willSuspend: "willSuspend"
  case .didResume: "didResume"
  case .networkAvailable: "networkAvailable"
  case .networkUnavailable: "networkUnavailable"
  case .terminationRequested: "terminationRequested"
  }
}

// MARK: - SHA-256 (FIPS 180-4)

private let sha256InitialHash: [UInt32] = [
  0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB,
  0x5BE0_CD19,
]

private let sha256RoundConstants: [UInt32] = [
  0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4,
  0xAB1C_5ED5, 0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE,
  0x9BDC_06A7, 0xC19B_F174, 0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F,
  0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA, 0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
  0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967, 0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC,
  0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85, 0xA2BF_E8A1, 0xA81A_664B,
  0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070, 0x19A4_C116,
  0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
  0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7,
  0xC671_78F2,
]

private func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
  (value >> count) | (value << (32 - count))
}

/// The lowercase hexadecimal SHA-256 digest of `bytes` (FIPS 180-4): the frozen `contentHash`
/// function. Foundation offers no SHA-256 on every platform this package builds for, so the
/// tests carry this small implementation and check it against the standard's own examples.
private func sha256Hex(_ bytes: [UInt8]) -> String {
  var message = bytes
  let bitCount = UInt64(bytes.count) &* 8
  message.append(0x80)
  while message.count % 64 != 56 {
    message.append(0)
  }
  for shift in stride(from: 56, through: 0, by: -8) {
    message.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
  }
  var hash = sha256InitialHash
  var schedule = [UInt32](repeating: 0, count: 64)
  for blockStart in stride(from: 0, to: message.count, by: 64) {
    for index in 0..<16 {
      let byte = blockStart + index * 4
      let high = UInt32(message[byte]) << 24 | UInt32(message[byte + 1]) << 16
      let low = UInt32(message[byte + 2]) << 8 | UInt32(message[byte + 3])
      schedule[index] = high | low
    }
    for index in 16..<64 {
      let early = schedule[index - 15]
      let late = schedule[index - 2]
      let sigma0 = rotateRight(early, by: 7) ^ rotateRight(early, by: 18) ^ (early >> 3)
      let sigma1 = rotateRight(late, by: 17) ^ rotateRight(late, by: 19) ^ (late >> 10)
      schedule[index] = schedule[index - 16] &+ sigma0 &+ schedule[index - 7] &+ sigma1
    }
    var state = hash
    for index in 0..<64 {
      let (a, b, c, d, e, f, g, h) = (
        state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7]
      )
      let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
      let choice = (e & f) ^ (~e & g)
      let first = h &+ sum1 &+ choice &+ sha256RoundConstants[index] &+ schedule[index]
      let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
      let majority = (a & b) ^ (a & c) ^ (b & c)
      let second = sum0 &+ majority
      state = [first &+ second, a, b, c, d &+ first, e, f, g]
    }
    for index in 0..<8 {
      hash[index] = hash[index] &+ state[index]
    }
  }
  return hash.map { word in
    let digits = String(word, radix: 16)
    return String(repeating: "0", count: 8 - digits.count) + digits
  }.joined()
}

// MARK: - Production source

/// The production file's lines, as written.
private func productionSourceLines() throws -> [String] {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // KVMContractsTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // KVMContracts
    .appendingPathComponent("Sources/KVMContracts/PlatformBackendContracts.swift")
  return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
}

/// `line` without its `//` comment, trimmed. The production file has no `//` inside a string.
private func codeText(of line: String) -> String {
  let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
  return code.trimmingCharacters(in: .whitespaces)
}

/// Whether `code` holds `word` where it does not continue an identifier, so `print(` matches a
/// call but not the end of `loadTrustedFingerprint(`.
private func mentions(_ word: String, in code: String) -> Bool {
  var searchStart = code.startIndex
  while let range = code.range(of: word, range: searchStart..<code.endIndex) {
    guard range.lowerBound > code.startIndex else { return true }
    let before = code[code.index(before: range.lowerBound)]
    guard before.isLetter || before.isNumber || before == "_" else { return true }
    searchStart = range.upperBound
  }
  return false
}

/// Every declaration that can be public surface, each as one line holding its whole header:
/// every file-level line (types, extensions, attributes) and every member that is not private.
/// A wrapped header is joined while a parenthesis is open, while it ends with a comma, or when
/// its brace stands on the next line, so a conformance added on a continuation line, an
/// `extension` or an attribute shows up too. Bodies are indented deeper and are left out.
private func publicSurface(of lines: [String]) -> [String] {
  var surface: [String] = []
  var index = 0
  while index < lines.count {
    let indentation = lines[index].prefix { $0 == " " }.count
    var text = codeText(of: lines[index])
    index += 1
    let skipped = ["}", "{", ""].contains(text) || text.hasPrefix("import ")
    let isPrivate = text.hasPrefix("private ") || text.hasPrefix("fileprivate ")
    guard indentation == 0 || indentation == 2, !skipped, !isPrivate else { continue }
    while index < lines.count {
      let next = codeText(of: lines[index])
      let openParentheses = text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
      guard openParentheses > 0 || text.hasSuffix(",") || next == "{" else { break }
      text += text.hasSuffix("(") || next.hasPrefix(")") ? next : " " + next
      index += 1
    }
    surface.append(text)
  }
  return surface
}

/// The C-015 public surface: the plan b.9 sketch, the public initializers a conformer in another
/// module needs, the redacted renderings, `PeerKey`'s parser and its validating decoder.
private let frozenPublicSurface = [
  "public enum InjectionOutcome: Equatable, Sendable {",
  "case injected",
  "case unsupported(InjectionUnsupportedReason)",
  "public enum InjectionUnsupportedReason: String, Codable, CaseIterable, Sendable {",
  "case unknownKey",
  "case noPlatformKeyCode",
  "case buttonUnavailable",
  "case repeatNotInjected",
  "public protocol InputInjectionBackend: Sendable {",
  "func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome>",
  "func flush() -> CoreResult<Void>",
  "func releaseAllHeld() -> CoreResult<Void>",
  "public struct PlatformScreenGeometry: Equatable, Codable, Sendable {",
  "public let originX: Int",
  "public let originY: Int",
  "public let width: Int",
  "public let height: Int",
  "public let cursorX: Int",
  "public let cursorY: Int",
  "public init(originX: Int, originY: Int, width: Int, height: Int, cursorX: Int, cursorY: Int) {",
  "public protocol ScreenBackend: Sendable {",
  "func currentGeometry() -> CoreResult<PlatformScreenGeometry>",
  "var changes: AsyncStream<PlatformScreenGeometry> { get }",
  "func stop() async",
  "public struct PlatformClipboardText: Sendable, CustomStringConvertible,"
    + " CustomDebugStringConvertible, CustomReflectable {",
  "public let text: String",
  "public let contentHash: String",
  "public init(text: String, contentHash: String) {",
  "public var description: String { \"PlatformClipboardText(redacted)\" }",
  "public var debugDescription: String { description }",
  "public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }",
  "public protocol ClipboardBackend: Sendable {",
  "func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?>",
  "func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void>",
  "var ownerChanges: AsyncStream<Void> { get }",
  "func stop() async",
  "public struct PeerKey: Hashable, Codable, Sendable {",
  "public let rawValue: String",
  "public init?(host: String, port: UInt16) {",
  "public init?(rawValue: String) {",
  "public init(from decoder: any Decoder) throws {",
  "public enum TrustInsertOutcome: Equatable, Sendable {",
  "case inserted",
  "case existing(storedFingerprint: Data)",
  "public protocol SecureStorageBackend: Sendable {",
  "func loadTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Data?>",
  "func insertTrustedFingerprintIfAbsent(_ fingerprint: Data, for peer: PeerKey)"
    + " async -> CoreResult<TrustInsertOutcome>",
  "func removeTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Void>",
  "public enum LifecycleSignal: Equatable, Sendable {",
  "case willSuspend",
  "case didResume",
  "case networkAvailable",
  "case networkUnavailable",
  "case terminationRequested",
  "public protocol LifecycleBackend: Sendable {",
  "var signals: AsyncStream<LifecycleSignal> { get }",
  "func stop()",
  "public protocol CaptureBackend: Sendable {",
  "func start() throws(CoreError)",
  "func stop()",
  "var events: AsyncStream<KVMEvent> { get }",
]

// MARK: - Reference conformers (test code, public API only)

/// A failure carrying only `code`. The rules constrain codes; the reference conformers fix
/// nothing else about their errors.
private func referenceFailure(_ code: CoreErrorCode) -> CoreError {
  CoreError(
    code: code,
    severity: .error,
    retryDisposition: .never,
    cleanupDisposition: .notRequired
  )
}

/// What the reference platform received from an injector, in order.
private enum PlatformInput: Equatable {
  case motion(NormalizedPoint)
  case wheel(deltaX: Int32, deltaY: Int32)
  case button(code: UInt8, isDown: Bool)
  case key(code: UInt32, isDown: Bool)
}

/// The named catalog keys, in a fixed order that gives each its reference key code.
private let referenceNamedKeys: [VirtualKey] = [
  .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
  .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp, .volumeDown,
  .mute,
]

/// The C-005 catalog's modifier group (M1-042), which `releaseAllHeld()` releases last.
private let referenceModifierKeys: [VirtualKey] = [.shift, .control, .option, .command, .capsLock]

/// The key code the reference keyboard mapping starts with for `key`, or `nil` for a value
/// outside the C-005 catalog (M1-042). Exhaustive with no `default`, so a later catalog member
/// fails to compile here until it is handled.
private func referenceKeyCode(_ key: VirtualKey) -> UInt32? {
  switch key {
  case .letter(let index):
    index <= 25 ? 100 + UInt32(index) : nil
  case .digit(let digit):
    digit <= 9 ? 200 + UInt32(digit) : nil
  case .function(let number):
    (1...24).contains(number) ? 300 + UInt32(number) : nil
  case .punctuation(let punctuation):
    400 + UInt32(punctuation.rawValue)
  case .unknown:
    nil
  case .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home,
    .end, .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp,
    .volumeDown, .mute:
    referenceNamedKeys.firstIndex(of: key).map { 500 + UInt32($0) }
  }
}

/// A reference `InputInjectionBackend` over an in-memory platform with a keyboard mapping and a
/// pointer that can change at any time. The platform queues what it receives and processes the
/// queue on `flush()`, as a display connection does.
private final class ReferenceInjector: InputInjectionBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var keyCodeOverrides: [(key: VirtualKey, code: UInt32?)]
  private var buttonCodeOverrides: [(button: MouseButton, code: UInt8?)]
  private var heldKeys: [(key: VirtualKey, code: UInt32)] = []
  private var heldButtons: [(button: MouseButton, code: UInt8)] = []
  private var queued: [PlatformInput] = []
  private var processedInputs: [PlatformInput] = []
  private var platformLost = false

  init(keysWithoutCode: [VirtualKey] = [], unavailableButtons: [MouseButton] = []) {
    keyCodeOverrides = keysWithoutCode.map { (key: $0, code: nil) }
    buttonCodeOverrides = unavailableButtons.map { (button: $0, code: nil) }
  }

  /// Everything the platform received, processed or not.
  var received: [PlatformInput] { lock.withLock { processedInputs + queued } }

  /// What the platform has processed, in order.
  var processed: [PlatformInput] { lock.withLock { processedInputs } }

  /// The key codes the platform holds down after everything it received.
  var platformHeldKeyCodes: Set<UInt32> {
    var held: Set<UInt32> = []
    for case .key(let code, let isDown) in received {
      if isDown { held.insert(code) } else { held.remove(code) }
    }
    return held
  }

  /// The buttons the platform holds down after everything it received.
  var platformHeldButtons: Set<UInt8> {
    var held: Set<UInt8> = []
    for case .button(let code, let isDown) in received {
      if isDown { held.insert(code) } else { held.remove(code) }
    }
    return held
  }

  /// The keyboard mapping changes, as when a layout is reloaded: `key` now has `code`, or none.
  func remap(_ key: VirtualKey, to code: UInt32?) {
    lock.withLock {
      keyCodeOverrides.removeAll { $0.key == key }
      keyCodeOverrides.append((key: key, code: code))
    }
  }

  /// The pointer changes: `button` now has `code`, or none.
  func remapButton(_ button: MouseButton, to code: UInt8?) {
    lock.withLock {
      buttonCodeOverrides.removeAll { $0.button == button }
      buttonCodeOverrides.append((button: button, code: code))
    }
  }

  /// The platform goes away, as a display does when its server exits.
  func losePlatform() {
    lock.withLock { platformLost = true }
  }

  func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome> {
    lock.withLock { () -> CoreResult<InjectionOutcome> in
      let input: PlatformInput
      switch event {
      case .mouseMove(let position):
        input = .motion(position)
      case .scroll(let deltaX, let deltaY):
        input = .wheel(deltaX: deltaX, deltaY: deltaY)
      case .mouseButton(let button, let phase):
        let code = phase == .up ? releaseCode(for: button) : currentCode(for: button)
        guard let code else { return .success(.unsupported(.buttonUnavailable)) }
        input = .button(code: code, isDown: phase == .down)
      case .key(let key, let phase, _):
        guard referenceKeyCode(key) != nil else {
          return .success(.unsupported(.unknownKey))
        }
        guard phase != .repeatKey else {
          return .success(.unsupported(.repeatNotInjected))
        }
        let code = phase == .up ? releaseCode(for: key) : currentCode(for: key)
        guard let code else { return .success(.unsupported(.noPlatformKeyCode)) }
        input = .key(code: code, isDown: phase == .down)
      case .clipboard, .enterScreen, .leaveScreen:
        return .failure(referenceFailure(.internalFailure(.preconditionFailed)))
      }
      guard !platformLost else {
        return .failure(referenceFailure(.lifecycle(.subsystemUnavailable)))
      }
      queued.append(input)
      remember(input, for: event)
      return .success(.injected)
    }
  }

  func flush() -> CoreResult<Void> {
    lock.withLock { () -> CoreResult<Void> in
      guard !platformLost else {
        return .failure(referenceFailure(.lifecycle(.subsystemUnavailable)))
      }
      processedInputs += queued
      queued.removeAll()
      return .success(())
    }
  }

  func releaseAllHeld() -> CoreResult<Void> {
    lock.withLock { () -> CoreResult<Void> in
      let keys = Array(heldKeys.reversed())
      let ordinaryKeys = keys.filter { !referenceModifierKeys.contains($0.key) }
      let modifierKeys = keys.filter { referenceModifierKeys.contains($0.key) }
      var releases: [PlatformInput] = ordinaryKeys.map { .key(code: $0.code, isDown: false) }
      releases += heldButtons.reversed().map { .button(code: $0.code, isDown: false) }
      releases += modifierKeys.map { .key(code: $0.code, isDown: false) }
      guard releases.isEmpty || !platformLost else {
        // Nothing reached the platform, so everything stays recorded for a later sweep.
        return .failure(referenceFailure(.inputSafety(.cleanupPartial)))
      }
      queued += releases
      heldKeys.removeAll()
      heldButtons.removeAll()
      return .success(())
    }
  }

  private func currentCode(for key: VirtualKey) -> UInt32? {
    guard let override = keyCodeOverrides.first(where: { $0.key == key }) else {
      return referenceKeyCode(key)
    }
    return override.code
  }

  private func currentCode(for button: MouseButton) -> UInt8? {
    guard let override = buttonCodeOverrides.first(where: { $0.button == button }) else {
      return button.rawValue
    }
    return override.code
  }

  /// The code a release of `key` uses: the one it was pressed with while it is held, so that a
  /// mapping change cannot strand it, and otherwise the current mapping's.
  private func releaseCode(for key: VirtualKey) -> UInt32? {
    heldKeys.first { $0.key == key }?.code ?? currentCode(for: key)
  }

  /// The code a release of `button` uses, by the same rule.
  private func releaseCode(for button: MouseButton) -> UInt8? {
    heldButtons.first { $0.button == button }?.code ?? currentCode(for: button)
  }

  /// Keeps, in memory only, the platform code of every key and button this backend holds.
  private func remember(_ input: PlatformInput, for event: KVMEvent) {
    switch (event, input) {
    case (.key(let key, _, _), .key(let code, let isDown)):
      heldKeys.removeAll { $0.key == key }
      if isDown { heldKeys.append((key: key, code: code)) }
    case (.mouseButton(let button, _), .button(let code, let isDown)):
      heldButtons.removeAll { $0.button == button }
      if isDown { heldButtons.append((button: button, code: code)) }
    default:
      break
    }
  }
}

/// A reference `ScreenBackend` over an in-memory desktop.
private final class ReferenceScreen: ScreenBackend, @unchecked Sendable {
  let changes: AsyncStream<PlatformScreenGeometry>
  private let continuation: AsyncStream<PlatformScreenGeometry>.Continuation
  private let lock = NSLock()
  private var geometry: PlatformScreenGeometry
  private var stopped = false

  init(geometry: PlatformScreenGeometry) {
    let (stream, continuation) = AsyncStream<PlatformScreenGeometry>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    changes = stream
    self.continuation = continuation
    self.geometry = geometry
  }

  func currentGeometry() -> CoreResult<PlatformScreenGeometry> {
    lock.withLock { () -> CoreResult<PlatformScreenGeometry> in
      guard !stopped, Self.hasArea(geometry) else {
        return .failure(referenceFailure(.lifecycle(.subsystemUnavailable)))
      }
      return .success(geometry)
    }
  }

  /// The platform reports a new desktop.
  func platformChanged(to newGeometry: PlatformScreenGeometry) {
    lock.withLock {
      guard !stopped else { return }
      geometry = newGeometry
      guard Self.hasArea(newGeometry) else { return }
      continuation.yield(newGeometry)
    }
  }

  /// The pointer moves; the desktop stays as it is.
  func platformPointerMoved(toX cursorX: Int, y cursorY: Int) {
    lock.withLock {
      guard !stopped else { return }
      geometry = PlatformScreenGeometry(
        originX: geometry.originX, originY: geometry.originY, width: geometry.width,
        height: geometry.height, cursorX: cursorX, cursorY: cursorY)
      // Pointer movement alone is not a change: nothing is yielded.
    }
  }

  func stop() async {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      continuation.finish()
    }
  }

  private static func hasArea(_ geometry: PlatformScreenGeometry) -> Bool {
    geometry.width >= 1 && geometry.height >= 1
  }
}

/// A reference `ClipboardBackend` over an in-memory platform clipboard. Like a selection owner,
/// the platform states a size before it hands over any byte; a test can make that size a lower
/// bound and the hand-over happen in parts, as a selection transferred incrementally does.
private actor ReferenceClipboard: ClipboardBackend {
  nonisolated let ownerChanges: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private var platformBytes: [UInt8]?
  private var statedByteCount: Int?
  private var partByteCount: Int?
  private var ownerAnswers = true
  private var stopped = false

  /// Bytes copied out of the platform into this process.
  private(set) var transferredByteCount = 0

  /// The most content bytes a read held at once.
  private(set) var largestHeldByteCount = 0

  /// Bytes encoded for the platform by writes.
  private(set) var encodedByteCount = 0

  init() {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    ownerChanges = stream
    self.continuation = continuation
  }

  /// What the platform clipboard holds, as bytes.
  var platformContent: [UInt8]? { platformBytes }

  /// Another application takes the clipboard with `bytes`. It states `statedByteCount` as the
  /// size (the true size when `nil`) and hands the bytes over in parts of `partByteCount`
  /// (all at once when `nil`).
  func foreignCopy(_ bytes: [UInt8], statedByteCount: Int? = nil, partByteCount: Int? = nil) {
    guard !stopped else { return }
    platformBytes = bytes
    self.statedByteCount = statedByteCount
    self.partByteCount = partByteCount
    ownerAnswers = true
    continuation.yield()
  }

  /// The application that owns the clipboard stops answering requests for it.
  func ownerStopsAnswering() {
    ownerAnswers = false
  }

  func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?> {
    guard !Task.isCancelled else {
      return .failure(referenceFailure(.cancellation(.requested)))
    }
    guard !stopped else {
      return .failure(referenceFailure(.lifecycle(.subsystemUnavailable)))
    }
    guard let bytes = platformBytes else { return .success(nil) }
    guard ownerAnswers else {
      return .failure(referenceFailure(.timeout(.read)))
    }
    guard (statedByteCount ?? bytes.count) <= limit.byteCount else {
      return .failure(referenceFailure(.clipboard(.oversized)))
    }
    var held: [UInt8] = []
    for part in parts(of: bytes) {
      guard held.count + part.count <= limit.byteCount else {
        return .failure(referenceFailure(.clipboard(.oversized)))
      }
      held += part
      transferredByteCount += part.count
      largestHeldByteCount = max(largestHeldByteCount, held.count)
    }
    do {
      let text = try ClipboardTextCodec.decode(Data(held), limit: limit)
      return .success(
        PlatformClipboardText(text: text, contentHash: sha256Hex(Array(text.utf8))))
    } catch let error as CoreError {
      return .failure(error)
    } catch {
      return .failure(referenceFailure(.internalFailure(.unclassified)))
    }
  }

  func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void> {
    guard !Task.isCancelled else {
      return .failure(referenceFailure(.cancellation(.requested)))
    }
    guard !stopped else {
      return .failure(referenceFailure(.lifecycle(.subsystemUnavailable)))
    }
    guard text.utf8.count <= limit.byteCount else {
      return .failure(referenceFailure(.clipboard(.oversized)))
    }
    let bytes = Array(text.utf8)
    encodedByteCount += bytes.count
    // This backend now owns the clipboard: its own write is not an owner change.
    platformBytes = bytes
    statedByteCount = nil
    partByteCount = nil
    ownerAnswers = true
    return .success(())
  }

  func stop() async {
    guard !stopped else { return }
    stopped = true
    continuation.finish()
  }

  private func parts(of bytes: [UInt8]) -> [[UInt8]] {
    let size = max(partByteCount ?? bytes.count, 1)
    return stride(from: 0, to: bytes.count, by: size).map { start in
      Array(bytes[start..<min(start + size, bytes.count)])
    }
  }
}

/// A reference `SecureStorageBackend` over an in-memory record set. Actor isolation makes each
/// insert-if-absent atomic, as an atomic platform add does.
private actor ReferenceTrustStore: SecureStorageBackend {
  private var records: [PeerKey: Data] = [:]
  private var available = true
  private var protectedFromOthers = true

  /// Reads, writes and removals that reached storage.
  private(set) var storageOperationCount = 0

  /// A record written by something other than this store, possibly malformed.
  func plant(_ value: Data, for peer: PeerKey) {
    records[peer] = value
  }

  /// Storage stops working, as an unreadable file or a locked keychain does.
  func makeUnavailable() {
    available = false
  }

  /// Other users can now change the records, as when the record file's mode widens or the file
  /// is replaced by a link.
  func exposeToOtherUsers() {
    protectedFromOthers = false
  }

  func loadTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Data?> {
    guard !Task.isCancelled else {
      return .failure(referenceFailure(.cancellation(.requested)))
    }
    guard protectedFromOthers else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    storageOperationCount += 1
    guard available else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    return .success(records[peer])
  }

  func insertTrustedFingerprintIfAbsent(
    _ fingerprint: Data,
    for peer: PeerKey
  ) async -> CoreResult<TrustInsertOutcome> {
    guard fingerprint.count == sha256DigestLength else {
      return .failure(referenceFailure(.security(.trustRejected)))
    }
    guard !Task.isCancelled else {
      return .failure(referenceFailure(.cancellation(.requested)))
    }
    guard protectedFromOthers else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    storageOperationCount += 1
    guard available else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    if let stored = records[peer] {
      return .success(.existing(storedFingerprint: stored))
    }
    records[peer] = Data(fingerprint)
    return .success(.inserted)
  }

  func removeTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Void> {
    guard protectedFromOthers else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    storageOperationCount += 1
    guard available else {
      return .failure(referenceFailure(.security(.secureStorageUnavailable)))
    }
    records[peer] = nil
    return .success(())
  }
}

/// A reference `LifecycleBackend` relaying what an in-memory platform reports.
private final class ReferenceLifecycle: LifecycleBackend, @unchecked Sendable {
  let signals: AsyncStream<LifecycleSignal>
  private let continuation: AsyncStream<LifecycleSignal>.Continuation
  private let lock = NSLock()
  private var stopped = false

  init(capacity: Int = 8) {
    let (stream, continuation) = AsyncStream<LifecycleSignal>.makeStream(
      bufferingPolicy: .bufferingOldest(capacity))
    signals = stream
    self.continuation = continuation
  }

  /// The platform reports a change.
  func platformReported(_ signal: LifecycleSignal) {
    lock.withLock {
      guard !stopped else { return }
      if case .enqueued = continuation.yield(signal) { return }
      // The signal cannot be delivered: end the stream rather than drop it silently.
      stopped = true
      continuation.finish()
    }
  }

  func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      continuation.finish()
    }
  }
}

/// A reference `CaptureBackend` over an in-memory platform input source.
private final class ReferenceCapture: CaptureBackend, @unchecked Sendable {
  private enum State {
    case idle
    case capturing
    case stopped
  }

  let events: AsyncStream<KVMEvent>
  private let continuation: AsyncStream<KVMEvent>.Continuation
  private let lock = NSLock()
  private let platformPermitsCapture: Bool
  private var state = State.idle
  private var suppressing = false

  init(bufferLimit: Int, platformPermitsCapture: Bool = true) {
    let (stream, continuation) = AsyncStream<KVMEvent>.makeStream(
      bufferingPolicy: .bufferingOldest(bufferLimit))
    events = stream
    self.continuation = continuation
    self.platformPermitsCapture = platformPermitsCapture
  }

  /// Whether local input is currently withheld from the local machine.
  var suppressesLocalInput: Bool { lock.withLock { suppressing } }

  func start() throws(CoreError) {
    let failure = lock.withLock { () -> CoreError? in
      guard state == .idle else {
        return referenceFailure(.internalFailure(.preconditionFailed))
      }
      guard platformPermitsCapture else {
        endCapture()
        return referenceFailure(.permission(.capabilityUnavailable))
      }
      state = .capturing
      suppressing = true
      return nil
    }
    if let failure { throw failure }
  }

  /// The platform captured `event`.
  func platformCaptured(_ event: KVMEvent) {
    lock.withLock {
      guard state == .capturing else { return }
      let result = continuation.yield(event)
      if case .enqueued = result { return }
      // A move that does not fit may be dropped: a later move carries the newer position.
      if case .dropped = result, case .mouseMove = event { return }
      // Any other event that cannot be delivered stops capture rather than vanish.
      endCapture()
    }
  }

  func stop() {
    lock.withLock { endCapture() }
  }

  /// Ends capture and suppression and finishes `events`. Called with the lock held.
  private func endCapture() {
    guard state != .stopped else { return }
    state = .stopped
    suppressing = false
    continuation.finish()
  }
}

// MARK: - Tests

@Suite(.timeLimit(.minutes(1)))
struct PlatformBackendContractsTests {
  // MARK: Input injection

  @Test func inputEventsAreInjectedAndReachThePlatformInCallOrder() throws {
    let injector = ReferenceInjector()
    let position = NormalizedPoint(x: 0, y: 1)
    let events: [KVMEvent] = [
      .mouseMove(position: position),
      .mouseButton(button: .left, phase: .down),
      .mouseButton(button: .left, phase: .up),
      .scroll(deltaX: .min, deltaY: .max),
      .key(key: .letter(25), phase: .down, modifiers: ModifierState(shift: true)),
      .key(key: .letter(25), phase: .up, modifiers: ModifierState(shift: true)),
      .key(key: .digit(9), phase: .down, modifiers: ModifierState()),
      .key(key: .digit(9), phase: .up, modifiers: ModifierState()),
      .key(key: .function(1), phase: .down, modifiers: ModifierState()),
      .key(key: .function(24), phase: .up, modifiers: ModifierState()),
      .key(key: .punctuation(.slash), phase: .down, modifiers: ModifierState()),
      .key(key: .punctuation(.slash), phase: .up, modifiers: ModifierState()),
    ]
    let left = MouseButton.left.rawValue
    let z = try #require(referenceKeyCode(.letter(25)))
    let nine = try #require(referenceKeyCode(.digit(9)))
    let f1 = try #require(referenceKeyCode(.function(1)))
    let f24 = try #require(referenceKeyCode(.function(24)))
    let slash = try #require(referenceKeyCode(.punctuation(.slash)))
    let expected: [PlatformInput] = [
      .motion(position), .button(code: left, isDown: true), .button(code: left, isDown: false),
      .wheel(deltaX: .min, deltaY: .max), .key(code: z, isDown: true),
      .key(code: z, isDown: false), .key(code: nine, isDown: true),
      .key(code: nine, isDown: false), .key(code: f1, isDown: true),
      .key(code: f24, isDown: false), .key(code: slash, isDown: true),
      .key(code: slash, isDown: false),
    ]

    for event in events {
      #expect(try injector.inject(event).get() == .injected)
    }
    #expect(injector.received == expected)
    #expect(injector.processed.isEmpty)

    try injector.flush().get()
    #expect(injector.processed == expected)
  }

  @Test func unknownAndOutOfDomainKeysAreUnsupportedInEveryPhaseAndNothingIsRecorded() throws {
    let injector = ReferenceInjector()
    let unknownKeys: [VirtualKey] = [
      .unknown(0), .unknown(.max), .letter(26), .letter(.max), .digit(10), .function(0),
      .function(25),
    ]

    for key in unknownKeys {
      for phase in [KeyPhase.down, .repeatKey, .up] {
        let event = KVMEvent.key(key: key, phase: phase, modifiers: ModifierState(shift: true))
        #expect(try injector.inject(event).get() == .unsupported(.unknownKey))
      }
    }
    try injector.flush().get()
    #expect(injector.received.isEmpty)
    #expect(injector.processed.isEmpty)
  }

  @Test func missingKeyCodesUnavailableButtonsAndDeclinedRepeatsAreUnsupportedWithoutEffect()
    throws
  {
    let injector = ReferenceInjector(keysWithoutCode: [.volumeUp], unavailableButtons: [.auxiliary])
    let noCode = KVMEvent.key(key: .volumeUp, phase: .down, modifiers: ModifierState())
    let noButton = KVMEvent.mouseButton(button: .auxiliary, phase: .down)
    let repeated = KVMEvent.key(key: .space, phase: .repeatKey, modifiers: ModifierState())

    #expect(try injector.inject(noCode).get() == .unsupported(.noPlatformKeyCode))
    #expect(try injector.inject(noButton).get() == .unsupported(.buttonUnavailable))
    #expect(try injector.inject(repeated).get() == .unsupported(.repeatNotInjected))
    try injector.flush().get()
    #expect(injector.received.isEmpty)

    #expect(InjectionOutcome.unsupported(.unknownKey) != .unsupported(.noPlatformKeyCode))
    #expect(InjectionOutcome.unsupported(.buttonUnavailable) != .injected)
  }

  @Test func releasingHeldInputReleasesWhatWasPressedEvenAfterTheMappingChanged() throws {
    let injector = ReferenceInjector()
    let z = try #require(referenceKeyCode(.letter(25)))
    let a = try #require(referenceKeyCode(.letter(0)))
    let middle = MouseButton.middle.rawValue
    let press: [KVMEvent] = [
      .key(key: .letter(25), phase: .down, modifiers: ModifierState()),
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .mouseButton(button: .middle, phase: .down),
    ]
    let release: [KVMEvent] = [
      .key(key: .letter(25), phase: .up, modifiers: ModifierState()),
      .key(key: .letter(0), phase: .up, modifiers: ModifierState()),
      .mouseButton(button: .middle, phase: .up),
    ]

    for event in press {
      #expect(try injector.inject(event).get() == .injected)
    }
    // While all three are held, the keyboard mapping is reloaded and the pointer loses a button.
    injector.remap(.letter(25), to: 999)
    injector.remap(.letter(0), to: nil)
    injector.remapButton(.middle, to: nil)
    for event in release {
      #expect(try injector.inject(event).get() == .injected)
    }

    #expect(
      injector.received == [
        .key(code: z, isDown: true), .key(code: a, isDown: true),
        .button(code: middle, isDown: true), .key(code: z, isDown: false),
        .key(code: a, isDown: false), .button(code: middle, isDown: false),
      ])
    #expect(injector.platformHeldKeyCodes.isEmpty)
    #expect(injector.platformHeldButtons.isEmpty)
    // Released input is no longer held, so its next press uses the new mapping.
    #expect(try injector.inject(press[0]).get() == .injected)
    #expect(injector.received.last == .key(code: 999, isDown: true))
  }

  @Test func aReleaseOfInputTheBackendDoesNotHoldUsesTheCurrentMapping() throws {
    let injector = ReferenceInjector(keysWithoutCode: [.mute], unavailableButtons: [.auxiliary])
    let d = try #require(referenceKeyCode(.letter(3)))
    let unheldKey = KVMEvent.key(key: .letter(3), phase: .up, modifiers: ModifierState())
    let unheldMute = KVMEvent.key(key: .mute, phase: .up, modifiers: ModifierState())
    let unheldButton = KVMEvent.mouseButton(button: .auxiliary, phase: .up)

    #expect(try injector.inject(unheldKey).get() == .injected)
    #expect(try injector.inject(unheldMute).get() == .unsupported(.noPlatformKeyCode))
    #expect(try injector.inject(unheldButton).get() == .unsupported(.buttonUnavailable))
    #expect(injector.received == [.key(code: d, isDown: false)])
    #expect(injector.platformHeldKeyCodes.isEmpty)
  }

  @Test func releaseAllHeldReleasesKeysThenButtonsThenModifiersInReversePressOrder() throws {
    let injector = ReferenceInjector()
    let a = try #require(referenceKeyCode(.letter(0)))
    let b = try #require(referenceKeyCode(.letter(1)))
    let shift = try #require(referenceKeyCode(.shift))
    let control = try #require(referenceKeyCode(.control))
    let left = MouseButton.left.rawValue
    let right = MouseButton.right.rawValue
    let presses: [KVMEvent] = [
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .key(key: .shift, phase: .down, modifiers: ModifierState(shift: true)),
      .mouseButton(button: .left, phase: .down),
      .key(key: .letter(1), phase: .down, modifiers: ModifierState(shift: true)),
      .key(key: .control, phase: .down, modifiers: ModifierState(shift: true, control: true)),
      .mouseButton(button: .right, phase: .down),
    ]
    for event in presses {
      #expect(try injector.inject(event).get() == .injected)
    }

    try injector.releaseAllHeld().get()

    #expect(
      Array(injector.received.dropFirst(presses.count)) == [
        .key(code: b, isDown: false), .key(code: a, isDown: false),
        .button(code: right, isDown: false), .button(code: left, isDown: false),
        .key(code: control, isDown: false), .key(code: shift, isDown: false),
      ])
    #expect(injector.platformHeldKeyCodes.isEmpty)
    #expect(injector.platformHeldButtons.isEmpty)
  }

  @Test func releaseAllHeldReleasesInputWhoseReleaseNeverArrivedWithItsPressedCode() throws {
    let injector = ReferenceInjector()
    let z = try #require(referenceKeyCode(.letter(25)))
    let d = try #require(referenceKeyCode(.letter(3)))
    let middle = MouseButton.middle.rawValue
    let events: [KVMEvent] = [
      .key(key: .letter(3), phase: .down, modifiers: ModifierState()),
      .key(key: .letter(25), phase: .down, modifiers: ModifierState()),
      .mouseButton(button: .middle, phase: .down),
      .key(key: .letter(3), phase: .up, modifiers: ModifierState()),
    ]
    for event in events {
      #expect(try injector.inject(event).get() == .injected)
    }
    // The releases of Z and the middle button were counted by the caller but dropped with its
    // queue; the mapping has changed since the presses.
    injector.remap(.letter(25), to: 999)
    injector.remapButton(.middle, to: nil)

    try injector.releaseAllHeld().get()

    #expect(
      Array(injector.received.dropFirst(events.count)) == [
        .key(code: z, isDown: false), .button(code: middle, isDown: false),
      ])
    #expect(!injector.received.dropFirst(events.count).contains(.key(code: d, isDown: false)))
    #expect(injector.platformHeldKeyCodes.isEmpty)
    #expect(injector.platformHeldButtons.isEmpty)
  }

  @Test func releaseAllHeldIsIdempotentAndHasNothingToReleaseOnceAllWasReleased() throws {
    let injector = ReferenceInjector()
    let pairs: [KVMEvent] = [
      .key(key: .letter(2), phase: .down, modifiers: ModifierState()),
      .key(key: .letter(2), phase: .up, modifiers: ModifierState()),
      .mouseButton(button: .left, phase: .down),
      .mouseButton(button: .left, phase: .up),
    ]
    for event in pairs {
      #expect(try injector.inject(event).get() == .injected)
    }

    try injector.releaseAllHeld().get()
    #expect(injector.received.count == pairs.count)

    let press = KVMEvent.key(key: .option, phase: .down, modifiers: ModifierState(option: true))
    #expect(try injector.inject(press).get() == .injected)
    try injector.releaseAllHeld().get()
    let afterFirstSweep = injector.received
    try injector.releaseAllHeld().get()

    #expect(afterFirstSweep.count == pairs.count + 2)
    #expect(injector.received == afterFirstSweep)
    #expect(injector.platformHeldKeyCodes.isEmpty)
  }

  @Test func releaseAllHeldOnALostPlatformFailsAsPartialCleanupAndKeepsTheRecord() throws {
    let idle = ReferenceInjector()
    idle.losePlatform()
    #expect(failureCode(idle.releaseAllHeld()) == nil)

    let injector = ReferenceInjector()
    let e = try #require(referenceKeyCode(.letter(4)))
    let press = KVMEvent.key(key: .letter(4), phase: .down, modifiers: ModifierState())
    #expect(try injector.inject(press).get() == .injected)
    injector.losePlatform()

    #expect(failureCode(injector.releaseAllHeld()) == .inputSafety(.cleanupPartial))
    #expect(failureCode(injector.releaseAllHeld()) == .inputSafety(.cleanupPartial))
    #expect(injector.platformHeldKeyCodes == [e])
  }

  @Test func eventsThatAreNotInputFailClosedAndChangeNothing() throws {
    let injector = ReferenceInjector()
    let screen = ScreenID()
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(),
      origin: .local,
      utf8Text: probeText,
      contentHash: probeHash
    )
    let events: [KVMEvent] = [
      .clipboard(payload),
      .enterScreen(screen: screen, position: NormalizedPoint(x: 0.5, y: 0.5)),
      .leaveScreen(screen: screen),
    ]

    for event in events {
      #expect(failureCode(injector.inject(event)) == .internalFailure(.preconditionFailed))
    }
    try injector.flush().get()
    #expect(injector.received.isEmpty)
  }

  @Test func flushIsTheBarrierForEverythingInjectedBeforeItAndCanRepeat() throws {
    let injector = ReferenceInjector()
    let shift = try #require(referenceKeyCode(.shift))
    let press = KVMEvent.key(key: .shift, phase: .down, modifiers: ModifierState(shift: true))
    let release = KVMEvent.key(key: .shift, phase: .up, modifiers: ModifierState())
    let sent: [PlatformInput] = [.key(code: shift, isDown: true), .key(code: shift, isDown: false)]

    try injector.flush().get()
    #expect(try injector.inject(press).get() == .injected)
    #expect(try injector.inject(release).get() == .injected)
    #expect(injector.processed.isEmpty)

    try injector.flush().get()
    #expect(injector.processed == sent)
    try injector.flush().get()
    #expect(injector.processed == sent)
  }

  @Test func aLostPlatformFailsInjectionAndFlushTyped() {
    let injector = ReferenceInjector()
    injector.losePlatform()

    let move = KVMEvent.mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5))
    #expect(failureCode(injector.inject(move)) == .lifecycle(.subsystemUnavailable))
    #expect(failureCode(injector.flush()) == .lifecycle(.subsystemUnavailable))
    #expect(injector.received.isEmpty)
  }

  @Test func injectionUnsupportedReasonIsAClosedSetWithAFrozenCoding() throws {
    #expect(
      InjectionUnsupportedReason.allCases == [
        .unknownKey, .noPlatformKeyCode, .buttonUnavailable, .repeatNotInjected,
      ])

    for reason in InjectionUnsupportedReason.allCases {
      let encoded = try JSONEncoder().encode(reason)
      #expect(reason.rawValue == frozenName(of: reason))
      #expect(String(decoding: encoded, as: UTF8.self) == "\"\(frozenName(of: reason))\"")
      #expect(try JSONDecoder().decode(InjectionUnsupportedReason.self, from: encoded) == reason)
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        InjectionUnsupportedReason.self, from: Data(#""unsupportedEvent""#.utf8))
    }
  }

  // MARK: Screen

  @Test func screenGeometryReportsTheDesktopAndThePointer() throws {
    let screen = ReferenceScreen(geometry: desktop)

    let geometry = try screen.currentGeometry().get()

    #expect(geometry == desktop)
    #expect(geometry.width == 1600 && geometry.height == 900)
    #expect(geometry.cursorX == 800 && geometry.cursorY == 450)
  }

  @Test func screenNeverReportsADesktopWithoutArea() async throws {
    let smallest = PlatformScreenGeometry(
      originX: -1, originY: -1, width: 1, height: 1, cursorX: -1, cursorY: -1)
    let noWidth = PlatformScreenGeometry(
      originX: 0, originY: 0, width: 0, height: 900, cursorX: 0, cursorY: 0)
    let screen = ReferenceScreen(geometry: smallest)
    var changes = screen.changes.makeAsyncIterator()

    #expect(try screen.currentGeometry().get() == smallest)
    screen.platformChanged(to: noWidth)
    #expect(failureCode(screen.currentGeometry()) != nil)

    // Stopping finishes the stream; anything yielded before it would come out first.
    await screen.stop()
    #expect(await changes.next() == nil)
  }

  @Test func screenChangesAlwaysDeliverTheNewestGeometry() async throws {
    let wide = PlatformScreenGeometry(
      originX: 0, originY: 0, width: 2560, height: 1440, cursorX: 0, cursorY: 0)
    let tall = PlatformScreenGeometry(
      originX: 0, originY: 0, width: 1080, height: 1920, cursorX: 540, cursorY: 960)
    let screen = ReferenceScreen(geometry: desktop)
    var changes = screen.changes.makeAsyncIterator()

    #expect(try screen.currentGeometry().get() == desktop)
    screen.platformChanged(to: wide)
    screen.platformChanged(to: tall)
    #expect(try screen.currentGeometry().get() == tall)
    await screen.stop()

    var delivered: [PlatformScreenGeometry] = []
    while let geometry = await changes.next() {
      delivered.append(geometry)
    }
    // Coalescing may skip `wide`, but never the newest change, and never reorders.
    #expect(delivered == [wide, tall] || delivered == [tall])
  }

  @Test func pointerMovementAloneIsNotAScreenChange() async throws {
    let screen = ReferenceScreen(geometry: desktop)
    var changes = screen.changes.makeAsyncIterator()

    screen.platformPointerMoved(toX: 10, y: 20)
    let geometry = try screen.currentGeometry().get()

    #expect(geometry.cursorX == 10 && geometry.cursorY == 20)
    #expect(geometry.width == desktop.width && geometry.height == desktop.height)
    await screen.stop()
    #expect(await changes.next() == nil)
  }

  @Test func screenStopIsIdempotentFinishesChangesAndFailsLaterReads() async throws {
    let screen = ReferenceScreen(geometry: desktop)
    var changes = screen.changes.makeAsyncIterator()

    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await screen.stop()
    }.value
    await screen.stop()

    #expect(await changes.next() == nil)
    #expect(failureCode(screen.currentGeometry()) == .lifecycle(.subsystemUnavailable))
  }

  @Test func platformScreenGeometryRoundTripsWithAFrozenCodingShape() throws {
    let extreme = PlatformScreenGeometry(
      originX: Int(Int32.min), originY: -1, width: 1, height: Int(Int32.max),
      cursorX: Int(Int32.min), cursorY: Int(Int32.max))

    for geometry in [desktop, extreme] {
      let encoded = try JSONEncoder().encode(geometry)
      #expect(try JSONDecoder().decode(PlatformScreenGeometry.self, from: encoded) == geometry)
    }
    let fields = try JSONDecoder().decode(
      [String: Int].self, from: JSONEncoder().encode(desktop))
    #expect(
      fields == [
        "originX": 0, "originY": 0, "width": 1600, "height": 900, "cursorX": 800,
        "cursorY": 450,
      ])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        PlatformScreenGeometry.self,
        from: Data(#"{"originX":0,"originY":0,"width":1600,"height":900,"cursorX":800}"#.utf8))
    }
  }

  // MARK: Clipboard

  @Test func theSHA256OracleMatchesTheFIPSExamples() {
    let twoBlocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"

    #expect(
      sha256Hex(Array("abc".utf8))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(sha256Hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(
      sha256Hex(Array(twoBlocks.utf8))
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  }

  @Test func contentHashIsTheLowercaseHexSHA256OfTheUTF8Bytes() async throws {
    let clipboard = ReferenceClipboard()
    let limit = try byteLimit(64)

    try await clipboard.writePlainText("abc", limit: limit).get()
    let abc = try #require(try await clipboard.readPlainText(limit: limit).get())
    await clipboard.foreignCopy(Array(mixedWidthText.utf8))
    let mixed = try #require(try await clipboard.readPlainText(limit: limit).get())

    #expect(abc.contentHash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(mixed.contentHash == sha256Hex(Array(mixedWidthText.utf8)))
    #expect(mixed.contentHash.count == 2 * sha256DigestLength)
    #expect(mixed.contentHash.allSatisfy { "0123456789abcdef".contains($0) })
  }

  @Test func clipboardWritesAndReadsPlainTextWithAHashOfTheTextAlone() async throws {
    let clipboard = ReferenceClipboard()
    let limit = try byteLimit(64)

    try await clipboard.writePlainText(mixedWidthText, limit: limit).get()
    let written = try #require(try await clipboard.readPlainText(limit: limit).get())
    await clipboard.foreignCopy(Array(mixedWidthText.utf8))
    let copied = try #require(try await clipboard.readPlainText(limit: limit).get())
    await clipboard.foreignCopy(Array("other".utf8))
    let other = try #require(try await clipboard.readPlainText(limit: limit).get())

    #expect(written.text == mixedWidthText)
    #expect(copied.text == mixedWidthText)
    #expect(written.contentHash == copied.contentHash)
    #expect(other.contentHash != written.contentHash)
    #expect(!written.contentHash.isEmpty)
    #expect(!written.contentHash.contains(mixedWidthText))
  }

  @Test func clipboardReadsNilWhenItHoldsNoText() async throws {
    let clipboard = ReferenceClipboard()

    #expect(try await clipboard.readPlainText(limit: byteLimit(1)).get() == nil)
    #expect(await clipboard.transferredByteCount == 0)
  }

  @Test func clipboardAcceptsTextExactlyAtTheLimitInBothDirections() async throws {
    let clipboard = ReferenceClipboard()
    let limit = try byteLimit(mixedWidthByteCount)

    try await clipboard.writePlainText(mixedWidthText, limit: limit).get()

    #expect(try await clipboard.readPlainText(limit: limit).get()?.text == mixedWidthText)
    #expect(await clipboard.encodedByteCount == mixedWidthByteCount)
    #expect(await clipboard.transferredByteCount == mixedWidthByteCount)
  }

  @Test func anOversizedReadIsRefusedBeforeAnyContentIsTransferred() async throws {
    let clipboard = ReferenceClipboard()
    let held = Array(mixedWidthText.utf8)
    await clipboard.foreignCopy(held)

    let read = await clipboard.readPlainText(limit: try byteLimit(mixedWidthByteCount - 1))

    #expect(failureCode(read) == .clipboard(.oversized))
    #expect(await clipboard.transferredByteCount == 0)
    #expect(await clipboard.platformContent == held)
  }

  @Test func aReadInPartsWithAnUnderstatedSizeNeverHoldsMoreThanTheLimit() async throws {
    let clipboard = ReferenceClipboard()
    let held = Array(mixedWidthText.utf8)
    await clipboard.foreignCopy(held, statedByteCount: 1, partByteCount: 3)

    let refused = await clipboard.readPlainText(limit: try byteLimit(mixedWidthByteCount - 1))

    #expect(failureCode(refused) == .clipboard(.oversized))
    #expect(await clipboard.largestHeldByteCount <= mixedWidthByteCount - 1)
    #expect(await clipboard.platformContent == held)

    let accepted = try await clipboard.readPlainText(limit: byteLimit(mixedWidthByteCount)).get()
    #expect(accepted?.text == mixedWidthText)
    #expect(await clipboard.largestHeldByteCount == mixedWidthByteCount)
  }

  @Test func anOversizedWriteIsRefusedBeforeAnythingIsEncodedAndChangesNothing() async throws {
    let clipboard = ReferenceClipboard()
    let held = Array("kept".utf8)
    await clipboard.foreignCopy(held)

    let write = await clipboard.writePlainText(
      mixedWidthText, limit: try byteLimit(mixedWidthByteCount - 1))

    #expect(failureCode(write) == .clipboard(.oversized))
    #expect(await clipboard.encodedByteCount == 0)
    #expect(await clipboard.platformContent == held)
  }

  @Test func malformedUTF8IsRejectedAndNeverRepaired() async throws {
    let clipboard = ReferenceClipboard()
    let malformed: [[UInt8]] = [[0xFF], [0xC3, 0x28], [0xED, 0xA0, 0x80], [0x61, 0xF0, 0x9F]]

    for bytes in malformed {
      await clipboard.foreignCopy(bytes)
      let read = await clipboard.readPlainText(limit: try byteLimit(64))
      #expect(failureCode(read) == .clipboard(.invalidUTF8))
    }
  }

  @Test func aReadFromAnOwnerThatNeverAnswersTimesOutAndChangesNothing() async throws {
    let clipboard = ReferenceClipboard()
    let held = Array("kept".utf8)
    await clipboard.foreignCopy(held)
    await clipboard.ownerStopsAnswering()

    let read = await clipboard.readPlainText(limit: try byteLimit(64))

    #expect(failureCode(read) == .timeout(.read))
    #expect(await clipboard.transferredByteCount == 0)
    #expect(await clipboard.platformContent == held)
  }

  @Test func ownerChangesReportOtherApplicationsButNeverOwnWrites() async throws {
    let limit = try byteLimit(64)
    let quiet = ReferenceClipboard()
    var quietChanges = quiet.ownerChanges.makeAsyncIterator()
    let busy = ReferenceClipboard()
    var busyChanges = busy.ownerChanges.makeAsyncIterator()

    try await quiet.writePlainText("ours", limit: limit).get()
    await quiet.stop()
    await busy.foreignCopy(Array("theirs".utf8))

    #expect(await quietChanges.next() == nil)
    #expect(await busyChanges.next() != nil)
  }

  @Test func clipboardCallsFromACancelledTaskFailAndChangeNothing() async throws {
    let clipboard = ReferenceClipboard()
    let held = Array("kept".utf8)
    let limit = try byteLimit(64)
    await clipboard.foreignCopy(held)

    let (read, write) = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let read = await clipboard.readPlainText(limit: limit)
      let write = await clipboard.writePlainText("lost", limit: limit)
      return (read, write)
    }.value

    #expect(failureCode(read) == .cancellation(.requested))
    #expect(failureCode(write) == .cancellation(.requested))
    #expect(await clipboard.platformContent == held)
    #expect(await clipboard.transferredByteCount == 0)
    #expect(await clipboard.encodedByteCount == 0)
  }

  @Test func clipboardStopIsIdempotentFinishesOwnerChangesAndFailsLaterCalls() async throws {
    let clipboard = ReferenceClipboard()
    var changes = clipboard.ownerChanges.makeAsyncIterator()
    let limit = try byteLimit(64)

    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await clipboard.stop()
    }.value
    await clipboard.stop()

    #expect(await changes.next() == nil)
    let read = await clipboard.readPlainText(limit: limit)
    let write = await clipboard.writePlainText("late", limit: limit)
    #expect(failureCode(read) == .lifecycle(.subsystemUnavailable))
    #expect(failureCode(write) == .lifecycle(.subsystemUnavailable))
  }

  @Test func platformClipboardTextNeverRendersItsTextOrHash() {
    let value = PlatformClipboardText(text: probeText, contentHash: probeHash)
    let erased: Any = value
    var dumped = ""
    dump(value, to: &dumped)
    let read: CoreResult<PlatformClipboardText?> = .success(value)
    let renderings = [
      String(describing: value),
      String(reflecting: value),
      "\(value)",
      dumped,
      String(describing: read),
      String(reflecting: [value]),
    ]

    #expect(value.text == probeText)
    #expect(value.contentHash == probeHash)
    #expect(Mirror(reflecting: value).children.isEmpty)
    // Encoding would be another rendering: the value is not Encodable anywhere in the module.
    #expect(!(erased is any Encodable))
    for rendering in renderings {
      #expect(rendering.contains("PlatformClipboardText"))
      #expect(!rendering.contains(probeText))
      #expect(!rendering.contains(probeHash))
      #expect(!rendering.contains("\u{1F600}"))
      #expect(!rendering.contains("\u{6E2C}"))
    }
  }

  // MARK: Secure storage

  @Test func aTrustedFingerprintIsInsertedLoadedAndRemoved() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()

    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    let outcome = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA1), for: server)
      .get()
    #expect(outcome == .inserted)
    #expect(try await store.loadTrustedFingerprint(for: server).get() == fingerprint(0xA1))

    try await store.removeTrustedFingerprint(for: server).get()
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
  }

  @Test func insertNeverReplacesAnExistingRecord() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()
    _ = await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA1), for: server)

    let second = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0xB2), for: server)
      .get()

    #expect(second == .existing(storedFingerprint: fingerprint(0xA1)))
    #expect(try await store.loadTrustedFingerprint(for: server).get() == fingerprint(0xA1))
    #expect(TrustInsertOutcome.inserted != .existing(storedFingerprint: fingerprint(0xA1)))
  }

  @Test func insertRefusesAnythingButA32ByteDigestBeforeStorageWork() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()

    for length in [0, sha256DigestLength - 1, sha256DigestLength + 1, 64] {
      let value = Data(repeating: 0x5A, count: length)
      let outcome = await store.insertTrustedFingerprintIfAbsent(value, for: server)
      #expect(failureCode(outcome) == .security(.trustRejected))
    }
    #expect(await store.storageOperationCount == 0)

    let accepted = try await store.insertTrustedFingerprintIfAbsent(fingerprint(0x5A), for: server)
      .get()
    #expect(accepted == .inserted)
  }

  @Test func loadReturnsStoredBytesUnjudgedAndAStorageFailureIsNeverAMissingRecord()
    async throws
  {
    let store = ReferenceTrustStore()
    let server = try peer()
    let absent = try peer("other.example")
    let malformed = Data([0x01, 0x02, 0x03])
    await store.plant(malformed, for: server)

    #expect(try await store.loadTrustedFingerprint(for: server).get() == malformed)

    await store.makeUnavailable()
    let stored = await store.loadTrustedFingerprint(for: server)
    let missing = await store.loadTrustedFingerprint(for: absent)
    let insert = await store.insertTrustedFingerprintIfAbsent(fingerprint(1), for: absent)
    let remove = await store.removeTrustedFingerprint(for: server)
    #expect(failureCode(stored) == .security(.secureStorageUnavailable))
    #expect(failureCode(missing) == .security(.secureStorageUnavailable))
    #expect(failureCode(insert) == .security(.secureStorageUnavailable))
    #expect(failureCode(remove) == .security(.secureStorageUnavailable))
  }

  @Test func aStoreOthersCouldChangeFailsClosedWithoutTouchingARecord() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()
    _ = await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA1), for: server)
    let operationsBefore = await store.storageOperationCount
    await store.exposeToOtherUsers()

    let load = await store.loadTrustedFingerprint(for: server)
    let insert = await store.insertTrustedFingerprintIfAbsent(
      fingerprint(0xB2), for: try peer("other.example"))
    let remove = await store.removeTrustedFingerprint(for: server)

    #expect(failureCode(load) == .security(.secureStorageUnavailable))
    #expect(failureCode(insert) == .security(.secureStorageUnavailable))
    #expect(failureCode(remove) == .security(.secureStorageUnavailable))
    #expect(await store.storageOperationCount == operationsBefore)
  }

  @Test func removeIsIdempotentAndRunsEvenFromACancelledTask() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()
    _ = await store.insertTrustedFingerprintIfAbsent(fingerprint(0xA1), for: server)

    let removal = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await store.removeTrustedFingerprint(for: server)
    }.value

    #expect(failureCode(removal) == nil)
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
    try await store.removeTrustedFingerprint(for: server).get()
  }

  @Test func loadAndInsertFromACancelledTaskReadAndWriteNothing() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()
    let shortValue = Data(repeating: 1, count: sha256DigestLength - 1)

    let (load, insert, short) = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let load = await store.loadTrustedFingerprint(for: server)
      let insert = await store.insertTrustedFingerprintIfAbsent(fingerprint(1), for: server)
      let short = await store.insertTrustedFingerprintIfAbsent(shortValue, for: server)
      return (load, insert, short)
    }.value

    #expect(failureCode(load) == .cancellation(.requested))
    #expect(failureCode(insert) == .cancellation(.requested))
    // A value of the wrong length is refused first, also from a cancelled task.
    #expect(failureCode(short) == .security(.trustRejected))
    #expect(await store.storageOperationCount == 0)
    #expect(try await store.loadTrustedFingerprint(for: server).get() == nil)
  }

  @Test func concurrentInsertsForOnePeerKeepExactlyOneRecord() async throws {
    let store = ReferenceTrustStore()
    let server = try peer()

    let outcomes = await withTaskGroup(of: (UInt8, TrustInsertOutcome?).self) { group in
      for seed in UInt8(1)...16 {
        group.addTask {
          (
            seed,
            try? await store.insertTrustedFingerprintIfAbsent(fingerprint(seed), for: server)
              .get()
          )
        }
      }
      var outcomes: [(UInt8, TrustInsertOutcome?)] = []
      for await outcome in group {
        outcomes.append(outcome)
      }
      return outcomes
    }

    let winners = outcomes.filter { $0.1 == .inserted }.map(\.0)
    #expect(outcomes.count == 16)
    #expect(winners.count == 1)
    let winner = try #require(winners.first)
    for (_, outcome) in outcomes where outcome != .inserted {
      #expect(outcome == .existing(storedFingerprint: fingerprint(winner)))
    }
    #expect(try await store.loadTrustedFingerprint(for: server).get() == fingerprint(winner))
  }

  // MARK: Peer keys

  @Test func peerKeyNormalizationLowercasesTheHost() async throws {
    let typed = try peer("Server.EXAMPLE")
    let lower = try peer("server.example")

    #expect(typed.rawValue == "server.example:24800")
    #expect(typed == lower)
    #expect(Set([typed, lower]).count == 1)
    #expect(PeerKey(host: "Node:Zone", port: 1)?.rawValue == "node:zone:1")
    #expect(PeerKey(host: "NODE", port: 24_800) != PeerKey(host: "node", port: 24_801))

    let store = ReferenceTrustStore()
    _ = await store.insertTrustedFingerprintIfAbsent(fingerprint(7), for: typed)
    #expect(try await store.loadTrustedFingerprint(for: lower).get() == fingerprint(7))
  }

  @Test func peerKeyRefusesHostsAndPortsThatCannotIdentifyAPeer() throws {
    let refusedHosts = [
      "", " ", "server name.example", "server.example\n", "\tserver.example",
      "server\u{0000}name", "server\u{007F}name", "server\u{00A0}name", "server\u{2028}name",
      "server\u{200B}name", "server\u{202E}eman",
      // Printable ASCII only: no other letter, composed or not, and no invisible character.
      "\u{00C4}.example", "caf\u{00E9}.example", "cafe\u{0301}.example", "\u{3164}",
      "a\u{034F}b", "\u{2800}",
    ]

    for host in refusedHosts {
      #expect(PeerKey(host: host, port: 24_800) == nil)
    }
    #expect(PeerKey(host: "server.example", port: 0) == nil)
    #expect(try peer(port: 1).rawValue == "server.example:1")
    #expect(try peer(port: .max).rawValue == "server.example:65535")
    #expect(try peer("!~").rawValue == "!~:24800")
  }

  @Test func peerKeyParsesARawValueWithTheRulesOfItsInitializer() throws {
    let spellings: [(String, UInt16)] = [
      ("server.example", 24_800), ("node:zone", 1), ("a:1", 2), ("a", 12),
      ("[node:zone]", 65_535),
    ]
    let normalized = try peer()

    for (host, port) in spellings {
      let key = try peer(host, port: port)
      #expect(PeerKey(rawValue: key.rawValue) == key)
    }
    #expect(PeerKey(rawValue: "Server.EXAMPLE:24800") == normalized)
    // A caller tells an already normalized value from one the parser had to normalize.
    #expect(PeerKey(rawValue: "Server.EXAMPLE:24800")?.rawValue != "Server.EXAMPLE:24800")
    for raw in refusedRawValues {
      #expect(PeerKey(rawValue: raw) == nil)
    }
  }

  @Test func peerKeyRoundTripsAndDecodingNormalizesOrRefuses() throws {
    let spellings: [(String, UInt16)] = [
      ("server.example", 24_800), ("node:zone", 1), ("a:1", 2), ("a", 12),
      ("[node:zone]", 65_535),
    ]
    var rawValues: Set<String> = []

    for (host, port) in spellings {
      let key = try peer(host, port: port)
      let encoded = try JSONEncoder().encode(key)
      #expect(
        try JSONDecoder().decode([String: String].self, from: encoded) == ["rawValue": key.rawValue]
      )
      #expect(try JSONDecoder().decode(PeerKey.self, from: encoded) == key)
      rawValues.insert(key.rawValue)
    }
    #expect(rawValues.count == spellings.count)

    let uppercase = Data(#"{"rawValue":"Server.EXAMPLE:24800"}"#.utf8)
    #expect(try JSONDecoder().decode(PeerKey.self, from: uppercase) == peer())

    for raw in refusedRawValues {
      let data = try JSONEncoder().encode(["rawValue": raw])
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PeerKey.self, from: data)
      }
    }
    do {
      _ = try JSONDecoder().decode(PeerKey.self, from: Data(#"{"rawValue":"server-name"}"#.utf8))
      Issue.record("a key without a port must not decode")
    } catch {
      #expect(!String(describing: error).contains("server-name"))
    }
  }

  // MARK: Lifecycle

  @Test func lifecycleSignalsArriveInOrderAndStopFinishesTheStream() async {
    let lifecycle = ReferenceLifecycle()
    var signals = lifecycle.signals.makeAsyncIterator()
    let observed: [LifecycleSignal] = [
      .willSuspend, .didResume, .networkUnavailable, .networkAvailable, .terminationRequested,
    ]

    for signal in observed {
      lifecycle.platformReported(signal)
    }
    lifecycle.stop()
    lifecycle.stop()

    var received: [LifecycleSignal] = []
    while let signal = await signals.next() {
      received.append(signal)
    }
    #expect(received == observed)
    #expect(Set(received.map { frozenName(of: $0) }).count == 5)
  }

  @Test func lifecycleSignalsThatDoNotFitEndTheStreamInsteadOfVanishing() async {
    let lifecycle = ReferenceLifecycle(capacity: 4)
    var signals = lifecycle.signals.makeAsyncIterator()
    let observed: [LifecycleSignal] = [
      .willSuspend, .networkUnavailable, .didResume, .networkAvailable, .terminationRequested,
      .didResume,
    ]

    for signal in observed {
      lifecycle.platformReported(signal)
    }
    lifecycle.stop()

    var received: [LifecycleSignal] = []
    while let signal = await signals.next() {
      received.append(signal)
    }
    // Nothing vanished in the middle: the oldest signals arrived in order, and the stream ended
    // at the first one that did not fit.
    #expect(received == Array(observed.prefix(4)))
  }

  // MARK: Capture

  @Test func captureDeliversLocalInputInCaptureOrderWhileItRuns() async throws {
    let capture = ReferenceCapture(bufferLimit: 8)
    let input: [KVMEvent] = [
      .mouseMove(position: NormalizedPoint(x: 0.25, y: 0.75)),
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .key(key: .letter(0), phase: .up, modifiers: ModifierState()),
    ]

    capture.platformCaptured(input[0])
    try capture.start()
    #expect(capture.suppressesLocalInput)
    for event in input {
      capture.platformCaptured(event)
    }
    capture.stop()

    var received: [KVMEvent] = []
    for await event in capture.events {
      received.append(event)
    }
    #expect(received == input)
    #expect(!capture.suppressesLocalInput)
  }

  @Test func captureStartFailsClosedWhenRefusedAndAnInstanceIsSingleUse() async throws {
    let refused = ReferenceCapture(bufferLimit: 8, platformPermitsCapture: false)
    var refusedEvents = refused.events.makeAsyncIterator()

    do {
      try refused.start()
      Issue.record("a refused start must fail")
    } catch {
      #expect(error.code == .permission(.capabilityUnavailable))
    }
    #expect(!refused.suppressesLocalInput)
    #expect(await refusedEvents.next() == nil)

    let used = ReferenceCapture(bufferLimit: 8)
    try used.start()
    for instance in [refused, used] {
      do {
        try instance.start()
        Issue.record("a second start must fail")
      } catch {
        #expect(error.code == .internalFailure(.preconditionFailed))
      }
    }
    used.stop()
    do {
      try used.start()
      Issue.record("a start after stop must fail")
    } catch {
      #expect(error.code == .internalFailure(.preconditionFailed))
    }
  }

  @Test func captureStopEndsSuppressionIsIdempotentAndWorksBeforeStart() async throws {
    let neverStarted = ReferenceCapture(bufferLimit: 8)
    neverStarted.stop()
    neverStarted.stop()
    var neverStartedEvents = neverStarted.events.makeAsyncIterator()
    #expect(await neverStartedEvents.next() == nil)

    let capture = ReferenceCapture(bufferLimit: 8)
    let press = KVMEvent.key(key: .escape, phase: .down, modifiers: ModifierState())
    try capture.start()
    capture.platformCaptured(press)
    capture.stop()
    capture.stop()

    #expect(!capture.suppressesLocalInput)
    var received: [KVMEvent] = []
    for await event in capture.events {
      received.append(event)
    }
    #expect(received == [press])
  }

  @Test func captureMayDropAPointerMoveThatDoesNotFitAndKeepsCapturing() async throws {
    let capture = ReferenceCapture(bufferLimit: 2)
    var events = capture.events.makeAsyncIterator()
    let moves = (0..<3).map { index in
      KVMEvent.mouseMove(position: NormalizedPoint(x: Double(index) / 4, y: 0))
    }
    let press = KVMEvent.key(key: .letter(1), phase: .down, modifiers: ModifierState())
    try capture.start()

    for move in moves {
      capture.platformCaptured(move)
    }

    #expect(capture.suppressesLocalInput)
    #expect(await events.next() == moves[0])
    #expect(await events.next() == moves[1])
    capture.platformCaptured(press)
    capture.stop()
    #expect(await events.next() == press)
    #expect(await events.next() == nil)
  }

  @Test func captureNeverDropsAKeyOrButtonAndEndsTheStreamWhenOneDoesNotFit() async throws {
    let capture = ReferenceCapture(bufferLimit: 2)
    let input: [KVMEvent] = [
      .key(key: .letter(0), phase: .down, modifiers: ModifierState()),
      .mouseButton(button: .left, phase: .down),
      .key(key: .letter(0), phase: .up, modifiers: ModifierState()),
      .mouseButton(button: .left, phase: .up),
    ]
    try capture.start()

    for event in input {
      capture.platformCaptured(event)
    }

    #expect(!capture.suppressesLocalInput)
    var received: [KVMEvent] = []
    for await event in capture.events {
      received.append(event)
    }
    #expect(received == Array(input.prefix(2)))
  }

  // MARK: Public surface and production source

  @Test func publicSurfaceIsExactlyTheC015Inventory() throws {
    let lines = try productionSourceLines()

    #expect(publicSurface(of: lines) == frozenPublicSurface)
  }

  @Test func productionSourceImportsOnlyFoundationAndHoldsNoPlatformOrLoggingCode() throws {
    let code = try productionSourceLines().map(codeText(of:)).filter { !$0.isEmpty }

    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import Foundation"])
    let forbidden = [
      "print(", "debugPrint(", "NSLog", "Logger", "os_log", "dump(", "fputs(", "FileHandle",
      "fatalError(", "precondition(", "preconditionFailure(", "assert(", "assertionFailure(",
      "@unchecked", "nonisolated(unsafe)", "static var", "#if os", "#if canImport",
    ]
    #expect(mentions("print(", in: "print(x)") && mentions("print(", in: "a; print(x)"))
    #expect(!mentions("print(", in: "func loadTrustedFingerprint(for peer: PeerKey)"))
    for word in forbidden {
      #expect(!code.contains { mentions(word, in: $0) }, "production code mentions \(word)")
    }
  }
}

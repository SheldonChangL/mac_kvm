import Foundation
import KVMContracts
import LinuxPlatform

// M4-020-FOLLOWUP-001: what `mackvm-client` prints.
//
// - Status lines use a closed vocabulary (`ClientStatus`): fixed text, plus at most a count or a
//   frozen error code. No host, port, screen name, address, key, button, position, clipboard
//   text or fingerprint ever reaches one (Frozen Decision 8).
// - The deliberate trust outputs (`ClientTrustText`) show fingerprints on purpose, as the Mac
//   app's `fingerprint` command does (plan a.7). The connect-time instructions never name the
//   host; only `fingerprint show` echoes the server the person typed.

/// One status line. Every case is fixed text; associated values are counts or frozen codes.
enum ClientStatus: Equatable, Sendable {
  case starting
  case connecting
  case connected
  case screenActive
  case screenInactive
  case connectionEnded(CoreErrorCode?)
  case waitingToReconnect(seconds: Int)
  case resumed
  case networkAvailable(Bool)
  case cleanup(CleanupDisposition)
  case injectionFailed(CoreErrorCode)
  case displayLost
  case stopping(signal: Int32)
  case stopped(CoreErrorCode)
  case trustStoreUnavailable

  var text: String {
    switch self {
    case .starting: "starting"
    case .connecting: "connecting to the server"
    case .connected: "connected"
    case .screenActive: "input is on this screen"
    case .screenInactive: "input left this screen"
    case .connectionEnded(let code): "connection ended" + Self.suffix(code)
    case .waitingToReconnect(let seconds): "reconnecting in \(seconds) s"
    case .resumed: "the system resumed; reconnecting"
    case .networkAvailable(let available):
      available ? "the network is available" : "the network is unavailable"
    case .cleanup(let disposition): "released held input: \(disposition.rawValue)"
    case .injectionFailed(let code): "input injection failed" + Self.suffix(code)
    case .displayLost: "the X display was lost; exiting"
    case .stopping(let signal): "stopping on signal \(signal)"
    case .stopped(let code): "stopped" + Self.suffix(code)
    case .trustStoreUnavailable:
      "the trust store is unusable: its directory must be a private 0700 directory owned by you"
        + " below an existing configuration directory"
    }
  }

  private static func suffix(_ code: CoreErrorCode?) -> String {
    guard let code else { return "" }
    return " (" + ClientReport.name(of: code) + ")"
  }
}

/// Where status lines and trust text go; tests record them.
protocol ClientOutput: Sendable {
  func status(_ status: ClientStatus)
  /// A deliberate, multi-line message to the person (trust prompts and `fingerprint` output).
  func message(_ text: String)
  /// A usage or startup error.
  func error(_ text: String)
}

/// Standard output and standard error, written on one serial queue so a slow terminal never
/// stalls a caller holding a lock.
final class ClientStandardOutput: ClientOutput, @unchecked Sendable {
  private let queue = DispatchQueue(label: "mackvm.report")

  func status(_ status: ClientStatus) {
    let text = status.text
    let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    queue.async {
      FileHandle.standardOutput.write(Data("[\(stamp)] \(text)\n".utf8))
    }
  }

  func message(_ text: String) {
    queue.async {
      FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
  }

  func error(_ text: String) {
    queue.async {
      FileHandle.standardError.write(Data((text + "\n").utf8))
    }
  }

  /// Waits until every queued line is written.
  func flush() {
    queue.sync {}
  }
}

enum ClientReport {
  /// The frozen name of an error code, for example `security.identityUnknown`.
  static func name(of code: CoreErrorCode) -> String {
    switch code {
    case .cancellation(let value): "cancellation." + value.rawValue
    case .timeout(let value): "timeout." + value.rawValue
    case .transport(let value): "transport." + value.rawValue
    case .protocolViolation(let value): "protocol." + value.rawValue
    case .security(let value): "security." + value.rawValue
    case .permission(let value): "permission." + value.rawValue
    case .inputSafety(let value): "inputSafety." + value.rawValue
    case .clipboard(let value): "clipboard." + value.rawValue
    case .lifecycle(let value): "lifecycle." + value.rawValue
    case .internalFailure(let value): "internal." + value.rawValue
    }
  }
}

/// The deliberate trust texts (plan a.7). Fingerprints appear here on purpose; hosts do not,
/// except in `fingerprintShow`, which echoes what the person typed.
enum ClientTrustText {
  /// The command a person runs to trust a server; the server stays a placeholder.
  static func trustCommand(hex: String) -> String {
    "mackvm-client fingerprint trust <host>[:port] \(hex)"
  }

  /// Non-interactive first use: what to compare and what to run. No host.
  static func unknownInstructions(presented: Data) -> String {
    let display = LinuxFingerprintText.canonicalDisplay(of: presented) ?? "(unavailable)"
    let hex = LinuxFingerprintText.lowercaseHex(of: presented) ?? ""
    return """
      The server presented a certificate this client does not trust yet.
      SHA-256: \(display)
      Compare it with the output of `MacKVM fingerprint` on the Mac. If they match, trust it
      with the same server you passed to connect, then start the client again:
        \(trustCommand(hex: hex))
      """
  }

  /// Interactive first use: the question. No host.
  static func unknownPrompt(presented: Data) -> String {
    let display = LinuxFingerprintText.canonicalDisplay(of: presented) ?? "(unavailable)"
    return """
      The server presented a certificate this client does not trust yet.
      SHA-256: \(display)
      Compare it with the output of `MacKVM fingerprint` on the Mac.
      Type trust and press Return to trust it; anything else stops.
      """
  }

  /// A trusted server presented a different certificate: both shown, nothing stored. No host.
  static func changedWarning(_ warning: LinuxFingerprintChangeWarning) -> String {
    """
    WARNING: the server presented a different certificate than the one this client trusts.
    The connection was refused and nothing was changed.
    Trusted SHA-256:   \(warning.trustedFingerprintDisplay)
    Presented SHA-256: \(warning.presentedFingerprintDisplay)
    If the Mac's identity was renewed on purpose (`MacKVM fingerprint` shows the new value),
    run `mackvm-client fingerprint forget <host>[:port]` and trust the new value.
    """
  }

  static let rejected = "The server's certificate was rejected; nothing was stored."
  static let notTrusted = "Not trusted; nothing was stored."
  static let rootUnsupported =
    "mackvm-client does not run as root: the trust store accepts only the running user's files."

  /// `fingerprint show`.
  static func show(server: ClientServerAddress, presented: Data?, trusted: Data?) -> String {
    let presentedText = presented.flatMap(LinuxFingerprintText.canonicalDisplay(of:)) ?? "none"
    let trustedText = trusted.flatMap(LinuxFingerprintText.canonicalDisplay(of:)) ?? "none"
    return """
      server: \(server.peerKey.rawValue)
      presented SHA-256: \(presentedText)
      trusted SHA-256:   \(trustedText)
      """
  }
}

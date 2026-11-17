import Foundation
import KVMContracts
import LinuxPlatform

// M4-020-FOLLOWUP-001: the command line of `mackvm-client` (plan b.16), in the shape of the Mac
// app's parser. Nothing here is persisted and nothing is logged.

/// The process exit codes (sysexits.h values; plan b.16). systemd's `RestartPreventExitStatus`
/// names 64, 69 and 78, so none of them restart-loops.
enum ClientExitCode: Int32, Equatable, Sendable {
  case success = 0
  /// Any failure no other code names.
  case failure = 1
  /// The command line is wrong (`EX_USAGE`).
  case usage = 64
  /// No X11 display, no XTest, or the display was lost (`EX_UNAVAILABLE`).
  case unavailable = 69
  /// A trust decision is needed: unknown or changed server identity, or an unusable trust
  /// store (`EX_CONFIG`).
  case trustDecisionNeeded = 78
}

/// A server named on the command line: `host`, `host:port`, `[ipv6]` or `[ipv6]:port`.
struct ClientServerAddress: Equatable, Sendable {
  static let defaultPort: UInt16 = 24_800

  let host: String
  let port: UInt16
  /// The trust store's key for this server.
  let peerKey: PeerKey

  /// `nil` unless the text names a host and an optional port in `1...65535`.
  init?(_ text: String) {
    let host: Substring
    var portText: Substring?
    if text.hasPrefix("[") {
      guard let close = text.firstIndex(of: "]") else { return nil }
      host = text[text.index(after: text.startIndex)..<close]
      let rest = text[text.index(after: close)...]
      if !rest.isEmpty {
        guard rest.hasPrefix(":") else { return nil }
        portText = rest.dropFirst()
      }
    } else if let colon = text.firstIndex(of: ":") {
      // A second colon means a bare IPv6 address, which must be bracketed.
      guard text[text.index(after: colon)...].firstIndex(of: ":") == nil else { return nil }
      host = text[..<colon]
      portText = text[text.index(after: colon)...]
    } else {
      host = Substring(text)
    }
    var port = Self.defaultPort
    if let portText {
      guard let value = Self.port(portText) else { return nil }
      port = value
    }
    guard !host.isEmpty, host.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }),
      !host.contains("["), !host.contains("]"), !host.contains("/"),
      let key = PeerKey(host: String(host), port: port)
    else { return nil }
    self.host = String(host)
    self.port = port
    peerKey = key
  }

  private static func port(_ text: Substring) -> UInt16? {
    guard let first = text.first, first != "0", text.utf8.count <= 5,
      text.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
      let value = UInt16(text), value != 0
    else { return nil }
    return value
  }
}

/// Options of `mackvm-client connect`.
struct ClientConnectOptions: Equatable, Sendable {
  var server: ClientServerAddress
  /// The Barrier screen name; must equal the Mac's `--client`.
  var screenName: String
  /// `--display`, or `nil` for `DISPLAY`.
  var displayName: String?
  /// `--non-interactive`: never prompt; print instructions and exit 78 instead.
  var nonInteractive = false
}

/// What the command line asks for.
enum ClientCommand: Equatable, Sendable {
  case connect(ClientConnectOptions)
  /// Connect once, show the presented and the trusted fingerprint, send nothing.
  case fingerprintShow(ClientServerAddress)
  /// Trust a 32-byte SHA-256 fingerprint for the server, never replacing another.
  case fingerprintTrust(ClientServerAddress, Data)
  /// Remove the server's trusted fingerprint.
  case fingerprintForget(ClientServerAddress)
}

enum ClientConfiguration {
  static let usage = """
    usage: mackvm-client connect <host>[:port] --name <screen-name> [--display <:n>]
                                 [--non-interactive]
           mackvm-client fingerprint show <host>[:port]
           mackvm-client fingerprint trust <host>[:port] <sha256>
           mackvm-client fingerprint forget <host>[:port]
    The default port is 24800. The screen name is 1 to 64 of [A-Za-z0-9_-] and must equal
    the Mac's --client. <sha256> is AA:BB:... or 64 hex digits. Running as root is not
    supported.
    """

  /// A Barrier screen name the Mac server accepts: 1...64 of `[A-Za-z0-9_-]`.
  static func isScreenName(_ name: String) -> Bool {
    (1...64).contains(name.utf8.count)
      && name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
  }

  /// An X11 display name of the form `[host]:n[.screen]`.
  static func isDisplayName(_ name: String) -> Bool {
    guard let colon = name.lastIndex(of: ":") else { return false }
    let host = name[..<colon]
    let rest = name[name.index(after: colon)...]
    let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 5 && $0.allSatisfy(\.isASCIIDigit) })
    else { return false }
    return host.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        || $0 == "-" || $0 == "."
    }
  }

  /// A SHA-256 fingerprint as `AA:BB:…` (32 colon-separated pairs) or 64 hex digits, either
  /// case; `nil` otherwise.
  static func fingerprint(_ text: String) -> Data? {
    let hex: String
    if text.contains(":") {
      let pairs = text.split(separator: ":", omittingEmptySubsequences: false)
      guard pairs.count == LinuxFingerprintText.sha256DigestLength,
        pairs.allSatisfy({ $0.utf8.count == 2 })
      else { return nil }
      hex = pairs.joined()
    } else {
      hex = text
    }
    guard hex.utf8.count == 2 * LinuxFingerprintText.sha256DigestLength else { return nil }
    return LinuxFingerprintText.digest(fromLowercaseHex: hex.lowercased())
  }

  /// Parses `arguments` without the executable name; `nil` means a usage error.
  static func parse(_ arguments: [String]) -> ClientCommand? {
    var remaining = arguments[...]
    switch remaining.popFirst() {
    case "connect":
      return parseConnect(&remaining)
    case "fingerprint":
      return parseFingerprint(&remaining)
    default:
      return nil
    }
  }

  private static func parseConnect(_ remaining: inout ArraySlice<String>) -> ClientCommand? {
    guard let serverText = remaining.popFirst(), !serverText.hasPrefix("-"),
      let server = ClientServerAddress(serverText)
    else { return nil }
    var name: String?
    var display: String?
    var nonInteractive = false
    while let option = remaining.popFirst() {
      switch option {
      case "--name":
        guard name == nil, let value = remaining.popFirst(), isScreenName(value) else {
          return nil
        }
        name = value
      case "--display":
        guard display == nil, let value = remaining.popFirst(), isDisplayName(value) else {
          return nil
        }
        display = value
      case "--non-interactive":
        guard !nonInteractive else { return nil }
        nonInteractive = true
      default:
        return nil
      }
    }
    guard let name else { return nil }
    return .connect(
      ClientConnectOptions(
        server: server, screenName: name, displayName: display, nonInteractive: nonInteractive))
  }

  private static func parseFingerprint(_ remaining: inout ArraySlice<String>) -> ClientCommand? {
    guard let action = remaining.popFirst(), let serverText = remaining.popFirst(),
      let server = ClientServerAddress(serverText)
    else { return nil }
    let command: ClientCommand
    switch action {
    case "show":
      command = .fingerprintShow(server)
    case "forget":
      command = .fingerprintForget(server)
    case "trust":
      guard let text = remaining.popFirst(), let digest = fingerprint(text) else { return nil }
      command = .fingerprintTrust(server, digest)
    default:
      return nil
    }
    return remaining.isEmpty ? command : nil
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}

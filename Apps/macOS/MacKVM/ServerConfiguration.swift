import KVMContracts
import MacPlatform

/// Command-line configuration of the server role. Nothing here is persisted.
struct ServerConfiguration: Equatable {
  enum Command: Equatable {
    /// Run the Barrier server with the event tap.
    case serve
    /// Print the server certificate fingerprint, creating the identity first.
    case fingerprint
    /// Delete the server identity; clients must trust the next one again.
    case forgetIdentity
    #if DEBUG
      /// Run the server without an event tap, driven by stdin commands.
      case smoke
    #endif
  }

  static let defaultPort: UInt16 = 24_800
  static let usage = """
    usage: MacKVM serve --client <screen-name> [--edge right|left|top|bottom]
                        [--port <port>] [--loopback-only]
           MacKVM fingerprint
           MacKVM forget-identity
    """

  var command: Command
  var clientName = ""
  var edge = ScreenEdge.right
  var port = defaultPort
  var scope = MacTLSServerListenerScope.anyInterface
  var identityLabel = MacServerIdentityStore.productionLabel

  /// A Barrier screen name the server accepts: 1...64 of `[A-Za-z0-9_-]`.
  static func isScreenName(_ name: String) -> Bool {
    (1...64).contains(name.utf8.count)
      && name.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      }
  }

  /// Parses `arguments` without the executable name; `nil` means usage error.
  static func parse(_ arguments: [String]) -> ServerConfiguration? {
    guard let first = arguments.first else { return nil }
    var configuration: ServerConfiguration
    switch first {
    case "serve": configuration = ServerConfiguration(command: .serve)
    case "fingerprint": configuration = ServerConfiguration(command: .fingerprint)
    case "forget-identity": configuration = ServerConfiguration(command: .forgetIdentity)
    #if DEBUG
      case "smoke": configuration = ServerConfiguration(command: .smoke)
    #endif
    default: return nil
    }
    var remaining = arguments.dropFirst()
    while let option = remaining.popFirst() {
      switch option {
      case "--client":
        guard let value = remaining.popFirst() else { return nil }
        configuration.clientName = value
      case "--edge":
        guard let value = remaining.popFirst(), let edge = ScreenEdge(rawValue: value) else {
          return nil
        }
        configuration.edge = edge
      case "--port":
        guard let value = remaining.popFirst(), let port = UInt16(value), port != 0 else {
          return nil
        }
        configuration.port = port
      case "--loopback-only":
        configuration.scope = .loopback
      #if DEBUG
        case "--identity-label":
          guard let value = remaining.popFirst(), !value.isEmpty else { return nil }
          configuration.identityLabel = value
      #endif
      default:
        return nil
      }
    }
    switch configuration.command {
    case .serve:
      return isScreenName(configuration.clientName) ? configuration : nil
    #if DEBUG
      case .smoke:
        return isScreenName(configuration.clientName) ? configuration : nil
    #endif
    case .fingerprint, .forgetIdentity:
      return configuration
    }
  }
}

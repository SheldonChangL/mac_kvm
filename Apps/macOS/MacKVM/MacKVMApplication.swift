import AppKit
import BarrierCompatibility
import CoreGraphics
import Foundation
import KVMContracts
import KVMCore
import MacPlatform

@main
struct MacKVMApplication {
  static func main() {
    guard let configuration = ServerConfiguration.parse(Array(CommandLine.arguments.dropFirst()))
    else {
      print(ServerConfiguration.usage)
      exit(64)
    }
    let store = MacServerIdentityStore(label: configuration.identityLabel)
    switch configuration.command {
    case .forgetIdentity:
      do {
        try store.remove()
        report("server identity removed; clients must trust the next one")
        exit(0)
      } catch {
        report("could not remove the server identity: \(error)")
        exit(1)
      }
    case .fingerprint:
      reportFingerprint(loadIdentity(store))
      exit(0)
    case .serve:
      serve(configuration, store: store)
    #if DEBUG
      case .smoke:
        SmokeDriver.run(configuration, identity: loadIdentity(store))
    #endif
    }
  }

  private static func serve(_ configuration: ServerConfiguration, store: MacServerIdentityStore)
    -> Never
  {
    let permissions = EventTapPermissionService()
    guard permissions.preflight() == .ready else {
      _ = permissions.requestMissingAccess()
      report("Input Monitoring and Accessibility are required for the event tap; grant them and retry")
      exit(77)
    }
    guard let desktop = MacDesktop.bounds(), let mouse = MacMouseCapture(bounds: desktop) else {
      report("no usable display")
      exit(1)
    }
    let identity = loadIdentity(store)
    reportFingerprint(identity)

    let suppressor = LocalEventSuppressor(
      filter: .live(), isEmergencyEscape: { EmergencyEscape.isChordKey($0) })
    guard
      let runtime = ServerRuntime(
        configuration: configuration, identity: identity, desktop: desktop,
        suppressor: suppressor, cursor: CursorRestorer())
    else { exit(1) }
    let input = InputTap(
      coordinator: runtime.coordinator, effects: runtime.effects, suppressor: suppressor,
      mouse: mouse)
    let tap = MacEventTap { type, event in input.handle(type, event) }
    guard let lifecycle = EventTapLifecycle(control: MacEventTapControl(tap: tap), restartBudget: 10)
    else { exit(1) }
    input.attach(lifecycle)
    do {
      try lifecycle.start()
    } catch {
      report("the event tap could not be created: \(error.code)")
      exit(77)
    }

    let stop: @Sendable (InputLifecycleTrigger) -> Void = { trigger in
      Task {
        await runtime.shutdown(trigger)
        lifecycle.terminate()
        report("stopped; input is local")
        exit(0)
      }
    }
    let signals = installSignalHandlers(stop)
    let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { _ in
      runtime.coordinator.dispatch(.lifecycle(.sleep))
      report("system sleep: input is local")
    }
    Task {
      do throws(CoreError) {
        try await runtime.start()
        report("move the pointer across the \(configuration.edge.rawValue) edge to control the client")
        report("Control+Option+Command+Delete returns input to this Mac at any time")
      } catch {
        report("could not listen: \(error.code)")
        lifecycle.terminate()
        exit(69)
      }
    }
    withExtendedLifetime((signals, sleepObserver, tap, input, runtime, lifecycle)) {
      CFRunLoopRun()
    }
    exit(0)
  }

  static func loadIdentity(_ store: MacServerIdentityStore) -> MacServerIdentity {
    do {
      return try store.loadOrCreate()
    } catch {
      report("the server identity is unavailable: \(error)")
      exit(1)
    }
  }

  static func reportFingerprint(_ identity: MacServerIdentity) {
    let digest = [UInt8](identity.certificateSHA256)
    report(
      "server certificate SHA-256: "
        + digest.map { String(format: "%02X", $0) }.joined(separator: ":"))
    if let line = BarrierTrustedServerEntry.line(sha256: digest) {
      report("Barrier client trust line (SSL/Fingerprints/TrustedServers.txt): \(line)")
    }
  }

  /// SIGINT and SIGTERM stop the server through the lifecycle path.
  static func installSignalHandlers(_ stop: @escaping @Sendable (InputLifecycleTrigger) -> Void)
    -> [any DispatchSourceSignal]
  {
    [SIGINT, SIGTERM].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { stop(.termination) }
      source.resume()
      return source
    }
  }
}

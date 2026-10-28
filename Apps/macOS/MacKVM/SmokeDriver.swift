#if DEBUG
  import CoreGraphics
  import Foundation
  import KVMContracts
  import KVMCore
  import MacPlatform

  /// DEBUG-only server run without an event tap. Commands on standard input
  /// stand in for captured input and go through the same coordinator, outbox
  /// and session path as real input; the local cursor and local input are
  /// never touched. Release builds do not contain it.
  ///
  ///   edge | move <dx> <dy> | key <name> down|up|repeat
  ///   button left|right|middle down|up | scroll <dx> <dy> | escape | state
  ///   pause <ms> | quit
  enum SmokeDriver {
    static func run(_ configuration: ServerConfiguration, identity: MacServerIdentity) -> Never {
      let desktop = MacDesktop.bounds() ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
      MacKVMApplication.reportFingerprint(identity)
      guard
        let runtime = ServerRuntime(
          configuration: configuration, identity: identity, desktop: desktop, suppressor: nil,
          cursor: nil, inputCapturable: { true })
      else { exit(1) }
      Task {
        do throws(CoreError) {
          try await runtime.start()
        } catch {
          report("could not listen: \(error.code)")
          exit(69)
        }
      }
      let reader = Thread {
        var modifiers = ModifierState()
        while let line = readLine() {
          let words = line.split(separator: " ").map(String.init)
          guard !words.isEmpty else { continue }
          if words == ["quit"] { break }
          execute(words, runtime: runtime, edge: configuration.edge, modifiers: &modifiers)
        }
        Task {
          await runtime.shutdown(.termination)
          report("stopped")
          flushReports()
          exit(0)
        }
      }
      reader.start()
      withExtendedLifetime((runtime, reader)) { CFRunLoopRun() }
      exit(0)
    }

    private static func execute(
      _ words: [String], runtime: ServerRuntime, edge: ScreenEdge, modifiers: inout ModifierState
    ) {
      let coordinator = runtime.coordinator
      switch words[0] {
      case "edge":
        // Approach from the middle, as a real pointer does; an edge disarmed by
        // a forced return re-arms only once the pointer was away from it.
        let position = edgePosition(edge)
        coordinator.observeLocal(
          .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)), at: uptime())
        coordinator.observeLocal(.mouseMove(position: position), at: uptime())
        Thread.sleep(forTimeInterval: 0.08)
        coordinator.observeLocal(.mouseMove(position: position), at: uptime())
      case "move" where words.count == 3:
        guard let dx = Double(words[1]), let dy = Double(words[2]) else { break }
        if !coordinator.moveRemote(deltaX: dx, deltaY: dy) { report("smoke: not remote") }
      case "key" where words.count == 3:
        guard let key = virtualKey(words[1]), let phase = keyPhase(words[2]) else { break }
        update(&modifiers, key: key, phase: phase)
        _ = coordinator.handleSuppressed(.key(key: key, phase: phase, modifiers: modifiers))
      case "button" where words.count == 3:
        guard let button = mouseButton(words[1]), let phase = buttonPhase(words[2]) else { break }
        _ = coordinator.handleSuppressed(.mouseButton(button: button, phase: phase))
      case "scroll" where words.count == 3:
        guard let dx = Int32(words[1]), let dy = Int32(words[2]) else { break }
        _ = coordinator.handleSuppressed(.scroll(deltaX: dx, deltaY: dy))
      case "escape":
        coordinator.dispatch(.emergencyEscape)
      case "state":
        report("smoke: state \(coordinator.state)")
      case "pause" where words.count == 2:
        if let milliseconds = Double(words[1]) {
          Thread.sleep(forTimeInterval: milliseconds / 1000)
        }
      default:
        report("smoke: unknown command")
      }
    }

    private static func edgePosition(_ edge: ScreenEdge) -> NormalizedPoint {
      switch edge {
      case .right: NormalizedPoint(x: 1, y: 0.5)
      case .left: NormalizedPoint(x: 0, y: 0.5)
      case .top: NormalizedPoint(x: 0.5, y: 0)
      case .bottom: NormalizedPoint(x: 0.5, y: 1)
      }
    }

    private static func update(_ state: inout ModifierState, key: VirtualKey, phase: KeyPhase) {
      guard phase != .repeatKey else { return }
      let down = phase == .down
      switch key {
      case .shift: state.shift = down
      case .control: state.control = down
      case .option: state.option = down
      case .command: state.command = down
      default: break
      }
    }

    private static func virtualKey(_ name: String) -> VirtualKey? {
      let scalars = Array(name.unicodeScalars)
      if scalars.count == 1, let value = scalars.first?.value {
        if (97...122).contains(value) { return .letter(UInt8(value - 97)) }
        if (48...57).contains(value) { return .digit(UInt8(value - 48)) }
      }
      if name.hasPrefix("f"), let number = UInt8(name.dropFirst()), (1...12).contains(number) {
        return .function(number)
      }
      let named: [String: VirtualKey] = [
        "return": .enter, "escape": .escape, "tab": .tab, "space": .space,
        "backspace": .backspace, "delete": .delete, "left": .left, "right": .right, "up": .up,
        "down": .down, "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
        "shift": .shift, "control": .control, "option": .option, "command": .command,
        "capslock": .capsLock,
      ]
      return named[name]
    }

    private static func keyPhase(_ name: String) -> KeyPhase? {
      ["down": .down, "up": .up, "repeat": .repeatKey][name]
    }

    private static func mouseButton(_ name: String) -> MouseButton? {
      ["left": .left, "right": .right, "middle": .middle][name]
    }

    private static func buttonPhase(_ name: String) -> ButtonPhase? {
      ["down": .down, "up": .up][name]
    }
  }
#endif

import CX11
import Foundation
import KVMContracts
import LinuxPlatform
import Testing

// M4-024 tests. The pure and in-memory suites run everywhere on Linux; the `.x11` suite runs
// under Xvfb in `make verify-linux` and reads what the X server delivers to its own window on a
// second connection.

// MARK: - Helpers

/// Xlib's thread support, enabled once before the first Xlib call of the test process, as the
/// composition root does in production (plan a.3). Suites run in parallel, and Xlib without it
/// is not safe to use from several threads, even on separate connections.
private let xlibThreadsEnabled: Bool = XInitThreads() != 0

/// Every C-005 member for one representative payload, plus the full letter, digit, function and
/// punctuation domains. The switch in `expectedKeySym` is exhaustive with no `default`, so a new
/// catalog member fails to compile here until it is mapped.
private let catalog: [VirtualKey] = {
  var members: [VirtualKey] = (0...25).map { VirtualKey.letter(UInt8($0)) }
  members += (0...9).map { VirtualKey.digit(UInt8($0)) }
  members += (1...24).map { VirtualKey.function(UInt8($0)) }
  members += PunctuationKey.allCases.map { VirtualKey.punctuation($0) }
  let named: [VirtualKey] = [
    .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
    .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp, .volumeDown,
    .mute,
  ]
  members += named
  return members
}()

/// The oracle: X11 public keysym values (keysymdef.h, XF86keysym.h).
private func expectedKeySym(_ key: VirtualKey) -> KeySym? {
  switch key {
  case .letter(let n): n <= 25 ? 0x61 + KeySym(n) : nil
  case .digit(let n): n <= 9 ? 0x30 + KeySym(n) : nil
  case .function(let n): (1...24).contains(n) ? 0xFFBD + KeySym(n) : nil
  case .punctuation(let p):
    [0x2D, 0x3D, 0x5B, 0x5D, 0x5C, 0x3B, 0x27, 0x60, 0x2C, 0x2E, 0x2F][Int(p.rawValue)]
  case .enter: 0xFF0D
  case .escape: 0xFF1B
  case .tab: 0xFF09
  case .space: 0x20
  case .backspace: 0xFF08
  case .delete: 0xFFFF
  case .left: 0xFF51
  case .right: 0xFF53
  case .up: 0xFF52
  case .down: 0xFF54
  case .home: 0xFF50
  case .end: 0xFF57
  case .pageUp: 0xFF55
  case .pageDown: 0xFF56
  case .shift: 0xFFE1
  case .control: 0xFFE3
  case .option: 0xFFE9
  case .command: 0xFFEB
  case .capsLock: 0xFFE5
  case .volumeUp: 0x1008_FF13
  case .volumeDown: 0x1008_FF11
  case .mute: 0x1008_FF12
  case .unknown: nil
  }
}

private let noModifiers = ModifierState()

private func key(_ key: VirtualKey, _ phase: KeyPhase) -> KVMEvent {
  .key(key: key, phase: phase, modifiers: noModifiers)
}

private let screen1600x900: @Sendable () -> PlatformScreenGeometry = {
  PlatformScreenGeometry(originX: 0, originY: 0, width: 1600, height: 900, cursorX: 0, cursorY: 0)
}

/// What the in-memory X server received.
private enum PortCall: Equatable {
  case key(UInt8, down: Bool)
  case button(UInt32, down: Bool)
  case motion(Int32, Int32)
  case flush
  case sync
  case close
}

/// An in-memory `LinuxX11InputPort` with a changeable keymap and a failure switch.
private final class FakePort: LinuxX11InputPort, @unchecked Sendable {
  private let lock = NSLock()
  private var keymap: [KeySym: UInt8] = [:]
  private var storedCalls: [PortCall] = []
  private var failing = false
  private var failingKeyCodes: Set<UInt8> = []
  let buttons: Int

  init(buttons: Int = 9) { self.buttons = buttons }

  var calls: [PortCall] { lock.withLock { storedCalls } }
  var inputCalls: [PortCall] {
    calls.filter { if case .flush = $0 { false } else if case .sync = $0 { false } else { true } }
  }

  /// Key codes and buttons the server holds after every call so far.
  var heldKeyCodes: Set<UInt8> {
    var held: Set<UInt8> = []
    for case .key(let code, let down) in calls {
      if down { held.insert(code) } else { held.remove(code) }
    }
    return held
  }

  var heldButtons: Set<UInt32> {
    var held: Set<UInt32> = []
    for case .button(let code, let down) in calls {
      if down { held.insert(code) } else { held.remove(code) }
    }
    return held
  }

  func remap(_ keysym: KeySym, to code: UInt8) { lock.withLock { keymap[keysym] = code } }
  func setFailing(_ value: Bool) { lock.withLock { failing = value } }
  func failKeyCode(_ code: UInt8, _ value: Bool) {
    lock.withLock {
      if value { _ = failingKeyCodes.insert(code) } else { _ = failingKeyCodes.remove(code) }
    }
  }
  func clearCalls() { lock.withLock { storedCalls.removeAll() } }

  /// The default mapping: a distinct code per keysym used in these tests.
  static func defaultCode(_ keysym: KeySym) -> UInt8 { UInt8(8 + keysym % 240) }

  func keycode(for keysym: KeySym) -> UInt8 {
    lock.withLock { keymap[keysym] ?? Self.defaultCode(keysym) }
  }
  func pointerButtonCount() -> Int { buttons }
  func fakeKey(_ keycode: UInt8, down: Bool) -> Bool {
    record(.key(keycode, down: down), fails: failingKeyCodes.contains(keycode))
  }
  func fakeButton(_ button: UInt32, down: Bool) -> Bool { record(.button(button, down: down)) }
  func fakeMotion(x: Int32, y: Int32) -> Bool { record(.motion(x, y)) }
  func flush() -> Bool { record(.flush) }
  func sync() -> Bool { record(.sync) }
  func close() { _ = record(.close, ignoreFailure: true) }

  private func record(_ call: PortCall, fails: Bool = false, ignoreFailure: Bool = false) -> Bool {
    lock.withLock {
      guard ignoreFailure || (!failing && !fails) else { return false }
      storedCalls.append(call)
      return true
    }
  }
}

private func code(_ key: VirtualKey) -> UInt8 {
  FakePort.defaultCode(LinuxKeySymMapper.keysym(for: key)!)
}

private func errorCode<T>(_ result: CoreResult<T>) -> CoreErrorCode? {
  if case .failure(let error) = result { return error.code }
  return nil
}

// MARK: - Pure tables

@Suite("M4-024 key table and pointer arithmetic")
struct LinuxX11InjectorTableTests {
  @Test("every catalog member maps to its X11 keysym")
  func everyMemberMaps() {
    for member in catalog {
      #expect(LinuxKeySymMapper.keysym(for: member) == expectedKeySym(member), "\(member)")
      #expect(LinuxKeySymMapper.keysym(for: member) != nil)
    }
  }

  @Test("unknown and out-of-domain payloads have no keysym")
  func outOfDomain() {
    let invalid: [VirtualKey] = [
      .letter(26), .letter(255), .digit(10), .function(0), .function(25), .unknown(0),
      .unknown(0x61),
    ]
    for member in invalid { #expect(LinuxKeySymMapper.keysym(for: member) == nil) }
  }

  @Test("only the catalog's modifier group counts as modifiers")
  func modifierGroup() {
    let modifiers = catalog.filter(LinuxKeySymMapper.isModifier)
    #expect(modifiers == [.shift, .control, .option, .command, .capsLock])
  }

  @Test("wheel sign table: up 4, down 5, left 6, right 7, vertical first")
  func wheelTable() {
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: 0, deltaY: 1) == [4])
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: 0, deltaY: -2) == [5, 5])
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: 1, deltaY: 0) == [6])
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: -1, deltaY: 0) == [7])
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: -1, deltaY: 1) == [4, 7])
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: 0, deltaY: 0) == [])
  }

  @Test("each wheel axis is capped at 32 notches, including Int32.min")
  func wheelCap() {
    #expect(LinuxX11PointerMath.maximumNotchesPerAxis == 32)
    #expect(LinuxX11PointerMath.wheelButtons(deltaX: 0, deltaY: 33).count == 32)
    let extreme = LinuxX11PointerMath.wheelButtons(deltaX: .min, deltaY: .max)
    #expect(extreme == Array(repeating: 4, count: 32) + Array(repeating: 7, count: 32))
  }

  @Test("button table: left 1, middle 2, right 3, auxiliary 8")
  func buttonTable() {
    #expect(LinuxX11PointerMath.xButton(for: .left) == 1)
    #expect(LinuxX11PointerMath.xButton(for: .middle) == 2)
    #expect(LinuxX11PointerMath.xButton(for: .right) == 3)
    #expect(LinuxX11PointerMath.xButton(for: .auxiliary) == 8)
  }

  @Test("every pixel round-trips through the decoder's normalization")
  func pixelRoundTrip() {
    for extent in [1, 2, 3, 900, 1600, 1920] {
      for pixel in 0..<extent {
        // BarrierMouseMoveDecoder.normalized: (pixel - origin) / (extent - 1), 0 for one pixel.
        let normalized = extent > 1 ? Double(pixel) / Double(extent - 1) : 0
        #expect(LinuxX11PointerMath.pixel(normalized, extent: extent) == pixel)
      }
    }
  }

  @Test("pixels are clamped to the axis")
  func pixelClamp() {
    #expect(LinuxX11PointerMath.pixel(-1, extent: 100) == 0)
    #expect(LinuxX11PointerMath.pixel(2, extent: 100) == 99)
    #expect(LinuxX11PointerMath.pixel(.nan, extent: 100) == 0)
    #expect(LinuxX11PointerMath.pixel(0.5, extent: 0) == 0)
  }
}

// MARK: - Injector over an in-memory port

@Suite("M4-024 injector rules over an in-memory X server")
struct LinuxX11InjectorPortTests {
  @Test("a key press and release reach XTest with the mapped key code, each flushed")
  func keyHappyPath() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    #expect(try injector.inject(key(.letter(0), .down)).get() == .injected)
    #expect(try injector.inject(key(.letter(0), .up)).get() == .injected)
    let a = code(.letter(0))
    #expect(port.calls == [.key(a, down: true), .flush, .key(a, down: false), .flush])
  }

  @Test("unknown and out-of-domain keys are unsupported in every phase and inject nothing")
  func unknownKeys() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    for member in [VirtualKey.unknown(7), .letter(26), .function(0)] {
      for phase in [KeyPhase.down, .up, .repeatKey] {
        #expect(try injector.inject(key(member, phase)).get() == .unsupported(.unknownKey))
      }
    }
    #expect(port.calls.isEmpty)
    try injector.releaseAllHeld().get()
    #expect(port.inputCalls.isEmpty)
  }

  @Test("a repeat is never injected, even for a held key")
  func repeatNotInjected() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = injector.inject(key(.letter(1), .down))
    port.clearCalls()
    #expect(
      try injector.inject(key(.letter(1), .repeatKey)).get() == .unsupported(.repeatNotInjected))
    #expect(try injector.inject(key(.space, .repeatKey)).get() == .unsupported(.repeatNotInjected))
    #expect(port.calls.isEmpty)
  }

  @Test("a key the keymap lacks is noPlatformKeyCode and is not recorded")
  func noKeyCode() throws {
    let port = FakePort()
    port.remap(0x1008_FF12, to: 0)
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    #expect(try injector.inject(key(.mute, .down)).get() == .unsupported(.noPlatformKeyCode))
    #expect(port.calls.isEmpty)
    try injector.releaseAllHeld().get()
    #expect(port.inputCalls.isEmpty)
  }

  @Test("a release after a keymap change frees the key code that was pressed")
  func releaseUsesPressedCode() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = injector.inject(key(.letter(0), .down))
    port.remap(0x61, to: 200)
    #expect(try injector.inject(key(.letter(0), .up)).get() == .injected)
    #expect(port.heldKeyCodes.isEmpty)
    // Once released, the current mapping applies again.
    _ = injector.inject(key(.letter(0), .down))
    #expect(port.heldKeyCodes == [200])
  }

  @Test("a button release after the pointer lost the button frees the pressed button")
  func buttonReleaseUsesPressedCode() throws {
    let port = FakePort(buttons: 9)
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    #expect(try injector.inject(.mouseButton(button: .auxiliary, phase: .down)).get() == .injected)
    #expect(try injector.inject(.mouseButton(button: .auxiliary, phase: .up)).get() == .injected)
    #expect(port.inputCalls == [.button(8, down: true), .button(8, down: false)])
  }

  @Test("buttons beyond the pointer's button count are unavailable")
  func buttonUnavailable() throws {
    let port = FakePort(buttons: 5)
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    let aux = KVMEvent.mouseButton(button: .auxiliary, phase: .down)
    #expect(try injector.inject(aux).get() == .unsupported(.buttonUnavailable))
    #expect(
      try injector.inject(.scroll(deltaX: 1, deltaY: 0)).get() == .unsupported(.buttonUnavailable))
    #expect(try injector.inject(.scroll(deltaX: 0, deltaY: -1)).get() == .injected)
    #expect(port.inputCalls == [.button(5, down: true), .button(5, down: false)])
  }

  @Test("left, middle and right map to X buttons 1, 2 and 3")
  func basicButtons() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    for button in [MouseButton.left, .middle, .right] {
      _ = try injector.inject(.mouseButton(button: button, phase: .down)).get()
      _ = try injector.inject(.mouseButton(button: button, phase: .up)).get()
    }
    let expected: [PortCall] = [1, 2, 3].flatMap {
      [PortCall.button($0, down: true), .button($0, down: false)]
    }
    #expect(port.inputCalls == expected)
  }

  @Test("a scroll is a press and release per notch")
  func scrollNotches() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    #expect(try injector.inject(.scroll(deltaX: -1, deltaY: 2)).get() == .injected)
    let expected: [PortCall] = [4, 4, 7].flatMap {
      [PortCall.button($0, down: true), .button($0, down: false)]
    }
    #expect(port.inputCalls == expected)
  }

  @Test("a move lands on the pixel the server meant, offset by the origin")
  func motion() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(.mouseMove(position: NormalizedPoint(x: 0, y: 0))).get()
    _ = try injector.inject(.mouseMove(position: NormalizedPoint(x: 1, y: 1))).get()
    _ = try injector.inject(.mouseMove(position: NormalizedPoint(x: 799.0 / 1599, y: 0.5))).get()
    let offset = LinuxX11Injector(
      port: port,
      screen: {
        PlatformScreenGeometry(
          originX: 10, originY: 20, width: 2, height: 2, cursorX: 0, cursorY: 0)
      })
    _ = try offset.inject(.mouseMove(position: NormalizedPoint(x: 1, y: 0))).get()
    #expect(
      port.inputCalls == [.motion(0, 0), .motion(1599, 899), .motion(799, 450), .motion(11, 20)])
  }

  @Test("events that are not input fail with preconditionFailed and change nothing")
  func notInput() {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    let events: [KVMEvent] = [
      .leaveScreen(screen: ScreenID()),
      .enterScreen(screen: ScreenID(), position: NormalizedPoint(x: 0, y: 0)),
    ]
    for event in events {
      #expect(errorCode(injector.inject(event)) == .internalFailure(.preconditionFailed))
    }
    #expect(port.calls.isEmpty)
  }

  @Test("a lost display fails with subsystemUnavailable and records nothing")
  func platformLost() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    port.setFailing(true)
    #expect(errorCode(injector.inject(key(.letter(2), .down))) == .lifecycle(.subsystemUnavailable))
    #expect(errorCode(injector.flush()) == .lifecycle(.subsystemUnavailable))
    port.setFailing(false)
    try injector.releaseAllHeld().get()
    #expect(port.inputCalls.isEmpty)
  }

  @Test("releaseAllHeld: other keys, then buttons, then modifiers, each in reverse press order")
  func releaseOrder() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    let presses: [KVMEvent] = [
      key(.shift, .down), key(.letter(0), .down), .mouseButton(button: .left, phase: .down),
      key(.control, .down), key(.digit(1), .down), .mouseButton(button: .right, phase: .down),
    ]
    for event in presses { _ = try injector.inject(event).get() }
    port.clearCalls()
    try injector.releaseAllHeld().get()
    #expect(
      port.inputCalls == [
        .key(code(.digit(1)), down: false), .key(code(.letter(0)), down: false),
        .button(3, down: false), .button(1, down: false),
        .key(code(.control), down: false), .key(code(.shift), down: false),
      ])
    #expect(port.heldKeyCodes.isEmpty && port.heldButtons.isEmpty)
    port.clearCalls()
    try injector.releaseAllHeld().get()
    #expect(port.inputCalls.isEmpty)
  }

  @Test("a failed sweep reports cleanupPartial, keeps what failed and retries it")
  func partialSweep() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(key(.letter(0), .down)).get()
    _ = try injector.inject(key(.letter(1), .down)).get()
    port.failKeyCode(code(.letter(0)), true)
    let first = injector.releaseAllHeld()
    #expect(errorCode(first) == .inputSafety(.cleanupPartial))
    #expect(port.heldKeyCodes == [code(.letter(0))])
    port.failKeyCode(code(.letter(0)), false)
    port.clearCalls()
    try injector.releaseAllHeld().get()
    #expect(port.inputCalls == [.key(code(.letter(0)), down: false)])
  }

  @Test("release(_:) waits for the server, and an unsupported release counts as done")
  func releaseStep() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(key(.tab, .down)).get()
    port.clearCalls()
    try injector.release(key(.tab, .up))
    #expect(port.calls == [.key(code(.tab), down: false), .flush, .sync])
    try injector.release(key(.unknown(3), .up))
    port.setFailing(true)
    #expect(throws: CoreError.self) { try injector.release(key(.tab, .up)) }
  }

  @Test("releaseRemaining sweeps, then syncs; flush is XSync")
  func releaseRemaining() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(key(.option, .down)).get()
    port.clearCalls()
    try injector.releaseRemaining()
    #expect(port.calls == [.key(code(.option), down: false), .flush, .sync])
    port.clearCalls()
    try injector.flush().get()
    #expect(port.calls == [.sync])
    try injector.restoreLocalInput()
  }

  @Test("close releases what is held, closes once, and later calls fail")
  func closeReleases() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(key(.letter(4), .down)).get()
    try injector.close().get()
    try injector.close().get()
    #expect(port.heldKeyCodes.isEmpty)
    #expect(port.calls.filter { $0 == .close }.count == 1)
    #expect(errorCode(injector.inject(key(.letter(4), .down))) == .lifecycle(.subsystemUnavailable))
    #expect(errorCode(injector.flush()) == .lifecycle(.subsystemUnavailable))
    try injector.releaseAllHeld().get()
    try injector.releaseRemaining()
  }

}

// MARK: - Drain worker

/// An injector double for the drain: records the thread and can block inside `inject`.
private final class GatedInjector: InputInjectionBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [KVMEvent] = []
  private var threads: Set<String> = []
  let entered = DispatchSemaphore(value: 0)
  let gate = DispatchSemaphore(value: 0)
  let blockOn: KVMEvent?
  let failOn: KVMEvent?

  init(blockOn: KVMEvent? = nil, failOn: KVMEvent? = nil) {
    self.blockOn = blockOn
    self.failOn = failOn
  }

  var injected: [KVMEvent] { lock.withLock { events } }
  var threadNames: Set<String> { lock.withLock { threads } }

  func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome> {
    lock.withLock { _ = threads.insert(Thread.current.name ?? "") }
    if event == blockOn {
      entered.signal()
      gate.wait()
    }
    if event == failOn {
      return .failure(
        CoreError(
          code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
          cleanupDisposition: .notRequired))
    }
    lock.withLock { events.append(event) }
    if event != blockOn { entered.signal() }
    return .success(.injected)
  }

  func flush() -> CoreResult<Void> { .success(()) }
  func releaseAllHeld() -> CoreResult<Void> { .success(()) }
}

private final class FailureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [CoreError] = []
  var errors: [CoreError] { lock.withLock { stored } }
  func append(_ error: CoreError) { lock.withLock { stored.append(error) } }
}

@Suite("M4-024 injection drain on a dedicated thread")
struct LinuxInjectionDrainTests {
  @Test("events are injected in order on the drain's own thread")
  func order() {
    let injector = GatedInjector()
    let drain = LinuxInjectionDrain(injector: injector, capacity: 16, onFailure: { _ in })
    let events = (0..<5).map { key(.letter(UInt8($0)), .down) }
    for event in events { #expect(drain.enqueue(event)) }
    drain.start()
    for _ in events { injector.entered.wait() }
    drain.clearTransientState()
    #expect(injector.injected == events)
    #expect(injector.threadNames == [LinuxInjectionDrain.threadName])
  }

  @Test("clearTransientState waits for the in-flight event, then drops the queue")
  func joinsInFlight() {
    let press = key(.letter(0), .down)
    let release = key(.letter(0), .up)
    let injector = GatedInjector(blockOn: press)
    let drain = LinuxInjectionDrain(injector: injector, capacity: 16, onFailure: { _ in })
    drain.start()
    #expect(drain.enqueue(press))
    injector.entered.wait()
    #expect(drain.enqueue(release))
    let cleared = DispatchSemaphore(value: 0)
    Thread {
      drain.clearTransientState()
      cleared.signal()
    }.start()
    #expect(cleared.wait(timeout: .now() + 0.2) == .timedOut)
    injector.gate.signal()
    cleared.wait()
    #expect(injector.injected == [press])
    #expect(drain.count == 0)
    #expect(!drain.enqueue(release))
    drain.clearTransientState()
  }

  @Test("a full queue refuses, and a stopped drain refuses")
  func bounded() {
    let injector = GatedInjector()
    let drain = LinuxInjectionDrain(injector: injector, capacity: 2, onFailure: { _ in })
    #expect(drain.enqueue(key(.space, .down)))
    #expect(drain.enqueue(key(.space, .up)))
    #expect(!drain.enqueue(key(.tab, .down)))
    drain.clearTransientState()
    drain.clearTransientState()
    #expect(drain.count == 0)
    drain.start()
    #expect(!drain.enqueue(key(.tab, .down)))
    #expect(injector.injected.isEmpty)
  }

  @Test("an injection failure is reported once and stops the worker")
  func failureStops() {
    let bad = key(.letter(3), .down)
    let injector = GatedInjector(failOn: bad)
    let failures = FailureBox()
    let reported = DispatchSemaphore(value: 0)
    let drain = LinuxInjectionDrain(injector: injector, capacity: 8) { error in
      failures.append(error)
      reported.signal()
    }
    #expect(drain.enqueue(bad))
    #expect(drain.enqueue(key(.letter(4), .down)))
    drain.start()
    reported.wait()
    drain.clearTransientState()
    #expect(failures.errors.map(\.code) == [.lifecycle(.subsystemUnavailable)])
    #expect(injector.injected.isEmpty)
  }

  @Test("terminal path: a release dropped by the reset is still released by the sweep (h.1)")
  func sweepCoversDroppedRelease() throws {
    let port = FakePort()
    let injector = LinuxX11Injector(port: port, screen: screen1600x900)
    _ = try injector.inject(key(.letter(0), .down)).get()
    let drain = LinuxInjectionDrain(injector: injector, capacity: 4, onFailure: { _ in })
    #expect(drain.enqueue(key(.letter(0), .up)))
    drain.clearTransientState()
    #expect(port.heldKeyCodes == [code(.letter(0))])
    try injector.releaseRemaining()
    #expect(port.heldKeyCodes.isEmpty)
  }
}

// MARK: - Xvfb

private let x11Enabled = LinuxPlatformSkeleton.x11TestsEnabled(
  environment: ProcessInfo.processInfo.environment)

/// A second connection with a full-screen focused window that records what it receives.
private final class X11Observer {
  let display: OpaquePointer
  let root: Window
  let window: Window

  init() throws {
    guard xlibThreadsEnabled, let display = XOpenDisplay(nil) else { throw ObserverError.noDisplay }
    self.display = display
    let screen = XDefaultScreen(display)
    root = XRootWindow(display, screen)
    let width = UInt32(XDisplayWidth(display, screen))
    let height = UInt32(XDisplayHeight(display, screen))
    window = XCreateSimpleWindow(display, root, 0, 0, width, height, 0, 0, 0)
    // KeyPress, KeyRelease, ButtonPress, ButtonRelease, PointerMotion, StructureNotify.
    let mask: Int = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 6) | (1 << 17)
    XSelectInput(display, window, mask)
    XMapRaised(display, window)
    _ = try next(types: [19], timeout: 5)  // MapNotify
    XSetInputFocus(display, window, 2, 0)  // RevertToParent, CurrentTime
    XSync(display, 0)
    drain()
  }

  enum ObserverError: Error { case noDisplay, timeout }

  /// Event (type, detail): key code for keys, button for buttons, x for motion.
  func events(count: Int, timeout: TimeInterval) -> [(type: Int32, detail: UInt32)] {
    var seen: [(type: Int32, detail: UInt32)] = []
    let deadline = Date().addingTimeInterval(timeout)
    while seen.count < count, Date() < deadline {
      if let event = poll() { seen.append(event) } else { usleep(5_000) }
    }
    return seen
  }

  func collect(for duration: TimeInterval) -> [(type: Int32, detail: UInt32)] {
    var seen: [(type: Int32, detail: UInt32)] = []
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      if let event = poll() { seen.append(event) } else { usleep(5_000) }
    }
    return seen
  }

  func drain() { while poll() != nil {} }

  private func next(types: Set<Int32>, timeout: TimeInterval) throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let event = poll(), types.contains(event.type) { return event.type }
      usleep(5_000)
    }
    throw ObserverError.timeout
  }

  private func poll() -> (type: Int32, detail: UInt32)? {
    guard XPending(display) > 0 else { return nil }
    var event = XEvent()
    XNextEvent(display, &event)
    switch event.type {
    case 2, 3: return (event.type, event.xkey.keycode)
    case 4, 5: return (event.type, event.xbutton.button)
    case 6: return (event.type, UInt32(event.xmotion.x))
    default: return (event.type, 0)
    }
  }

  /// True when no key is down on the server.
  func keymapIsEmpty() -> Bool {
    var keys = [CChar](repeating: 0, count: 32)
    XQueryKeymap(display, &keys)
    return keys.allSatisfy { $0 == 0 }
  }

  /// The pointer's button mask (Button1Mask … Button5Mask).
  func buttonMask() -> UInt32 {
    var rootReturn: Window = 0
    var child: Window = 0
    var rootX: Int32 = 0
    var rootY: Int32 = 0
    var windowX: Int32 = 0
    var windowY: Int32 = 0
    var mask: UInt32 = 0
    XQueryPointer(display, root, &rootReturn, &child, &rootX, &rootY, &windowX, &windowY, &mask)
    return mask & 0x1F00
  }

  deinit {
    XDestroyWindow(display, window)
    XCloseDisplay(display)
  }
}

private func keyEvents(_ events: [(type: Int32, detail: UInt32)]) -> [String] {
  events.compactMap { event in
    switch event.type {
    case 2: "KeyPress\(event.detail)"
    case 3: "KeyRelease\(event.detail)"
    case 4: "ButtonPress\(event.detail)"
    case 5: "ButtonRelease\(event.detail)"
    default: nil
    }
  }
}

// Serialized, and the only suite that calls Xlib, so no two Xlib connections are opened or used
// at the same time by the test process. Each test is bounded, so a hang names its test.
@Suite(
  "M4-024 injector against Xvfb", .serialized, .tags(.x11), .enabled(if: x11Enabled),
  .timeLimit(.minutes(1)))
struct LinuxX11InjectorXvfbTests {
  @Test("no display is lifecycle.subsystemUnavailable")
  func noDisplay() {
    #expect(xlibThreadsEnabled)
    #expect(throws: CoreError.self) {
      _ = try LinuxX11Injector(displayName: ":4097", screen: screen1600x900)
    }
    do {
      _ = try LinuxX11Injector(displayName: ":4097", screen: screen1600x900)
    } catch {
      #expect(error.code == .lifecycle(.subsystemUnavailable))
    }
  }
  @Test("keys arrive with the Xvfb default keymap's key codes (the M2-035 oracle)")
  func keycodes() throws {
    let observer = try X11Observer()
    let injector = try LinuxX11Injector(displayName: nil, screen: screen1600x900)
    defer { _ = injector.close() }
    let sequence: [VirtualKey] = [
      .letter(0), .shift, .letter(1), .enter, .digit(1), .function(5), .punctuation(.minus),
    ]
    for member in sequence {
      _ = try injector.inject(key(member, .down)).get()
      _ = try injector.inject(key(member, .up)).get()
    }
    try injector.flush().get()
    let seen = keyEvents(observer.events(count: 14, timeout: 5))
    let expected = [38, 50, 56, 36, 10, 71, 20].flatMap { ["KeyPress\($0)", "KeyRelease\($0)"] }
    #expect(seen == expected)
  }

  @Test("buttons, wheel and motion arrive as X button and motion events")
  func pointer() throws {
    let observer = try X11Observer()
    let geometry: @Sendable () -> PlatformScreenGeometry = {
      PlatformScreenGeometry(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 0, cursorY: 0)
    }
    let injector = try LinuxX11Injector(displayName: nil, screen: geometry)
    defer { _ = injector.close() }
    _ = try injector.inject(.mouseMove(position: NormalizedPoint(x: 0.25, y: 0.5))).get()
    try injector.flush().get()
    let motion = observer.events(count: 1, timeout: 5)
    #expect(motion.first?.type == 6)
    #expect(motion.first?.detail == 400)  // round(0.25 × 1599)
    observer.drain()
    for button in [MouseButton.left, .right, .middle] {
      _ = try injector.inject(.mouseButton(button: button, phase: .down)).get()
      _ = try injector.inject(.mouseButton(button: button, phase: .up)).get()
    }
    _ = try injector.inject(.scroll(deltaX: 0, deltaY: 1)).get()
    _ = try injector.inject(.scroll(deltaX: 0, deltaY: -1)).get()
    try injector.flush().get()
    let seen = keyEvents(observer.events(count: 10, timeout: 5).filter { $0.type != 6 })
    let expected = [1, 3, 2, 4, 5].flatMap { ["ButtonPress\($0)", "ButtonRelease\($0)"] }
    #expect(seen == expected)
  }

  @Test("a key held for over a second autorepeats in the X server (decision 6)")
  func autorepeat() throws {
    let observer = try X11Observer()
    let injector = try LinuxX11Injector(displayName: nil, screen: screen1600x900)
    defer { _ = injector.close() }
    _ = try injector.inject(key(.letter(0), .down)).get()
    try injector.flush().get()
    let held = observer.collect(for: 1.2)
    try injector.release(key(.letter(0), .up))
    let presses = held.filter { $0.type == 2 && $0.detail == 38 }.count
    #expect(presses > 1)
    #expect(observer.keymapIsEmpty())
  }

  @Test("the terminal path leaves no key or button down (h.1, h.6)")
  func releaseAllLeavesNothingDown() throws {
    let observer = try X11Observer()
    let injector = try LinuxX11Injector(displayName: nil, screen: screen1600x900)
    defer { _ = injector.close() }
    _ = try injector.inject(key(.shift, .down)).get()
    _ = try injector.inject(key(.letter(0), .down)).get()
    _ = try injector.inject(.mouseButton(button: .left, phase: .down)).get()
    try injector.flush().get()
    #expect(!observer.keymapIsEmpty())
    #expect(observer.buttonMask() != 0)
    let drain = LinuxInjectionDrain(injector: injector, capacity: 4, onFailure: { _ in })
    #expect(drain.enqueue(key(.letter(0), .up)))
    drain.clearTransientState()
    try injector.releaseRemaining()
    #expect(observer.keymapIsEmpty())
    #expect(observer.buttonMask() == 0)
  }

  @Test("an X server without XTest is permission.capabilityUnavailable")
  func missingXTest() throws {
    // A display number nobody holds: no lock file and no socket.
    let free = (150..<250).first {
      !FileManager.default.fileExists(atPath: "/tmp/.X\($0)-lock")
        && !FileManager.default.fileExists(atPath: "/tmp/.X11-unix/X\($0)")
    }
    let number = try #require(free)
    let xvfb = Process()
    xvfb.executableURL = URL(fileURLWithPath: "/usr/bin/Xvfb")
    xvfb.arguments = [":\(number)", "-extension", "XTEST", "-nolisten", "tcp"]
    xvfb.standardOutput = FileHandle.nullDevice
    xvfb.standardError = FileHandle.nullDevice
    #expect(xlibThreadsEnabled)
    try xvfb.run()
    defer {
      // Bounded: `waitUntilExit()` can block forever on Linux Foundation.
      xvfb.terminate()
      let stopBy = Date().addingTimeInterval(5)
      while xvfb.isRunning, Date() < stopBy { usleep(20_000) }
      if xvfb.isRunning { kill(xvfb.processIdentifier, SIGKILL) }
    }
    let socket = "/tmp/.X11-unix/X\(number)"
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: socket), Date() < deadline { usleep(20_000) }
    var code: CoreErrorCode?
    for _ in 0..<50 {
      do {
        let injector = try LinuxX11Injector(displayName: ":\(number)", screen: screen1600x900)
        _ = injector.close()
        code = nil
        break
      } catch {
        code = error.code
        if code != .lifecycle(.subsystemUnavailable) { break }
        usleep(100_000)
      }
    }
    #expect(code == .permission(.capabilityUnavailable))
  }
}

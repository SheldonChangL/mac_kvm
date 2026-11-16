// M4-024: the Linux X11 input injector (C-015 `InputInjectionBackend`).
//
// - Injection goes through the XTest extension on a display connection the injector owns
//   (plan b.12, decision 4). The composition root calls `XInitThreads()` once before any other
//   Xlib call (plan a.3); the injector serializes every use of its own connection with one lock.
// - The key table is first-party: X11 public keysym values from `keysymdef.h` and
//   `XF86keysym.h`, chosen by the US ANSI positional meaning of the C-005 catalog (M1-042,
//   M1-043). Nothing here is derived from Barrier.
// - Held input is recorded by the platform code it was pressed with, in memory only, so a
//   release after a keymap change frees what was pressed (plan h.1). Nothing is logged.
// - `.repeatKey` is never injected: the X server autorepeats XTest-held keys (plan a.6, risk f.4).
// - `LinuxInjectionDrain` is the dedicated drain `Thread` the terminal path stops and joins
//   before the queue reset and the releases (plan h.6, M1-063). The injector itself keeps no
//   queue (C-015).

import CX11
import CXTest
import Foundation
import KVMContracts

// MARK: - Key table

/// Maps C-005 virtual keys to X11 keysyms. First-party, US ANSI positional (M1-043); other
/// layouts are not claimed.
package enum LinuxKeySymMapper {
  /// The keysym for `key`, or `nil` for `unknown` and for a `letter`, `digit` or `function`
  /// outside its catalog domain (M1-042). Exhaustive with no `default`.
  package static func keysym(for key: VirtualKey) -> KeySym? {
    switch key {
    case .letter(let index):
      return index <= 25 ? KeySym(0x61) + KeySym(index) : nil  // XK_a + n
    case .digit(let digit):
      return digit <= 9 ? KeySym(0x30) + KeySym(digit) : nil  // XK_0 + n
    case .function(let number):
      return (1...24).contains(number) ? KeySym(0xFFBE) + KeySym(number) - 1 : nil  // XK_F1 + n - 1
    case .punctuation(let punctuation):
      return punctuationKeySym(punctuation)
    case .enter: return 0xFF0D  // XK_Return
    case .escape: return 0xFF1B  // XK_Escape
    case .tab: return 0xFF09  // XK_Tab
    case .space: return 0x20  // XK_space
    case .backspace: return 0xFF08  // XK_BackSpace
    case .delete: return 0xFFFF  // XK_Delete
    case .left: return 0xFF51  // XK_Left
    case .up: return 0xFF52  // XK_Up
    case .right: return 0xFF53  // XK_Right
    case .down: return 0xFF54  // XK_Down
    case .home: return 0xFF50  // XK_Home
    case .end: return 0xFF57  // XK_End
    case .pageUp: return 0xFF55  // XK_Prior
    case .pageDown: return 0xFF56  // XK_Next
    case .shift: return 0xFFE1  // XK_Shift_L
    case .control: return 0xFFE3  // XK_Control_L
    case .option: return 0xFFE9  // XK_Alt_L
    case .command: return 0xFFEB  // XK_Super_L
    case .capsLock: return 0xFFE5  // XK_Caps_Lock
    case .volumeUp: return 0x1008_FF13  // XF86XK_AudioRaiseVolume
    case .volumeDown: return 0x1008_FF11  // XF86XK_AudioLowerVolume
    case .mute: return 0x1008_FF12  // XF86XK_AudioMute
    case .unknown: return nil
    }
  }

  private static func punctuationKeySym(_ punctuation: PunctuationKey) -> KeySym {
    switch punctuation {
    case .minus: 0x2D  // XK_minus
    case .equal: 0x3D  // XK_equal
    case .leftBracket: 0x5B  // XK_bracketleft
    case .rightBracket: 0x5D  // XK_bracketright
    case .backslash: 0x5C  // XK_backslash
    case .semicolon: 0x3B  // XK_semicolon
    case .quote: 0x27  // XK_apostrophe
    case .grave: 0x60  // XK_grave
    case .comma: 0x2C  // XK_comma
    case .period: 0x2E  // XK_period
    case .slash: 0x2F  // XK_slash
    }
  }

  /// The catalog's modifier group (M1-042), which `releaseAllHeld()` releases last.
  package static func isModifier(_ key: VirtualKey) -> Bool {
    switch key {
    case .shift, .control, .option, .command, .capsLock: true
    default: false
    }
  }
}

// MARK: - Pointer arithmetic

/// Pure pointer conversions (first-party).
package enum LinuxX11PointerMath {
  /// At most this many wheel notches are injected per axis of one scroll event.
  package static let maximumNotchesPerAxis = 32

  /// The pixel offset for a normalized coordinate on an axis of `extent` pixels:
  /// `round(value × (extent − 1))`, clamped to the axis. The inverse of the decoder's
  /// `(pixel − origin) / (extent − 1)` (M1-PROTOCOL-003), so every pixel round-trips.
  package static func pixel(_ value: Double, extent: Int) -> Int {
    guard extent > 1, value.isFinite else { return 0 }
    let raw = (value * Double(extent - 1)).rounded()
    return Int(min(max(raw, 0), Double(extent - 1)))
  }

  /// The X core button for a KVM button: left 1, middle 2, right 3, auxiliary 8 (the server's
  /// X button 8 is wire 4, M1-PROTOCOL-003).
  package static func xButton(for button: MouseButton) -> UInt32 {
    switch button {
    case .left: 1
    case .middle: 2
    case .right: 3
    case .auxiliary: 8
    }
  }

  /// One X wheel button per notch: `deltaY > 0` is 4 (up), `< 0` is 5 (down), `deltaX > 0` is 6
  /// (left, the first-party sign of M1-PROTOCOL-003), `< 0` is 7 (right). Vertical first, each
  /// axis capped at `maximumNotchesPerAxis`.
  package static func wheelButtons(deltaX: Int32, deltaY: Int32) -> [UInt32] {
    let vertical = min(Int(deltaY.magnitude), maximumNotchesPerAxis)
    let horizontal = min(Int(deltaX.magnitude), maximumNotchesPerAxis)
    let verticalButton: UInt32 = deltaY > 0 ? 4 : 5
    let horizontalButton: UInt32 = deltaX > 0 ? 6 : 7
    return Array(repeating: verticalButton, count: vertical)
      + Array(repeating: horizontalButton, count: horizontal)
  }
}

// MARK: - Platform port

/// The X11 calls the injector makes, one connection's worth. `XlibInputPort` is the real one;
/// tests substitute an in-memory one. Calls are made under the injector's lock only.
package protocol LinuxX11InputPort: AnyObject {
  /// `XKeysymToKeycode`: 0 when the current keymap has no key code for `keysym`.
  func keycode(for keysym: KeySym) -> UInt8
  /// `XGetPointerMapping`: the number of core pointer buttons.
  func pointerButtonCount() -> Int
  /// `XTestFakeKeyEvent`; false when the request could not be made.
  func fakeKey(_ keycode: UInt8, down: Bool) -> Bool
  /// `XTestFakeButtonEvent`.
  func fakeButton(_ button: UInt32, down: Bool) -> Bool
  /// `XTestFakeMotionEvent` on the current screen, in root-window pixels.
  func fakeMotion(x: Int32, y: Int32) -> Bool
  /// `XFlush`.
  func flush() -> Bool
  /// `XSync`: returns once the server processed every request.
  func sync() -> Bool
  /// `XCloseDisplay`. Called at most once.
  func close()
}

/// The real port over one Xlib connection with XTest.
final class XlibInputPort: LinuxX11InputPort {
  private let display: OpaquePointer

  /// Opens `displayName` (or `DISPLAY` when `nil`) and checks for XTest.
  init(displayName: String?) throws(CoreError) {
    let opened: OpaquePointer?
    if let displayName {
      opened = displayName.withCString { XOpenDisplay($0) }
    } else {
      opened = XOpenDisplay(nil)
    }
    guard let opened else {
      throw linuxInjectorError(.lifecycle(.subsystemUnavailable))
    }
    var eventBase: Int32 = 0
    var errorBase: Int32 = 0
    var major: Int32 = 0
    var minor: Int32 = 0
    guard XTestQueryExtension(opened, &eventBase, &errorBase, &major, &minor) != 0 else {
      XCloseDisplay(opened)
      throw linuxInjectorError(.permission(.capabilityUnavailable))
    }
    display = opened
  }

  func keycode(for keysym: KeySym) -> UInt8 { XKeysymToKeycode(display, keysym) }

  func pointerButtonCount() -> Int { Int(XGetPointerMapping(display, nil, 0)) }

  func fakeKey(_ keycode: UInt8, down: Bool) -> Bool {
    XTestFakeKeyEvent(display, UInt32(keycode), down ? 1 : 0, 0) != 0
  }

  func fakeButton(_ button: UInt32, down: Bool) -> Bool {
    XTestFakeButtonEvent(display, button, down ? 1 : 0, 0) != 0
  }

  func fakeMotion(x: Int32, y: Int32) -> Bool {
    XTestFakeMotionEvent(display, -1, x, y, 0) != 0
  }

  func flush() -> Bool { XFlush(display) != 0 }

  func sync() -> Bool { XSync(display, 0) != 0 }

  func close() { XCloseDisplay(display) }
}

func linuxInjectorError(
  _ code: CoreErrorCode, cleanup: CleanupDisposition = .notRequired
) -> CoreError {
  CoreError(code: code, severity: .error, retryDisposition: .never, cleanupDisposition: cleanup)
}

// MARK: - Injector

/// Injects `KVMEvent` input into an X11 display through XTest (C-015, plan b.12).
///
/// Besides the C-015 calls it offers the `ClientInputSafety` steps the composition root adapts
/// (M1-063): `release(_:)`, `releaseRemaining()` and `restoreLocalInput()`. The drain worker and
/// its `clearTransientState()` are `LinuxInjectionDrain`'s.
package final class LinuxX11Injector: InputInjectionBackend, @unchecked Sendable {
  private let lock = NSLock()
  private let port: any LinuxX11InputPort
  private let screen: @Sendable () -> PlatformScreenGeometry
  private let buttonCount: Int
  private var heldKeys: [(key: VirtualKey, code: UInt8)] = []
  private var heldButtons: [(button: MouseButton, code: UInt32)] = []
  private var closed = false

  /// Connects to `displayName` (`DISPLAY` when `nil`). Fails with `lifecycle.subsystemUnavailable`
  /// without a display and `permission.capabilityUnavailable` without XTest.
  package convenience init(
    displayName: String?, screen: @escaping @Sendable () -> PlatformScreenGeometry
  ) throws(CoreError) {
    self.init(port: try XlibInputPort(displayName: displayName), screen: screen)
  }

  /// Over an already opened port (tests use an in-memory one).
  package init(
    port: any LinuxX11InputPort, screen: @escaping @Sendable () -> PlatformScreenGeometry
  ) {
    self.port = port
    self.screen = screen
    buttonCount = port.pointerButtonCount()
  }

  deinit {
    if !closed { port.close() }
  }

  package func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome> {
    lock.withLock { injectLocked(event) }
  }

  package func flush() -> CoreResult<Void> {
    lock.withLock { () -> CoreResult<Void> in
      guard !closed, port.sync() else {
        return .failure(linuxInjectorError(.lifecycle(.subsystemUnavailable)))
      }
      return .success(())
    }
  }

  package func releaseAllHeld() -> CoreResult<Void> {
    lock.withLock { releaseAllHeldLocked() }
  }

  /// `ClientInputSafety.release`: injects the release, then waits for the server (`XSync`). An
  /// `.unsupported` release counts as done: nothing was held (plan h.6).
  package func release(_ event: KVMEvent) throws(CoreError) {
    if case .failure(let error) = inject(event) { throw error }
    if case .failure(let error) = flush() { throw error }
  }

  /// `ClientInputSafety.releaseRemaining`: `releaseAllHeld()`, then `XSync` (plan h.1).
  package func releaseRemaining() throws(CoreError) {
    if case .failure(let error) = releaseAllHeld() { throw error }
    // After `close()` nothing is held and the connection is gone: there is nothing to wait for.
    if lock.withLock({ closed }) { return }
    if case .failure(let error) = flush() { throw error }
  }

  /// `ClientInputSafety.restoreLocalInput`: the client never suppresses local input.
  package func restoreLocalInput() throws(CoreError) {}

  /// Releases everything held, waits for the server and closes the connection. Idempotent.
  /// Later calls fail with `lifecycle.subsystemUnavailable`.
  package func close() -> CoreResult<Void> {
    lock.withLock { () -> CoreResult<Void> in
      guard !closed else { return .success(()) }
      let swept = releaseAllHeldLocked()
      _ = port.sync()
      closed = true
      port.close()
      return swept
    }
  }

  // MARK: Locked helpers

  private func injectLocked(_ event: KVMEvent) -> CoreResult<InjectionOutcome> {
    switch event {
    case .clipboard, .enterScreen, .leaveScreen:
      return .failure(linuxInjectorError(.internalFailure(.preconditionFailed)))
    case .mouseMove, .mouseButton, .scroll, .key:
      break
    }
    guard !closed else {
      return .failure(linuxInjectorError(.lifecycle(.subsystemUnavailable)))
    }
    let outcome: CoreResult<InjectionOutcome>
    switch event {
    case .mouseMove(let position):
      outcome = move(to: position)
    case .mouseButton(let button, let phase):
      outcome = press(button, down: phase == .down)
    case .scroll(let deltaX, let deltaY):
      outcome = scroll(deltaX: deltaX, deltaY: deltaY)
    case .key(let key, let phase, _):
      outcome = press(key, phase: phase)
    case .clipboard, .enterScreen, .leaveScreen:
      outcome = .failure(linuxInjectorError(.internalFailure(.preconditionFailed)))
    }
    if case .success(.injected) = outcome, !port.flush() {
      return .failure(linuxInjectorError(.lifecycle(.subsystemUnavailable)))
    }
    return outcome
  }

  private func move(to position: NormalizedPoint) -> CoreResult<InjectionOutcome> {
    let geometry = screen()
    let x = geometry.originX + LinuxX11PointerMath.pixel(position.x, extent: geometry.width)
    let y = geometry.originY + LinuxX11PointerMath.pixel(position.y, extent: geometry.height)
    let clampedX = Int32(clamping: x)
    let clampedY = Int32(clamping: y)
    guard port.fakeMotion(x: clampedX, y: clampedY) else { return platformLost() }
    return .success(.injected)
  }

  private func press(_ button: MouseButton, down: Bool) -> CoreResult<InjectionOutcome> {
    let heldCode = heldButtons.first { $0.button == button }?.code
    let code = heldCode ?? LinuxX11PointerMath.xButton(for: button)
    if heldCode == nil, Int(code) > buttonCount {
      return .success(.unsupported(.buttonUnavailable))
    }
    guard port.fakeButton(code, down: down) else { return platformLost() }
    heldButtons.removeAll { $0.button == button }
    if down { heldButtons.append((button: button, code: code)) }
    return .success(.injected)
  }

  private func scroll(deltaX: Int32, deltaY: Int32) -> CoreResult<InjectionOutcome> {
    let buttons = LinuxX11PointerMath.wheelButtons(deltaX: deltaX, deltaY: deltaY)
    if let highest = buttons.max(), Int(highest) > buttonCount {
      return .success(.unsupported(.buttonUnavailable))
    }
    for button in buttons {
      guard port.fakeButton(button, down: true), port.fakeButton(button, down: false) else {
        return platformLost()
      }
    }
    return .success(.injected)
  }

  private func press(_ key: VirtualKey, phase: KeyPhase) -> CoreResult<InjectionOutcome> {
    guard let keysym = LinuxKeySymMapper.keysym(for: key) else {
      return .success(.unsupported(.unknownKey))
    }
    guard phase != .repeatKey else {
      return .success(.unsupported(.repeatNotInjected))
    }
    let heldCode = heldKeys.first { $0.key == key }?.code
    let code = heldCode ?? port.keycode(for: keysym)
    guard code != 0 else {
      return .success(.unsupported(.noPlatformKeyCode))
    }
    let down = phase == .down
    guard port.fakeKey(code, down: down) else { return platformLost() }
    heldKeys.removeAll { $0.key == key }
    if down { heldKeys.append((key: key, code: code)) }
    return .success(.injected)
  }

  private func releaseAllHeldLocked() -> CoreResult<Void> {
    let keys = Array(heldKeys.reversed())
    let ordinary = keys.filter { !LinuxKeySymMapper.isModifier($0.key) }
    let modifiers = keys.filter { LinuxKeySymMapper.isModifier($0.key) }
    var failed = false
    if !closed {
      for held in ordinary where !releaseKeyLocked(held) { failed = true }
      for held in heldButtons.reversed() {
        if port.fakeButton(held.code, down: false) {
          heldButtons.removeAll { $0.button == held.button }
        } else {
          failed = true
        }
      }
      for held in modifiers where !releaseKeyLocked(held) { failed = true }
      if !port.flush() { failed = true }
    }
    guard !failed, heldKeys.isEmpty, heldButtons.isEmpty else {
      return .failure(linuxInjectorError(.inputSafety(.cleanupPartial), cleanup: .partial))
    }
    return .success(())
  }

  private func releaseKeyLocked(_ held: (key: VirtualKey, code: UInt8)) -> Bool {
    guard port.fakeKey(held.code, down: false) else { return false }
    heldKeys.removeAll { $0.key == held.key }
    return true
  }

  private func platformLost() -> CoreResult<InjectionOutcome> {
    .failure(linuxInjectorError(.lifecycle(.subsystemUnavailable)))
  }
}

// MARK: - Drain worker

/// The injection drain: a bounded FIFO and one dedicated `Thread` that hands each event to the
/// injector in order (plan a.3). It is a `Thread`, never a `Task` on the cooperative pool,
/// because `clearTransientState()` blocks while it joins the worker (M1-063, plan h.6).
///
/// - `enqueue(_:)` never blocks; it returns `false` when the queue is full or the drain is
///   stopped, and the caller fails closed.
/// - A `.failure` from the injector is terminal: the worker reports it once through
///   `onFailure` and stops; queued events are not injected.
/// - `clearTransientState()` stops the worker, waits for the event it is injecting, then drops
///   every queued event. It is idempotent; after it the drain accepts nothing. A new session
///   uses a new drain.
package final class LinuxInjectionDrain: @unchecked Sendable {
  private let condition = NSCondition()
  private let injector: any InputInjectionBackend
  private let capacity: Int
  private let onFailure: @Sendable (CoreError) -> Void
  private var queue: [KVMEvent] = []
  private var head = 0
  private var started = false
  private var stopping = false
  private var finished = false
  private var thread: Thread?

  /// Name of the worker thread; at most 15 bytes, the Linux thread-name limit.
  package static let threadName = "mackvm-inject"

  /// A drain of at most `capacity` queued events (at least 1). Call `start()` to run it.
  package init(
    injector: any InputInjectionBackend, capacity: Int,
    onFailure: @escaping @Sendable (CoreError) -> Void
  ) {
    self.injector = injector
    self.capacity = max(1, capacity)
    self.onFailure = onFailure
  }

  /// Number of queued events not yet taken by the worker.
  package var count: Int { condition.withLock { queue.count - head } }

  /// Starts the worker thread. Idempotent; does nothing after `clearTransientState()`.
  package func start() {
    condition.withLock {
      guard !started, !stopping else { return }
      started = true
      let worker = Thread { [self] in run() }
      worker.name = Self.threadName
      thread = worker
      worker.start()
    }
  }

  /// Queues one event for injection. `false` when full or stopped.
  package func enqueue(_ event: KVMEvent) -> Bool {
    condition.withLock {
      guard !stopping, queue.count - head < capacity else { return false }
      queue.append(event)
      condition.signal()
      return true
    }
  }

  /// `ClientInputSafety.clearTransientState`: stops and joins the worker, then drops the queue.
  /// Called from the worker itself (inside `onFailure`), it does not wait for itself.
  package func clearTransientState() {
    condition.lock()
    defer { condition.unlock() }
    stopping = true
    condition.broadcast()
    let isWorker = thread.map { Thread.current === $0 } ?? false
    if started, !isWorker {
      while !finished { condition.wait() }
    }
    queue.removeAll()
    head = 0
  }

  private func run() {
    // Named from the thread itself: on Linux a name set before `start()` does not reach it.
    Thread.current.name = Self.threadName
    while true {
      condition.lock()
      while head == queue.count, !stopping { condition.wait() }
      guard !stopping else {
        finished = true
        condition.broadcast()
        condition.unlock()
        return
      }
      let event = queue[head]
      head += 1
      if head == queue.count {
        queue.removeAll(keepingCapacity: true)
        head = 0
      }
      condition.unlock()

      if case .failure(let error) = injector.inject(event) {
        condition.withLock { stopping = true }
        onFailure(error)
      }
    }
  }
}

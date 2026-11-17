import CX11
import Foundation
import Glibc
import KVMContracts
import KVMCore
import LinuxPlatform

// M4-020-FOLLOWUP-001: the effects adapter between `ClientCoordinator` and the Linux backends
// (plan a.3, b.16). First-party policy:
//
// - `inject` and `moveLocalPointer` enqueue into a `LinuxInjectionDrain` (M4-024): a bounded
//   FIFO drained by one dedicated `Thread`. It replaces the plan's `CaptureQueue` because the
//   drain worker must be a `Thread`, never a cooperative-pool task (M1-063, h.6). A full or
//   stopped drain returns `false` and the coordinator fails closed.
// - Each session generation gets a new drain (`startSession()`); a stopped drain accepts nothing.
// - The terminal path (`ClientInputSafety`, M1-063) stops and joins the drain, drops queued
//   clipboard work, runs the ledger's plan through `release(_:)`, then the injector's own sweep
//   (`releaseRemaining()`, h.1). An `.unsupported` release counts as done (h.6).
// - Inbound clipboard text is written by one task, newest payload only.
// - Nothing here logs; the status lines carry no key, position or text.

/// The injector calls the runtime needs beyond C-015: the `ClientInputSafety` steps and the
/// final close. `LinuxX11Injector` provides them.
protocol ClientInjector: InputInjectionBackend {
  /// Injects one release and waits for the server.
  func release(_ event: KVMEvent) throws(CoreError)
  /// Releases everything the injector still holds (h.1).
  func releaseRemaining() throws(CoreError)
  /// Releases everything held, waits and closes the connection. `deinit` alone does not sweep,
  /// so the runtime always calls this before it drops the injector.
  func close() -> CoreResult<Void>
}

extension LinuxX11Injector: ClientInjector {}

/// Writes inbound clipboard text off the coordinator's lock: one task, the newest payload only.
final class ClientClipboardWriter: @unchecked Sendable {
  private let lock = NSLock()
  private let backend: any ClipboardBackend
  private let limit: ClipboardByteLimit
  private var pending: String?
  private var stopped = false
  private let kick: AsyncStream<Void>.Continuation
  private var worker: Task<Void, Never>?
  private var failures = 0

  init(backend: any ClipboardBackend, limit: ClipboardByteLimit) {
    self.backend = backend
    self.limit = limit
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    kick = continuation
    worker = Task { [weak self] in
      for await _ in stream {
        guard let self else { return }
        await self.writePending()
      }
    }
  }

  /// Queues `text`, replacing any text not yet written. `false` once stopped.
  func submit(_ text: String) -> Bool {
    let accepted = lock.withLock { () -> Bool in
      guard !stopped else { return false }
      pending = text
      return true
    }
    if accepted { kick.yield() }
    return accepted
  }

  /// Drops text not yet written (the terminal path).
  func dropPending() {
    lock.withLock { pending = nil }
  }

  /// Writes that failed, counted only.
  var failureCount: Int { lock.withLock { failures } }

  func stop() {
    lock.withLock {
      stopped = true
      pending = nil
    }
    kick.finish()
  }

  private func writePending() async {
    guard
      let text = lock.withLock({ () -> String? in
        defer { pending = nil }
        return pending
      })
    else { return }
    if case .failure = await backend.writePlainText(text, limit: limit) {
      lock.withLock { failures += 1 }
    }
  }
}

/// `ClientCoordinatorEffects` and `ClientInputSafety` over the Linux backends.
final class ClientEffects: ClientCoordinatorEffects, ClientInputSafety, @unchecked Sendable {
  /// Events a drain holds before `inject` fails closed.
  static let drainCapacity = 1_024

  private let lock = NSLock()
  private let injector: any ClientInjector
  private let clipboard: ClientClipboardWriter
  private let output: any ClientOutput
  private let onInjectionFailure: @Sendable (CoreError) -> Void
  private var drain: LinuxInjectionDrain
  private var closed = false
  private var displayGone = false

  /// `onInjectionFailure` runs on the drain's worker thread when the injector fails; it must
  /// return at once (the terminal path joins that worker).
  init(
    injector: any ClientInjector, clipboard: ClientClipboardWriter, output: any ClientOutput,
    onInjectionFailure: @escaping @Sendable (CoreError) -> Void
  ) {
    self.injector = injector
    self.clipboard = clipboard
    self.output = output
    self.onInjectionFailure = onInjectionFailure
    drain = Self.makeDrain(injector: injector, onFailure: onInjectionFailure)
    drain.start()
  }

  private static func makeDrain(
    injector: any ClientInjector, onFailure: @escaping @Sendable (CoreError) -> Void
  ) -> LinuxInjectionDrain {
    LinuxInjectionDrain(injector: injector, capacity: drainCapacity, onFailure: onFailure)
  }

  /// Gives the next session generation its own drain. Called after the previous generation's
  /// cleanup returned and before the new session exists.
  func startSession() {
    let fresh = Self.makeDrain(injector: injector, onFailure: onInjectionFailure)
    let started = lock.withLock { () -> Bool in
      guard !closed else { return false }
      drain = fresh
      return true
    }
    if started { fresh.start() }
  }

  /// The current drain's worker thread, for tests.
  var drainWorker: Thread? { lock.withLock { drain }.workerThread }

  private var currentDrain: LinuxInjectionDrain { lock.withLock { drain } }

  // MARK: ClientCoordinatorEffects

  func inject(_ event: KVMEvent) -> Bool {
    currentDrain.enqueue(event)
  }

  func moveLocalPointer(to position: NormalizedPoint) -> Bool {
    currentDrain.enqueue(.mouseMove(position: position))
  }

  func applyClipboard(_ payload: ClipboardPayload) -> Bool {
    clipboard.submit(payload.utf8Text)
  }

  func screenBecameActive() {
    output.status(.screenActive)
  }

  func screenBecameInactive() {
    output.status(.screenInactive)
  }

  // MARK: ClientInputSafety

  func clearTransientState() throws(CoreError) {
    currentDrain.clearTransientState()
    clipboard.dropPending()
  }

  func release(_ event: KVMEvent) throws(CoreError) {
    try requireDisplay()
    try injector.release(event)
  }

  func releaseRemaining() throws(CoreError) {
    try requireDisplay()
    try injector.releaseRemaining()
  }

  /// After a display loss no step touches Xlib: a call on the dead connection would enter the
  /// I/O error handler, and the X server that held the input is gone.
  private func requireDisplay() throws(CoreError) {
    if lock.withLock({ displayGone }) {
      throw CoreError(
        code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
        cleanupDisposition: .notRequired)
    }
  }

  /// Marks the display lost: later releases and the shutdown leave Xlib alone. `true` only for
  /// the first call.
  @discardableResult
  func markDisplayLost() -> Bool {
    lock.withLock {
      defer { displayGone = true }
      return !displayGone
    }
  }

  var isDisplayLost: Bool { lock.withLock { displayGone } }

  func restoreLocalInput() throws(CoreError) {}

  // MARK: Shutdown

  /// Stops the drain and the clipboard writer, then releases everything held and closes the
  /// injector's connection (its `deinit` does not sweep). After a display loss the injector is
  /// left alone. Idempotent.
  func shutdown() -> CoreResult<Void> {
    let (drain, gone) = lock.withLock { () -> (LinuxInjectionDrain?, Bool) in
      guard !closed else { return (nil, displayGone) }
      closed = true
      return (self.drain, displayGone)
    }
    guard let drain else { return .success(()) }
    clipboard.stop()
    guard !gone else { return .success(()) }
    drain.clearTransientState()
    return injector.close()
  }
}

// MARK: - Xlib process setup (plan a.3, h.8)

/// The process-wide Xlib setup the composition root owns.
protocol ClientXlibSetup: Sendable {
  /// `XInitThreads()`; must run before any `Display` is opened. `false` when it failed.
  func initializeThreads() -> Bool
  /// Installs the root's error and I/O error handlers, keeping the previous ones.
  func installHandlers(onDisplayLost: @escaping @Sendable () -> Void)
  /// Puts the previous handlers back.
  func restoreHandlers()
}

/// The live setup: `XInitThreads`, `XSetErrorHandler`, `XSetIOErrorHandler`.
struct ClientXlib: ClientXlibSetup {
  func initializeThreads() -> Bool { XInitThreads() != 0 }

  func installHandlers(onDisplayLost: @escaping @Sendable () -> Void) {
    ClientXErrorHandlers.install(
      setError: { XSetErrorHandler($0) }, setIOError: { XSetIOErrorHandler($0) },
      onDisplayLost: onDisplayLost)
  }

  func restoreHandlers() {
    ClientXErrorHandlers.restore(
      setError: { XSetErrorHandler($0) }, setIOError: { XSetIOErrorHandler($0) })
  }
}

/// The root of the process's Xlib error-handler chain (h.8).
///
/// - It is installed after `XInitThreads()` and before any backend opens a display, so every
///   backend's scoped handler (M4-026) chains to it. The previous handlers (Xlib's defaults,
///   which exit the process) are kept and put back by `restore`, after every backend stopped.
/// - The root owns every display of the process, so it is the end of the chain: a protocol
///   error is counted and ignored, never forwarded to Xlib's default, which would exit with
///   input still held. Every Xlib call that matters is checked by its result.
/// - An I/O error means the display is gone. The handler reports display loss once, then parks
///   the calling thread: returning would let Xlib exit the process before the cleanup. The
///   runtime runs the cleanup without touching Xlib and exits 69 (bounded).
enum ClientXErrorHandlers {
  typealias SetError = (XErrorHandler?) -> XErrorHandler?
  typealias SetIOError = (XIOErrorHandler?) -> XIOErrorHandler?

  private static let lock = NSLock()
  nonisolated(unsafe) private static var installed = false
  nonisolated(unsafe) private static var previousError: XErrorHandler?
  nonisolated(unsafe) private static var previousIOError: XIOErrorHandler?
  nonisolated(unsafe) private static var displayLost: (@Sendable () -> Void)?
  nonisolated(unsafe) private static var reported = false
  nonisolated(unsafe) private static var errors = 0

  static func install(
    setError: SetError, setIOError: SetIOError, onDisplayLost: @escaping @Sendable () -> Void
  ) {
    lock.withLock {
      guard !installed else { return }
      installed = true
      reported = false
      displayLost = onDisplayLost
      previousError = setError(clientErrorHandler)
      previousIOError = setIOError(clientIOErrorHandler)
    }
  }

  static func restore(setError: SetError, setIOError: SetIOError) {
    lock.withLock {
      guard installed else { return }
      installed = false
      _ = setError(previousError)
      _ = setIOError(previousIOError)
      previousError = nil
      previousIOError = nil
      displayLost = nil
    }
  }

  /// Protocol errors seen since the process started, counted only.
  static var errorCount: Int { lock.withLock { errors } }

  /// The protocol error handler's body: counted, never forwarded.
  static func handleError() -> Int32 {
    lock.withLock { errors += 1 }
    return 0
  }

  /// The I/O error handler's body: reports display loss once. Returns whether it reported.
  @discardableResult
  static func handleIOError() -> Bool {
    let callback = lock.withLock { () -> (@Sendable () -> Void)? in
      guard !reported else { return nil }
      reported = true
      return displayLost
    }
    callback?()
    return callback != nil
  }
}

private func clientErrorHandler(
  _ display: OpaquePointer?, _ event: UnsafeMutablePointer<XErrorEvent>?
) -> Int32 {
  ClientXErrorHandlers.handleError()
}

private func clientIOErrorHandler(_ display: OpaquePointer?) -> Int32 {
  ClientXErrorHandlers.handleIOError()
  // Never return: Xlib exits the process when this handler returns. The runtime exits.
  while true { _ = pause() }
}

// MARK: - Bootstrap

/// Opens one backend each; production opens the Linux backends, tests open fakes.
struct ClientBackendFactory: Sendable {
  var screen: @Sendable (String?) throws(CoreError) -> any ScreenBackend
  var injector: @Sendable (String?, ClientGeometryCache) throws(CoreError) -> any ClientInjector
  var clipboard: @Sendable (String?) throws(CoreError) -> any ClipboardBackend
  var lifecycle: @Sendable () -> any ClientLifecycle

  static let live = ClientBackendFactory(
    screen: { name throws(CoreError) in try LinuxScreenBackend(displayName: name) },
    injector: { name, cache throws(CoreError) in
      try LinuxX11Injector(displayName: name, screen: { cache.current })
    },
    clipboard: { name throws(CoreError) in try LinuxX11Clipboard(displayName: name) },
    lifecycle: { LinuxLifecycleMonitor() })
}

/// Opens the backends in the order h.8 requires: `XInitThreads()`, then the root's error
/// handlers, then the displays (screen, injector, clipboard).
enum ClientBootstrap {
  static func open(
    displayName: String?, xlib: any ClientXlibSetup, factory: ClientBackendFactory,
    onDisplayLost: @escaping @Sendable () -> Void
  ) async -> Result<ClientBackends, CoreError> {
    guard xlib.initializeThreads() else {
      return .failure(
        CoreError(
          code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
          cleanupDisposition: .notRequired))
    }
    xlib.installHandlers(onDisplayLost: onDisplayLost)
    let screen: any ScreenBackend
    do throws(CoreError) {
      screen = try factory.screen(displayName)
    } catch {
      xlib.restoreHandlers()
      return .failure(error)
    }
    let geometry: ClientGeometryCache
    switch screen.currentGeometry() {
    case .success(let value):
      geometry = ClientGeometryCache(value)
    case .failure(let error):
      await screen.stop()
      xlib.restoreHandlers()
      return .failure(error)
    }
    let injector: any ClientInjector
    do throws(CoreError) {
      injector = try factory.injector(displayName, geometry)
    } catch {
      await screen.stop()
      xlib.restoreHandlers()
      return .failure(error)
    }
    let clipboard: any ClipboardBackend
    do throws(CoreError) {
      clipboard = try factory.clipboard(displayName)
    } catch {
      _ = injector.close()
      await screen.stop()
      xlib.restoreHandlers()
      return .failure(error)
    }
    return .success(
      ClientBackends(
        injector: injector, screen: screen, clipboard: clipboard, lifecycle: factory.lifecycle(),
        geometry: geometry))
  }
}

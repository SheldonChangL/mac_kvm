import CX11
import CXFixes
import Crypto
import Foundation
import Glibc
import KVMContracts

// M4-026: the Linux X11 clipboard backend (C-015 `ClipboardBackend`, C-007 plain text).
//
// First-party design (plan b.13, decision 10):
// - In-process Xlib selection ownership on a private, unmapped window; no `xclip` subprocess.
// - Only the CLIPBOARD selection and only UTF-8 text. PRIMARY is not synchronized.
// - Served targets: TARGETS, UTF8_STRING, text/plain;charset=utf-8, and STRING only when the
//   text is Latin-1 representable. Content above a quarter of the maximum request size goes
//   out with INCR. Reads ask for UTF8_STRING and reassemble INCR, refusing as soon as the
//   stated size or the bytes received so far pass the caller's limit.
// - A read is bounded by a 2 s deadline, renewed while an INCR transfer makes progress; the
//   deadline is kept on the private thread with the monotonic clock (no `KVMClock`).
// - `ownerChanges` comes from XFixes selection-owner notifications on CLIPBOARD and never
//   fires for this backend's own window.
// - All X traffic happens on one private `Thread` that owns the `Display*`. API calls hop to
//   it through a mailbox and a wake pipe. Nothing here logs content or hashes (Frozen
//   Decision 8).

/// The pure rules of the X11 clipboard backend, kept apart so they are testable without a
/// display.
package enum LinuxX11ClipboardRules {
  /// How long a read waits for the clipboard's owner to hand content over. An INCR transfer
  /// renews the deadline with every chunk it receives.
  package static let readTimeout: Duration = .seconds(2)

  /// How long an outgoing INCR transfer waits for the requestor to take the next chunk.
  package static let outgoingTransferTimeout: Duration = .seconds(5)

  /// The targets a `TARGETS` request is answered with, in order.
  package static func servedTargetNames(latin1Representable: Bool) -> [String] {
    var names = ["TARGETS", "UTF8_STRING", "text/plain;charset=utf-8"]
    if latin1Representable {
      names.append("STRING")
    }
    return names
  }

  /// The ISO 8859-1 bytes of `text`, or `nil` when a scalar is above U+00FF.
  package static func latin1Bytes(of text: String) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.unicodeScalars.count)
    for scalar in text.unicodeScalars {
      guard scalar.value <= 0xFF else { return nil }
      bytes.append(UInt8(scalar.value))
    }
    return bytes
  }

  /// The lowercase hexadecimal SHA-256 digest of the text's UTF-8 bytes (C-015).
  package static func contentHash(of text: String) -> String {
    SHA256.hash(data: Array(text.utf8)).map { byte in
      let hex = String(byte, radix: 16)
      return byte < 0x10 ? "0" + hex : hex
    }.joined()
  }

  /// The largest property written in one request: a quarter of the maximum request size.
  /// `XMaxRequestSize` counts 4-byte units, so that quarter in bytes is the unit count. It is
  /// never below 4096 bytes.
  package static func incrChunkByteCount(maxRequestUnits: Int) -> Int {
    max(maxRequestUnits, 4096)
  }

  /// Whether content of `byteCount` bytes goes out with INCR.
  package static func usesINCR(byteCount: Int, chunkByteCount: Int) -> Bool {
    byteCount > chunkByteCount
  }
}

// MARK: - Errors

private func clipboardError(_ code: CoreErrorCode) -> CoreError {
  let retry: RetryDisposition
  switch code {
  case .timeout:
    retry = .backoff
  default:
    retry = .never
  }
  return CoreError(
    code: code, severity: .warning, retryDisposition: retry, cleanupDisposition: .notRequired)
}

// MARK: - Xlib constants (X.h), spelled out because the shim imports only Xlib.h

private enum X {
  static let none: UInt = 0
  static let currentTime: UInt = 0
  static let propertyChangeMask = 1 << 22
  static let propertyNotify: Int32 = 28
  static let selectionClear: Int32 = 29
  static let selectionRequest: Int32 = 30
  static let selectionNotify: Int32 = 31
  static let propertyNewValue: Int32 = 0
  static let propertyDelete: Int32 = 1
  static let propModeReplace: Int32 = 0
  static let anyPropertyType: UInt = 0
  static let success: Int32 = 0
  static let xfixesSetSelectionOwnerNotifyMask: UInt = 1
  static let xfixesSelectionNotify: Int32 = 0
}

/// Scopes Xlib's process-wide error handler to the clipboards' own displays.
///
/// Xlib's default error handler exits the process, and a requestor window can disappear while
/// it is being served, so errors on a clipboard's display are ignored; every call that matters
/// is checked by its result. Errors on any other display are passed to the handler that was
/// installed before the first clipboard registered, so other Xlib users (the screen backend,
/// the injector) keep their own error handling. When the last clipboard unregisters, that
/// previous handler is put back. A handler installed by someone else while a clipboard is
/// registered is replaced by that restore; the composition root installs its handlers first.
enum ClipboardXErrorScope {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var displays: Set<UInt> = []
  nonisolated(unsafe) private static var previous: XErrorHandler?

  static func register(_ display: OpaquePointer) {
    lock.withLock {
      if displays.isEmpty {
        previous = XSetErrorHandler(scopedHandler)
      }
      displays.insert(UInt(bitPattern: display))
    }
  }

  static func unregister(_ display: OpaquePointer) {
    lock.withLock {
      guard displays.remove(UInt(bitPattern: display)) != nil, displays.isEmpty else { return }
      XSetErrorHandler(previous)
      previous = nil
    }
  }

  fileprivate static func handle(
    _ display: OpaquePointer?, _ event: UnsafeMutablePointer<XErrorEvent>?
  ) -> Int32 {
    let (ours, chained) = lock.withLock { () -> (Bool, XErrorHandler?) in
      (display.map { displays.contains(UInt(bitPattern: $0)) } ?? false, previous)
    }
    guard !ours, let chained else { return 0 }
    return chained(display, event)
  }
}

private func scopedHandler(_ display: OpaquePointer?, _ event: UnsafeMutablePointer<XErrorEvent>?)
  -> Int32
{
  ClipboardXErrorScope.handle(display, event)
}

// MARK: - Backend

/// The X11 `CLIPBOARD` as a `ClipboardBackend`.
///
/// Requirement on the composition root (M4-020-FOLLOWUP-001): call `XInitThreads()` once,
/// before any `Display` is opened by any backend. This backend does not call it. The
/// owner calls `stop()` when done; dropping the last reference also stops the private thread,
/// without waiting for it.
package final class LinuxX11Clipboard: ClipboardBackend, @unchecked Sendable {
  package let ownerChanges: AsyncStream<Void>
  private let engine: ClipboardEngine

  /// Opens `displayName` (`nil` uses `DISPLAY`).
  ///
  /// - Throws: `lifecycle.subsystemUnavailable` when the display cannot be opened or the
  ///   private window cannot be made; `permission.capabilityUnavailable` without XFixes.
  package init(displayName: String?) throws(CoreError) {
    let (stream, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    engine = try ClipboardEngine(displayName: displayName, ownerChanges: continuation)
    ownerChanges = stream
    engine.start()
  }

  /// Content bytes this backend has fetched from other owners' answers since it was made.
  /// Tests use it to show that a refused read fetched nothing; it never carries content.
  package var transferredByteCount: Int { engine.transferredByteCount }

  deinit {
    engine.requestStop()
  }

  package func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?>
  {
    guard !Task.isCancelled else {
      return .failure(clipboardError(.cancellation(.requested)))
    }
    let byteLimit = limit.byteCount
    return await withCheckedContinuation { continuation in
      engine.submit(.read(limit: byteLimit) { continuation.resume(returning: $0) })
    }
  }

  package func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void> {
    guard !Task.isCancelled else {
      return .failure(clipboardError(.cancellation(.requested)))
    }
    guard text.utf8.count <= limit.byteCount else {
      return .failure(clipboardError(.clipboard(.oversized)))
    }
    let content = OwnedContent(
      utf8: Array(text.utf8), latin1: LinuxX11ClipboardRules.latin1Bytes(of: text))
    return await withCheckedContinuation { continuation in
      engine.submit(.write(content) { continuation.resume(returning: $0) })
    }
  }

  package func stop() async {
    await withCheckedContinuation { continuation in
      engine.stop { continuation.resume() }
    }
  }
}

// MARK: - Engine

private struct OwnedContent: Sendable {
  let utf8: [UInt8]
  let latin1: [UInt8]?
}

private enum Command: Sendable {
  case read(limit: Int, reply: @Sendable (CoreResult<PlatformClipboardText?>) -> Void)
  case write(OwnedContent, reply: @Sendable (CoreResult<Void>) -> Void)

  func refuse(_ error: CoreError) {
    switch self {
    case .read(_, let reply):
      reply(.failure(error))
    case .write(_, let reply):
      reply(.failure(error))
    }
  }
}

/// The state of the one read in progress.
private struct ReadInProgress {
  enum Phase {
    case awaitingNotify
    case incr(received: [UInt8])
  }

  let limit: Int
  let reply: @Sendable (CoreResult<PlatformClipboardText?>) -> Void
  var phase: Phase
  var deadline: ContinuousClock.Instant
}

/// One INCR transfer this backend serves to a requestor.
private struct OutgoingTransfer {
  let requestor: Window
  let property: Atom
  let type: Atom
  let bytes: [UInt8]
  var offset: Int
  var deadline: ContinuousClock.Instant
}

private final class ClipboardEngine: @unchecked Sendable {
  // Set in init, then used only on the private thread.
  private let display: OpaquePointer
  private let window: Window
  private let xfixesEventBase: Int32
  private let atoms: Atoms
  private let chunkByteCount: Int
  private let wakeRead: Int32
  private let wakeWrite: Int32
  private let ownerChanges: AsyncStream<Void>.Continuation

  // Shared with callers, guarded by `lock`.
  private let lock = NSLock()
  private var mailbox: [Command] = []
  private var stopRequested = false
  private var exited = false
  private var stopWaiters: [@Sendable () -> Void] = []
  private var fetchedByteCount = 0

  var transferredByteCount: Int { lock.withLock { fetchedByteCount } }

  // Private thread only.
  private var owned: OwnedContent?
  private var read: ReadInProgress?
  private var queuedReads: [Command] = []
  private var readPropertyIndex = 0
  private var readProperty: Atom { atoms.readProperties[readPropertyIndex] }
  private var transfers: [OutgoingTransfer] = []

  struct Atoms {
    let clipboard: Atom
    let targets: Atom
    let utf8String: Atom
    let textPlain: Atom
    let string: Atom
    let incr: Atom
    let atom: Atom
    /// Reads rotate through these properties, so an abandoned transfer that the owner keeps
    /// writing, or a late answer to a timed-out read, never lands in the next read's property.
    let readProperties: [Atom]
  }

  init(displayName: String?, ownerChanges: AsyncStream<Void>.Continuation) throws(CoreError) {
    guard let display = XOpenDisplay(displayName) else {
      throw clipboardError(.lifecycle(.subsystemUnavailable))
    }
    var eventBase: Int32 = 0
    var errorBase: Int32 = 0
    guard XFixesQueryExtension(display, &eventBase, &errorBase) != 0 else {
      XCloseDisplay(display)
      throw clipboardError(.permission(.capabilityUnavailable))
    }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else {
      XCloseDisplay(display)
      throw clipboardError(.lifecycle(.subsystemUnavailable))
    }
    _ = fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK)
    _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
    ClipboardXErrorScope.register(display)
    let root = XDefaultRootWindow(display)
    let window = XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0)
    guard window != X.none else {
      close(fds[0])
      close(fds[1])
      XCloseDisplay(display)
      ClipboardXErrorScope.unregister(display)
      throw clipboardError(.lifecycle(.subsystemUnavailable))
    }
    XSelectInput(display, window, X.propertyChangeMask)
    func intern(_ name: String) -> Atom { XInternAtom(display, name, 0) }
    atoms = Atoms(
      clipboard: intern("CLIPBOARD"), targets: intern("TARGETS"),
      utf8String: intern("UTF8_STRING"), textPlain: intern("text/plain;charset=utf-8"),
      string: intern("STRING"), incr: intern("INCR"), atom: intern("ATOM"),
      readProperties: (0..<4).map { intern("MACKVM_CLIPBOARD_READ_\($0)") })
    XFixesSelectSelectionInput(
      display, window, atoms.clipboard, X.xfixesSetSelectionOwnerNotifyMask)
    XSync(display, 0)
    self.display = display
    self.window = window
    xfixesEventBase = eventBase
    chunkByteCount = LinuxX11ClipboardRules.incrChunkByteCount(
      maxRequestUnits: XMaxRequestSize(display))
    wakeRead = fds[0]
    wakeWrite = fds[1]
    self.ownerChanges = ownerChanges
  }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "mackvm.x11-clipboard"
    thread.start()
  }

  func submit(_ command: Command) {
    let accepted = lock.withLock { () -> Bool in
      guard !stopRequested else { return false }
      mailbox.append(command)
      return true
    }
    guard accepted else {
      command.refuse(clipboardError(.lifecycle(.subsystemUnavailable)))
      return
    }
    wake()
  }

  /// Asks the thread to stop and calls `done` once it has released the display.
  func stop(_ done: @escaping @Sendable () -> Void) {
    let finished = lock.withLock { () -> Bool in
      stopRequested = true
      guard !exited else { return true }
      stopWaiters.append(done)
      return false
    }
    if finished {
      done()
    } else {
      wake()
    }
  }

  func requestStop() {
    lock.withLock { stopRequested = true }
    wake()
  }

  private func wake() {
    var byte: UInt8 = 1
    _ = write(wakeWrite, &byte, 1)
  }

  // MARK: Thread

  private func run() {
    var event = XEvent()
    var displayLost = false
    while true {
      let (commands, stopping) = lock.withLock { () -> ([Command], Bool) in
        defer { mailbox.removeAll() }
        return (mailbox, stopRequested)
      }
      if stopping {
        for command in commands {
          command.refuse(clipboardError(.lifecycle(.subsystemUnavailable)))
        }
        break
      }
      for command in commands {
        handle(command)
      }
      while XPending(display) > 0 {
        XNextEvent(display, &event)
        handle(event: &event)
      }
      expireDeadlines()
      startQueuedRead()
      XFlush(display)
      if !waitForActivity() {
        displayLost = true
        break
      }
    }
    shutDown(displayLost: displayLost)
  }

  /// Blocks until the display or the wake pipe is readable or the nearest deadline passes.
  /// Returns `false` when the display connection is gone.
  private func waitForActivity() -> Bool {
    if XPending(display) > 0 { return true }
    var fds = [
      pollfd(fd: XConnectionNumber(display), events: Int16(POLLIN), revents: 0),
      pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
    ]
    let result = poll(&fds, 2, timeoutMilliseconds())
    if result > 0 && fds[1].revents != 0 {
      var buffer = [UInt8](repeating: 0, count: 64)
      while Glibc.read(wakeRead, &buffer, buffer.count) > 0 {}
    }
    let lost = Int16(POLLHUP | POLLERR | POLLNVAL)
    return result <= 0 || fds[0].revents & lost == 0
  }

  private func timeoutMilliseconds() -> Int32 {
    let deadlines = transfers.map(\.deadline) + (read.map { [$0.deadline] } ?? [])
    guard let nearest = deadlines.min() else { return -1 }
    let remaining = nearest - ContinuousClock.now
    let milliseconds =
      remaining.components.seconds * 1000
      + remaining.components.attoseconds / 1_000_000_000_000_000 + 1
    return Int32(clamping: max(milliseconds, 0))
  }

  private func shutDown(displayLost: Bool) {
    let unavailable = clipboardError(.lifecycle(.subsystemUnavailable))
    read?.reply(.failure(unavailable))
    read = nil
    for command in queuedReads {
      command.refuse(unavailable)
    }
    queuedReads.removeAll()
    transfers.removeAll()
    owned = nil
    if !displayLost {
      if XGetSelectionOwner(display, atoms.clipboard) == window {
        XSetSelectionOwner(display, atoms.clipboard, X.none, X.currentTime)
      }
      XDestroyWindow(display, window)
      XSync(display, 0)
    }
    XCloseDisplay(display)
    ClipboardXErrorScope.unregister(display)
    ownerChanges.finish()
    let (late, waiters) = lock.withLock { () -> ([Command], [@Sendable () -> Void]) in
      stopRequested = true
      exited = true
      defer {
        mailbox.removeAll()
        stopWaiters.removeAll()
      }
      return (mailbox, stopWaiters)
    }
    for command in late {
      command.refuse(unavailable)
    }
    close(wakeRead)
    close(wakeWrite)
    for waiter in waiters {
      waiter()
    }
  }

  private func handle(_ command: Command) {
    switch command {
    case .read:
      queuedReads.append(command)
    case .write(let content, let reply):
      XSetSelectionOwner(display, atoms.clipboard, window, X.currentTime)
      guard XGetSelectionOwner(display, atoms.clipboard) == window else {
        reply(.failure(clipboardError(.lifecycle(.subsystemUnavailable))))
        return
      }
      owned = content
      reply(.success(()))
    }
  }

  private func handle(event: inout XEvent) {
    switch event.type {
    case X.selectionRequest:
      serve(event.xselectionrequest)
    case X.selectionNotify:
      receiveNotify(event.xselection)
    case X.propertyNotify:
      propertyChanged(event.xproperty)
    case X.selectionClear:
      if event.xselectionclear.window == window
        && event.xselectionclear.selection == atoms.clipboard
      {
        owned = nil
      }
    case xfixesEventBase + X.xfixesSelectionNotify:
      let notify = withUnsafePointer(to: &event) { pointer in
        pointer.withMemoryRebound(to: XFixesSelectionNotifyEvent.self, capacity: 1) {
          $0.pointee
        }
      }
      if notify.selection == atoms.clipboard && notify.owner != X.none
        && notify.owner != window
      {
        ownerChanges.yield()
      }
    default:
      break
    }
  }

  // MARK: Reading

  private func startQueuedRead() {
    while read == nil, !queuedReads.isEmpty {
      guard case .read(let limit, let reply) = queuedReads.removeFirst() else { continue }
      let owner = XGetSelectionOwner(display, atoms.clipboard)
      if owner == X.none {
        reply(.success(nil))
        continue
      }
      if owner == window, let owned {
        reply(decode(owned.utf8, limit: limit))
        continue
      }
      readPropertyIndex = (readPropertyIndex + 1) % atoms.readProperties.count
      XDeleteProperty(display, window, readProperty)
      XConvertSelection(
        display, atoms.clipboard, atoms.utf8String, readProperty, window, X.currentTime)
      read = ReadInProgress(
        limit: limit, reply: reply, phase: .awaitingNotify,
        deadline: .now + LinuxX11ClipboardRules.readTimeout)
    }
  }

  private func finishRead(_ result: CoreResult<PlatformClipboardText?>) {
    guard let current = read else { return }
    read = nil
    current.reply(result)
  }

  private func receiveNotify(_ notify: XSelectionEvent) {
    guard let current = read, case .awaitingNotify = current.phase,
      notify.requestor == window, notify.selection == atoms.clipboard,
      notify.property == X.none || notify.property == readProperty
    else { return }
    guard notify.property != X.none else {
      // The owner has no UTF-8 text.
      finishRead(.success(nil))
      return
    }
    guard let header = propertyHeader() else {
      finishRead(.success(nil))
      return
    }
    if header.type == atoms.incr {
      let stated = incrStatedSize()
      guard stated <= current.limit else {
        finishRead(.failure(clipboardError(.clipboard(.oversized))))
        return
      }
      read?.phase = .incr(received: [])
      read?.deadline = .now + LinuxX11ClipboardRules.readTimeout
      // Deleting the INCR property asks the owner for the first chunk.
      XDeleteProperty(display, window, readProperty)
      return
    }
    guard header.format == 8 else {
      XDeleteProperty(display, window, readProperty)
      finishRead(.failure(clipboardError(.clipboard(.unsupportedType))))
      return
    }
    guard header.byteCount <= current.limit else {
      XDeleteProperty(display, window, readProperty)
      finishRead(.failure(clipboardError(.clipboard(.oversized))))
      return
    }
    let bytes = takeProperty(byteCount: header.byteCount)
    finishRead(decode(bytes, limit: current.limit))
  }

  private func propertyChanged(_ event: XPropertyEvent) {
    if event.window == window {
      incomingChunk(event)
    } else if event.state == X.propertyDelete {
      sendNextChunk(requestor: event.window, property: event.atom)
    }
  }

  private func incomingChunk(_ event: XPropertyEvent) {
    guard let current = read, case .incr(let received) = current.phase,
      event.atom == readProperty, event.state == X.propertyNewValue
    else { return }
    guard let header = propertyHeader() else { return }
    guard header.format == 8 || header.byteCount == 0 else {
      XDeleteProperty(display, window, readProperty)
      finishRead(.failure(clipboardError(.clipboard(.unsupportedType))))
      return
    }
    if header.byteCount == 0 {
      XDeleteProperty(display, window, readProperty)
      finishRead(decode(received, limit: current.limit))
      return
    }
    guard received.count + header.byteCount <= current.limit else {
      XDeleteProperty(display, window, readProperty)
      finishRead(.failure(clipboardError(.clipboard(.oversized))))
      return
    }
    // Clear the phase first so the array is not copied when it grows.
    read?.phase = .awaitingNotify
    var accumulated = received
    accumulated += takeProperty(byteCount: header.byteCount)
    read?.phase = .incr(received: accumulated)
    read?.deadline = .now + LinuxX11ClipboardRules.readTimeout
  }

  private func decode(_ bytes: [UInt8], limit: Int) -> CoreResult<PlatformClipboardText?> {
    guard let byteLimit = ClipboardByteLimit(byteCount: limit) else {
      return .failure(clipboardError(.clipboard(.oversized)))
    }
    do {
      let text = try ClipboardTextCodec.decode(Data(bytes), limit: byteLimit)
      return .success(
        PlatformClipboardText(text: text, contentHash: LinuxX11ClipboardRules.contentHash(of: text))
      )
    } catch let error as CoreError {
      return .failure(error)
    } catch {
      return .failure(clipboardError(.internalFailure(.unclassified)))
    }
  }

  /// The read property's type, format and size in bytes, without transferring its content.
  private func propertyHeader() -> (type: Atom, format: Int32, byteCount: Int)? {
    var type: Atom = 0
    var format: Int32 = 0
    var items: UInt = 0
    var after: UInt = 0
    var data: UnsafeMutablePointer<UInt8>?
    let status = XGetWindowProperty(
      display, window, readProperty, 0, 0, 0, X.anyPropertyType, &type, &format, &items,
      &after, &data)
    if let data { XFree(data) }
    guard status == X.success, type != X.none else { return nil }
    return (type, format, Int(after))
  }

  /// The size an INCR property states: a lower bound on the content's size.
  private func incrStatedSize() -> Int {
    var type: Atom = 0
    var format: Int32 = 0
    var items: UInt = 0
    var after: UInt = 0
    var data: UnsafeMutablePointer<UInt8>?
    let status = XGetWindowProperty(
      display, window, readProperty, 0, 1, 0, atoms.incr, &type, &format, &items, &after,
      &data)
    defer { if let data { XFree(data) } }
    guard status == X.success, format == 32, items >= 1, let data else { return 0 }
    // Format-32 data comes back as C longs.
    return data.withMemoryRebound(to: Int.self, capacity: 1) {
      Int(UInt32(truncatingIfNeeded: $0.pointee))
    }
  }

  /// Reads and deletes the read property, whose size the caller already checked.
  private func takeProperty(byteCount: Int) -> [UInt8] {
    var type: Atom = 0
    var format: Int32 = 0
    var items: UInt = 0
    var after: UInt = 0
    var data: UnsafeMutablePointer<UInt8>?
    let length = (byteCount + 3) / 4
    let status = XGetWindowProperty(
      display, window, readProperty, 0, length, 1, X.anyPropertyType, &type, &format,
      &items, &after, &data)
    defer { if let data { XFree(data) } }
    guard status == X.success, format == 8, let data else { return [] }
    let bytes = Array(UnsafeBufferPointer(start: data, count: min(Int(items), byteCount)))
    lock.withLock { fetchedByteCount += bytes.count }
    return bytes
  }

  // MARK: Serving

  private func serve(_ request: XSelectionRequestEvent) {
    var reply = XEvent()
    reply.xselection.type = X.selectionNotify
    reply.xselection.display = display
    reply.xselection.requestor = request.requestor
    reply.xselection.selection = request.selection
    reply.xselection.target = request.target
    reply.xselection.time = request.time
    reply.xselection.property = X.none
    // Obsolete requestors name no property; ICCCM says to use the target atom then.
    let property = request.property != X.none ? request.property : request.target
    if request.selection == atoms.clipboard, request.owner == window, let owned,
      answer(request, content: owned, property: property)
    {
      reply.xselection.property = property
    }
    XSendEvent(display, request.requestor, 0, 0, &reply)
  }

  /// Writes the answer into the requestor's property. Returns `false` to refuse the target.
  private func answer(
    _ request: XSelectionRequestEvent, content: OwnedContent, property: Atom
  ) -> Bool {
    let bytes: [UInt8]
    let type: Atom
    switch request.target {
    case atoms.targets:
      var list = [atoms.targets, atoms.utf8String, atoms.textPlain]
      if content.latin1 != nil {
        list.append(atoms.string)
      }
      let longs = list.map { Int(bitPattern: $0) }
      longs.withUnsafeBytes { raw in
        _ = XChangeProperty(
          display, request.requestor, property, atoms.atom, 32, X.propModeReplace,
          raw.bindMemory(to: UInt8.self).baseAddress, Int32(longs.count))
      }
      return true
    case atoms.utf8String, atoms.textPlain:
      bytes = content.utf8
      type = request.target
    case atoms.string:
      guard let latin1 = content.latin1 else { return false }
      bytes = latin1
      type = atoms.string
    default:
      return false
    }
    if LinuxX11ClipboardRules.usesINCR(byteCount: bytes.count, chunkByteCount: chunkByteCount) {
      XSelectInput(display, request.requestor, X.propertyChangeMask)
      let size = [bytes.count]
      size.withUnsafeBytes { raw in
        _ = XChangeProperty(
          display, request.requestor, property, atoms.incr, 32, X.propModeReplace,
          raw.bindMemory(to: UInt8.self).baseAddress, 1)
      }
      transfers.removeAll { $0.requestor == request.requestor && $0.property == property }
      transfers.append(
        OutgoingTransfer(
          requestor: request.requestor, property: property, type: type, bytes: bytes,
          offset: 0,
          deadline: .now + LinuxX11ClipboardRules.outgoingTransferTimeout))
    } else {
      bytes.withUnsafeBufferPointer { buffer in
        _ = XChangeProperty(
          display, request.requestor, property, type, 8, X.propModeReplace, buffer.baseAddress,
          Int32(bytes.count))
      }
    }
    return true
  }

  private func sendNextChunk(requestor: Window, property: Atom) {
    guard
      let index = transfers.firstIndex(where: {
        $0.requestor == requestor && $0.property == property
      })
    else { return }
    let transfer = transfers[index]
    let end = min(transfer.offset + chunkByteCount, transfer.bytes.count)
    transfer.bytes.withUnsafeBufferPointer { buffer in
      _ = XChangeProperty(
        display, requestor, property, transfer.type, 8, X.propModeReplace,
        buffer.baseAddress.map { $0 + transfer.offset }, Int32(end - transfer.offset))
    }
    // The zero-length chunk written once every byte is out ends the transfer.
    if end == transfer.offset {
      endTransfer(at: index)
      return
    }
    transfers[index].offset = end
    transfers[index].deadline = .now + LinuxX11ClipboardRules.outgoingTransferTimeout
  }

  private func endTransfer(at index: Int) {
    let requestor = transfers.remove(at: index).requestor
    if !transfers.contains(where: { $0.requestor == requestor }) {
      XSelectInput(display, requestor, 0)
    }
  }

  private func expireDeadlines() {
    let now = ContinuousClock.now
    if let current = read, current.deadline <= now {
      finishRead(.failure(clipboardError(.timeout(.read))))
    }
    while let index = transfers.firstIndex(where: { $0.deadline <= now }) {
      endTransfer(at: index)
    }
  }
}

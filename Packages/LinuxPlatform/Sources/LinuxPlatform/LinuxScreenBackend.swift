#if os(Linux)
  import CX11
  import CXRandR
  import Foundation
  import Glibc
  import KVMContracts

  // M4-027: the Linux screen backend (C-015 `ScreenBackend`).
  //
  // - Geometry is the root window of the default screen. X11 has one desktop rectangle whose
  //   origin is always (0, 0); there is no per-monitor identity and no scale, because X11 pixel
  //   coordinates are what the Barrier DINF message carries (first-party policy, plan b.11).
  // - The size is read with `XGetGeometry` on the root window, not from Xlib's cached screen
  //   structure, so it is current without `XRRUpdateConfiguration` bookkeeping. The pointer comes
  //   from `XQueryPointer`.
  // - RandR is used only for `RRScreenChangeNotify`. The backend owns two connections: a query
  //   connection guarded by a lock, and an event connection that only the private event thread
  //   touches, so no Xlib call from two threads shares a connection and `XInitThreads` is not
  //   needed here.
  // - The event thread never blocks inside Xlib: it polls the event connection and a wake pipe,
  //   so `stop()` can end it, and it checks the connection for end-of-file before it lets Xlib
  //   read (Xlib's default handler would terminate the process on a lost display).

  /// The errors this backend reports. All are terminal and need no cleanup.
  package enum LinuxScreenError {
    /// The display cannot be opened, has gone away, or the backend was stopped.
    package static let subsystemUnavailable = CoreError(
      code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
      cleanupDisposition: .notRequired)

    /// A reported size outside the DINF range.
    package static let invariantViolation = CoreError(
      code: .protocolViolation(.invariantViolation), severity: .error, retryDisposition: .never,
      cleanupDisposition: .notRequired)

    /// The X server has no RandR extension, so a change could not be observed.
    package static let capabilityUnavailable = CoreError(
      code: .permission(.capabilityUnavailable), severity: .error, retryDisposition: .never,
      cleanupDisposition: .notRequired)
  }

  /// Pure rules of the screen backend, kept free of Xlib so they run without a display.
  package enum LinuxScreenGeometryRules {
    /// The largest width or height a DINF message can carry (M1-PROTOCOL-003: 16-bit, so 0x7FFF).
    package static let maximumDimension = 0x7FFF

    /// Builds the geometry of an X11 desktop of this size, or fails when the size is outside
    /// `1...maximumDimension`. The origin of an X11 root window is always (0, 0).
    package static func geometry(
      width: Int, height: Int, cursorX: Int, cursorY: Int
    ) -> CoreResult<PlatformScreenGeometry> {
      let range = 1...maximumDimension
      guard range.contains(width), range.contains(height) else {
        return .failure(LinuxScreenError.invariantViolation)
      }
      return .success(
        PlatformScreenGeometry(
          originX: 0, originY: 0, width: width, height: height, cursorX: cursorX,
          cursorY: cursorY))
    }

    /// Whether the desktop's origin or size differs. Pointer movement alone is not a change.
    package static func hasChanged(
      from old: PlatformScreenGeometry, to new: PlatformScreenGeometry
    ) -> Bool {
      old.originX != new.originX || old.originY != new.originY || old.width != new.width
        || old.height != new.height
    }
  }

  /// Reports the X11 desktop geometry and its changes.
  ///
  /// Calls may come from any thread. `stop()` is idempotent; the backend also stops itself when
  /// it is released. When the X server goes away the stream finishes and `currentGeometry()`
  /// fails with `lifecycle.subsystemUnavailable`; the lost connection is not closed, because
  /// Xlib would terminate the process while closing it (the composition root exits on display
  /// loss).
  package final class LinuxScreenBackend: ScreenBackend, @unchecked Sendable {
    private let session: ScreenSession

    package init(displayName: String?) throws(CoreError) {
      self.session = try ScreenSession.open(displayName: displayName, runsEventThread: true)
    }

    /// Test seam: with `runsEventThread` false nothing watches the event connection, so a test
    /// can reach the guards of `currentGeometry()` that the event thread would otherwise
    /// pre-empt. `changes` never yields without the thread. Production uses `init(displayName:)`.
    package init(displayName: String?, runsEventThread: Bool) throws(CoreError) {
      self.session = try ScreenSession.open(
        displayName: displayName, runsEventThread: runsEventThread)
    }

    deinit {
      session.shutdown()
    }

    package func currentGeometry() -> CoreResult<PlatformScreenGeometry> {
      session.currentGeometry()
    }

    package var changes: AsyncStream<PlatformScreenGeometry> {
      session.changes
    }

    package func stop() async {
      session.shutdown()
    }
  }

  /// The resources behind one backend. The event thread holds the session, not the backend, so
  /// dropping the backend runs `shutdown()` and ends the thread.
  private final class ScreenSession: @unchecked Sendable {
    let changes: AsyncStream<PlatformScreenGeometry>

    private let continuation: AsyncStream<PlatformScreenGeometry>.Continuation
    private let queryDisplay: OpaquePointer
    private let eventDisplay: OpaquePointer
    private let queryRoot: Window
    private let eventBase: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32

    /// Guards `queryDisplay` use, `stopped`, `lost` and `lastReported`.
    private let lock = NSLock()
    /// Serializes `shutdown()` so a second caller waits for the first to finish.
    private let shutdownLock = NSLock()
    private let threadExited = DispatchSemaphore(value: 0)
    private var threadStarted = false
    private var stopped = false
    private var lost = false
    private var lastReported: PlatformScreenGeometry

    static func open(
      displayName: String?, runsEventThread: Bool
    ) throws(CoreError) -> ScreenSession {
      guard let queryDisplay = XOpenDisplay(displayName) else {
        throw LinuxScreenError.subsystemUnavailable
      }
      guard let eventDisplay = XOpenDisplay(displayName) else {
        XCloseDisplay(queryDisplay)
        throw LinuxScreenError.subsystemUnavailable
      }
      var eventBase: Int32 = 0
      var errorBase: Int32 = 0
      guard XRRQueryExtension(eventDisplay, &eventBase, &errorBase) != 0 else {
        XCloseDisplay(eventDisplay)
        XCloseDisplay(queryDisplay)
        throw LinuxScreenError.capabilityUnavailable
      }
      var descriptors: [Int32] = [0, 0]
      guard pipe(&descriptors) == 0 else {
        XCloseDisplay(eventDisplay)
        XCloseDisplay(queryDisplay)
        throw LinuxScreenError.subsystemUnavailable
      }
      for descriptor in descriptors {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      }
      _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)

      // Select first, then read the starting geometry: a change after this point is reported.
      let root = XDefaultRootWindow(eventDisplay)
      XRRSelectInput(eventDisplay, root, Int32(RRScreenChangeNotifyMask))
      XSync(eventDisplay, 0)

      let initial = Self.readGeometry(display: queryDisplay, root: XDefaultRootWindow(queryDisplay))
      switch initial {
      case .failure(let error):
        close(descriptors[0])
        close(descriptors[1])
        XCloseDisplay(eventDisplay)
        XCloseDisplay(queryDisplay)
        throw error
      case .success(let geometry):
        let session = ScreenSession(
          queryDisplay: queryDisplay, eventDisplay: eventDisplay, eventBase: eventBase,
          wakeRead: descriptors[0], wakeWrite: descriptors[1], initial: geometry)
        if runsEventThread {
          session.startEventThread()
        }
        return session
      }
    }

    private init(
      queryDisplay: OpaquePointer, eventDisplay: OpaquePointer, eventBase: Int32,
      wakeRead: Int32, wakeWrite: Int32, initial: PlatformScreenGeometry
    ) {
      self.queryDisplay = queryDisplay
      self.eventDisplay = eventDisplay
      self.queryRoot = XDefaultRootWindow(queryDisplay)
      self.eventBase = eventBase
      self.wakeRead = wakeRead
      self.wakeWrite = wakeWrite
      self.lastReported = initial
      let made = AsyncStream.makeStream(
        of: PlatformScreenGeometry.self, bufferingPolicy: .bufferingNewest(1))
      self.changes = made.stream
      self.continuation = made.continuation
    }

    // MARK: Queries

    func currentGeometry() -> CoreResult<PlatformScreenGeometry> {
      lock.lock()
      defer { lock.unlock() }
      guard !stopped, !lost else { return .failure(LinuxScreenError.subsystemUnavailable) }
      guard queryConnectionIsOpen() else { return .failure(LinuxScreenError.subsystemUnavailable) }
      return Self.readGeometry(display: queryDisplay, root: queryRoot)
    }

    /// Whether the query connection can still be used. The caller holds the lock. A closed
    /// connection is never handed to Xlib (its default IO handler would exit the process): the
    /// session is marked lost and `changes` finishes, exactly as when the event thread notices.
    private func queryConnectionIsOpen() -> Bool {
      if Self.connectionClosed(XConnectionNumber(queryDisplay)) {
        lost = true
        continuation.finish()
        return false
      }
      return true
    }

    /// Reads the root window's size and the pointer. The caller holds the lock, or has the
    /// connection to itself (before the session exists).
    private static func readGeometry(
      display: OpaquePointer, root: Window
    ) -> CoreResult<PlatformScreenGeometry> {
      var rootReturn: Window = 0
      var x: Int32 = 0
      var y: Int32 = 0
      var width: UInt32 = 0
      var height: UInt32 = 0
      var border: UInt32 = 0
      var depth: UInt32 = 0
      let sized = XGetGeometry(display, root, &rootReturn, &x, &y, &width, &height, &border, &depth)
      guard sized != 0 else { return .failure(LinuxScreenError.subsystemUnavailable) }

      var pointerRoot: Window = 0
      var child: Window = 0
      var rootX: Int32 = 0
      var rootY: Int32 = 0
      var windowX: Int32 = 0
      var windowY: Int32 = 0
      var mask: UInt32 = 0
      let onScreen = XQueryPointer(
        display, root, &pointerRoot, &child, &rootX, &rootY, &windowX, &windowY, &mask)
      // False means the pointer is on another screen of the display: its position here is
      // unknown, and a made-up one would mislead the server's DINF.
      guard onScreen != 0 else { return .failure(LinuxScreenError.subsystemUnavailable) }

      return LinuxScreenGeometryRules.geometry(
        width: Int(width), height: Int(height), cursorX: Int(rootX), cursorY: Int(rootY))
    }

    // MARK: Event thread

    private func startEventThread() {
      threadStarted = true
      let thread = Thread { [self] in
        runEvents()
        threadExited.signal()
      }
      thread.name = "mackvm.linux-screen"
      thread.start()
    }

    private func runEvents() {
      let eventDescriptor = XConnectionNumber(eventDisplay)
      var descriptors = [
        pollfd(fd: eventDescriptor, events: Int16(POLLIN), revents: 0),
        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
      ]
      // Events that arrived with the select-input round trip are already queued in Xlib.
      drainEvents(readFromSocket: false)
      while true {
        descriptors[0].revents = 0
        descriptors[1].revents = 0
        let ready = poll(&descriptors, 2, -1)
        if ready < 0 {
          if errno == EINTR { continue }
          markLost()
          return
        }
        if descriptors[1].revents != 0 { return }
        let hangUp = Int16(POLLHUP | POLLERR | POLLNVAL)
        if descriptors[0].revents & hangUp != 0 || Self.connectionClosed(eventDescriptor) {
          markLost()
          return
        }
        if descriptors[0].revents & Int16(POLLIN) != 0 {
          drainEvents(readFromSocket: true)
        }
      }
    }

    /// Whether the X server has closed the connection. Peeks without consuming, so Xlib still
    /// reads whatever is pending.
    private static func connectionClosed(_ descriptor: Int32) -> Bool {
      var byte: UInt8 = 0
      let received = recv(descriptor, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
      if received == 0 { return true }
      if received < 0 { return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR }
      return false
    }

    /// Reads the events and, when any was a screen change, reports the geometry once.
    ///
    /// `readFromSocket` is true only after the caller checked that the connection is open and
    /// has data: `XPending` then pulls the pending bytes in with one read. The loop itself uses
    /// `XEventsQueued(QueuedAlready)`, which never touches the socket, because a second socket
    /// read after the server closed the connection would reach Xlib's fatal IO handler.
    private func drainEvents(readFromSocket: Bool) {
      if readFromSocket {
        _ = XPending(eventDisplay)
      }
      var changed = false
      var event = XEvent()
      // 0 is QueuedAlready: only what Xlib has already read.
      while XEventsQueued(eventDisplay, 0) > 0 {
        XNextEvent(eventDisplay, &event)
        if event.type == eventBase + Int32(RRScreenChangeNotify) {
          changed = true
        }
      }
      if changed { publish() }
    }

    private func publish() {
      lock.lock()
      if stopped || lost {
        lock.unlock()
        return
      }
      guard queryConnectionIsOpen() else {
        lock.unlock()
        return
      }
      let current = Self.readGeometry(display: queryDisplay, root: queryRoot)
      var report: PlatformScreenGeometry?
      // A failed read, or a size outside the range, is never yielded.
      if case .success(let geometry) = current,
        LinuxScreenGeometryRules.hasChanged(from: lastReported, to: geometry)
      {
        lastReported = geometry
        report = geometry
      }
      lock.unlock()
      if let report { continuation.yield(report) }
    }

    private func markLost() {
      lock.lock()
      lost = true
      lock.unlock()
      continuation.finish()
    }

    // MARK: Shutdown

    func shutdown() {
      shutdownLock.lock()
      defer { shutdownLock.unlock() }
      lock.lock()
      if stopped {
        lock.unlock()
        return
      }
      stopped = true
      lock.unlock()

      var byte: UInt8 = 1
      _ = write(wakeWrite, &byte, 1)
      if threadStarted {
        threadExited.wait()
      }

      continuation.finish()
      // The event thread has exited, so `lost` can no longer change.
      lock.lock()
      let connectionLost = lost
      if !connectionLost {
        XCloseDisplay(eventDisplay)
        XCloseDisplay(queryDisplay)
      }
      lock.unlock()
      close(wakeRead)
      close(wakeWrite)
    }
  }
#endif

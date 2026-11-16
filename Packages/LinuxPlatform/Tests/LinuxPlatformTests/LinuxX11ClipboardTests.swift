import CX11
import Foundation
import Glibc
import KVMContracts
import LinuxPlatform
import Synchronization
import Testing

// M4-026 tests. The pure suite runs everywhere. The X11 suite runs under Xvfb (`make
// verify-linux`) and uses a second Xlib connection, `X11TestPeer`, as the other application:
// it owns CLIPBOARD and serves it, or requests CLIPBOARD and reads the answer, with plain Xlib
// calls written here from the ICCCM rules, so the backend is checked against an independent
// implementation rather than against itself. The X11 suite is serialized because every test
// shares the one CLIPBOARD selection of the display.

private func limit(_ byteCount: Int) throws -> ClipboardByteLimit {
  try #require(ClipboardByteLimit(byteCount: byteCount))
}

private let oneMiB = 1_048_576

/// A text of exactly `byteCount` UTF-8 bytes that mixes one- and three-byte characters.
private func text(byteCount: Int) -> String {
  var scalars = String.UnicodeScalarView()
  var used = 0
  var index = 0
  while used < byteCount {
    if byteCount - used >= 3 && index % 5 == 0 {
      scalars.append("\u{4E2D}")
      used += 3
    } else {
      scalars.append(Unicode.Scalar(UInt8(0x61 + index % 26)))
      used += 1
    }
    index += 1
  }
  return String(scalars)
}

@Suite("M4-026 Linux X11 clipboard: pure rules")
struct LinuxX11ClipboardPureTests {
  @Test("the served target list names STRING only for Latin-1 text")
  func targetList() {
    #expect(
      LinuxX11ClipboardRules.servedTargetNames(latin1Representable: true) == [
        "TARGETS", "UTF8_STRING", "text/plain;charset=utf-8", "STRING",
      ])
    #expect(
      LinuxX11ClipboardRules.servedTargetNames(latin1Representable: false) == [
        "TARGETS", "UTF8_STRING", "text/plain;charset=utf-8",
      ])
  }

  @Test("Latin-1 conversion accepts U+0000 to U+00FF and refuses anything above")
  func latin1() {
    #expect(LinuxX11ClipboardRules.latin1Bytes(of: "") == [])
    #expect(LinuxX11ClipboardRules.latin1Bytes(of: "abc") == [0x61, 0x62, 0x63])
    #expect(
      LinuxX11ClipboardRules.latin1Bytes(of: "caf\u{E9}\u{FF}") == [0x63, 0x61, 0x66, 0xE9, 0xFF])
    #expect(LinuxX11ClipboardRules.latin1Bytes(of: "\u{100}") == nil)
    #expect(LinuxX11ClipboardRules.latin1Bytes(of: "a\u{4E2D}") == nil)
    #expect(LinuxX11ClipboardRules.latin1Bytes(of: "\u{1F600}") == nil)
  }

  @Test("the content hash is the lowercase SHA-256 hex of the UTF-8 bytes, and stable")
  func hashStability() {
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    #expect(LinuxX11ClipboardRules.contentHash(of: "abc") == abc)
    #expect(LinuxX11ClipboardRules.contentHash(of: "") == empty)
    let mixed = text(byteCount: 4096)
    #expect(
      LinuxX11ClipboardRules.contentHash(of: mixed)
        == LinuxX11ClipboardRules.contentHash(of: String(mixed.unicodeScalars)))
    #expect(LinuxX11ClipboardRules.contentHash(of: "abd") != abc)
  }

  @Test("content larger than a quarter of the maximum request is sent with INCR")
  func incrThreshold() {
    // XMaxRequestSize counts 4-byte units, so a quarter of the request in bytes is the unit
    // count itself.
    #expect(LinuxX11ClipboardRules.incrChunkByteCount(maxRequestUnits: 65_535) == 65_535)
    #expect(LinuxX11ClipboardRules.incrChunkByteCount(maxRequestUnits: 16) == 4096)
    #expect(!LinuxX11ClipboardRules.usesINCR(byteCount: 65_535, chunkByteCount: 65_535))
    #expect(LinuxX11ClipboardRules.usesINCR(byteCount: 65_536, chunkByteCount: 65_535))
  }

  @Test("the read deadline is 2 seconds")
  func readDeadline() {
    #expect(LinuxX11ClipboardRules.readTimeout == .seconds(2))
  }
}

// MARK: - X11 peer

/// The other application on the same display: a second Xlib connection with its own window.
/// All calls happen on the calling thread except `serve`, which answers requests on its own
/// thread until `close()`.
private final class X11TestPeer: @unchecked Sendable {
  let display: OpaquePointer
  let window: Window
  let clipboard: Atom
  let targets: Atom
  let utf8: Atom
  let incr: Atom
  let atomType: Atom
  let property: Atom

  private let lock = NSLock()
  private var serving = false
  private var stopServing = false
  private var serverThread: Thread?
  private var served: [UInt8] = []
  private var statedINCRSize: Int?
  private var answers = true
  private var sentBytes = 0
  private var requests = 0

  init() throws {
    _ = xlibThreadsInitialized
    guard let display = XOpenDisplay(nil) else {
      Issue.record(
        "XOpenDisplay failed: errno \(errno) DISPLAY \(ProcessInfo.processInfo.environment["DISPLAY"] ?? "-")"
      )
      throw CocoaError(.featureUnsupported)
    }
    self.display = display
    let root = XDefaultRootWindow(display)
    window = XCreateSimpleWindow(display, root, 0, 0, 1, 1, 0, 0, 0)
    XSelectInput(display, window, 1 << 22)  // PropertyChangeMask
    clipboard = XInternAtom(display, "CLIPBOARD", 0)
    targets = XInternAtom(display, "TARGETS", 0)
    utf8 = XInternAtom(display, "UTF8_STRING", 0)
    incr = XInternAtom(display, "INCR", 0)
    atomType = XInternAtom(display, "ATOM", 0)
    property = XInternAtom(display, "MACKVM_TEST_PEER", 0)
    XSync(display, 0)
  }

  var owner: Window { XGetSelectionOwner(display, clipboard) }

  /// Bytes this peer has written into requestors' properties while serving.
  var servedByteCount: Int { lock.withLock { sentBytes } }

  var requestCount: Int { lock.withLock { requests } }

  /// Nobody owns CLIPBOARD afterwards.
  func clearSelection() {
    XSetSelectionOwner(display, clipboard, 0, 0)
    XSync(display, 0)
  }

  /// Takes CLIPBOARD and serves `bytes` as UTF8_STRING until `close()`. With `statedINCRSize`
  /// the transfer always uses INCR and states that size; `answers: false` never answers.
  func serve(_ bytes: [UInt8], statedINCRSize: Int? = nil, answers: Bool = true) {
    lock.withLock {
      served = bytes
      self.statedINCRSize = statedINCRSize
      self.answers = answers
    }
    XSetSelectionOwner(display, clipboard, window, 0)
    XSync(display, 0)
    let alreadyServing = lock.withLock { () -> Bool in
      defer { serving = true }
      return serving
    }
    guard !alreadyServing else { return }
    let thread = Thread { [self] in serveLoop() }
    serverThread = thread
    thread.start()
  }

  /// Requests CLIPBOARD as `target` and returns the property's type and bytes, reassembling
  /// INCR. `nil` when the owner refuses. Fails the test when nothing arrives within 5 s.
  func request(_ target: Atom) -> (type: Atom, bytes: [UInt8], usedINCR: Bool)? {
    XDeleteProperty(display, window, property)
    XConvertSelection(display, clipboard, target, property, window, 0)
    XFlush(display)
    guard let notify = waitFor(selectionNotify: true) else {
      Issue.record("no SelectionNotify within 5 s")
      return nil
    }
    guard notify.xselection.property != 0 else { return nil }
    guard let first = takeProperty() else { return nil }
    guard first.type == incr else { return (first.type, first.bytes, false) }
    var bytes: [UInt8] = []
    var type: Atom = 0
    while true {
      guard waitFor(selectionNotify: false) != nil else {
        Issue.record("an INCR chunk did not arrive within 5 s")
        return nil
      }
      guard let chunk = takeProperty() else { continue }
      type = chunk.type
      if chunk.bytes.isEmpty { break }
      bytes += chunk.bytes
    }
    return (type, bytes, true)
  }

  /// The atoms of a TARGETS answer, by name.
  func targetNames() -> [String] {
    guard let answer = request(targets) else { return [] }
    let count = answer.bytes.count / MemoryLayout<Int>.size
    let atoms = answer.bytes.withUnsafeBytes { raw in
      (0..<count).map { raw.load(fromByteOffset: $0 * MemoryLayout<Int>.size, as: UInt.self) }
    }
    return atoms.map { atom in
      guard let name = XGetAtomName(display, atom) else { return "" }
      defer { XFree(name) }
      return String(cString: name)
    }
  }

  func atom(_ name: String) -> Atom { XInternAtom(display, name, 0) }

  func close() {
    let thread = lock.withLock { () -> Thread? in
      stopServing = true
      return serverThread
    }
    while let thread, !thread.isFinished {
      usleep(1000)
    }
    XDestroyWindow(display, window)
    XCloseDisplay(display)
  }

  // MARK: Requestor side

  private func waitFor(selectionNotify: Bool) -> XEvent? {
    let deadline = Date().addingTimeInterval(5)
    var event = XEvent()
    while Date() < deadline {
      while XPending(display) > 0 {
        XNextEvent(display, &event)
        if selectionNotify, event.type == 31, event.xselection.requestor == window {
          return event
        }
        if !selectionNotify, event.type == 28, event.xproperty.window == window,
          event.xproperty.atom == property, event.xproperty.state == 0
        {
          return event
        }
      }
      var fds = pollfd(fd: XConnectionNumber(display), events: Int16(POLLIN), revents: 0)
      _ = poll(&fds, 1, 50)
    }
    return nil
  }

  private func takeProperty() -> (type: Atom, bytes: [UInt8])? {
    var type: Atom = 0
    var format: Int32 = 0
    var items: UInt = 0
    var after: UInt = 0
    var data: UnsafeMutablePointer<UInt8>?
    let status = XGetWindowProperty(
      display, window, property, 0, Int(oneMiB * 4), 1, 0, &type, &format, &items, &after,
      &data)
    guard status == 0, type != 0 else { return nil }
    defer { if let data { XFree(data) } }
    let byteCount =
      format == 32 ? Int(items) * MemoryLayout<Int>.size : Int(items) * Int(format / 8)
    let bytes = data.map { Array(UnsafeBufferPointer(start: $0, count: byteCount)) } ?? []
    return (type, bytes)
  }

  // MARK: Owner side

  private struct Transfer {
    var requestor: Window
    var property: Atom
    var offset: Int
  }

  private func serveLoop() {
    var event = XEvent()
    var transfers: [Transfer] = []
    while !lock.withLock({ stopServing }) {
      while XPending(display) > 0 {
        XNextEvent(display, &event)
        if event.type == 30 {
          answer(event.xselectionrequest, transfers: &transfers)
        } else if event.type == 28, event.xproperty.state == 1 {
          continueTransfer(event.xproperty, transfers: &transfers)
        }
      }
      XFlush(display)
      var fds = pollfd(fd: XConnectionNumber(display), events: Int16(POLLIN), revents: 0)
      _ = poll(&fds, 1, 20)
    }
  }

  private func answer(_ request: XSelectionRequestEvent, transfers: inout [Transfer]) {
    let (bytes, stated, answering) = lock.withLock {
      requests += 1
      return (served, statedINCRSize, answers)
    }
    guard answering else { return }
    var reply = XEvent()
    reply.xselection.type = 31
    reply.xselection.display = display
    reply.xselection.requestor = request.requestor
    reply.xselection.selection = request.selection
    reply.xselection.target = request.target
    reply.xselection.time = request.time
    reply.xselection.property = 0
    if request.target == utf8 {
      if stated != nil || bytes.count > 65_536 {
        XSelectInput(display, request.requestor, 1 << 22)
        var size = stated ?? bytes.count
        withUnsafeBytes(of: &size) { raw in
          let pointer = raw.bindMemory(to: UInt8.self).baseAddress
          _ = XChangeProperty(display, request.requestor, request.property, incr, 32, 0, pointer, 1)
        }
        transfers.append(
          Transfer(requestor: request.requestor, property: request.property, offset: 0))
      } else {
        bytes.withUnsafeBufferPointer { buffer in
          _ = XChangeProperty(
            display, request.requestor, request.property, utf8, 8, 0, buffer.baseAddress,
            Int32(bytes.count))
        }
        lock.withLock { sentBytes += bytes.count }
      }
      reply.xselection.property = request.property
    }
    XSendEvent(display, request.requestor, 0, 0, &reply)
  }

  private func continueTransfer(_ event: XPropertyEvent, transfers: inout [Transfer]) {
    guard
      let index = transfers.firstIndex(where: {
        $0.requestor == event.window && $0.property == event.atom
      })
    else { return }
    let bytes = lock.withLock { served }
    // A transfer left open by an abandoned read can outlive the content it started with.
    let start = min(transfers[index].offset, bytes.count)
    let end = min(start + 65_536, bytes.count)
    bytes.withUnsafeBufferPointer { buffer in
      _ = XChangeProperty(
        display, event.window, event.atom, utf8, 8, 0, buffer.baseAddress.map { $0 + start },
        Int32(end - start))
    }
    lock.withLock { sentBytes += end - start }
    if start == end {
      transfers.remove(at: index)
    } else {
      transfers[index].offset = end
    }
  }
}

/// The test process is its own composition root: Xlib is made thread-safe once, before any
/// test opens a display (the peer uses its display from two threads).
private let xlibThreadsInitialized: Bool = XInitThreads() != 0

/// An X server resets when its last client disconnects, and a connection opened during the
/// reset fails with ECONNRESET. Between two tests every connection can be closed, so the test
/// process holds this one open for its whole life.
nonisolated(unsafe) private let serverAnchor: OpaquePointer? = XOpenDisplay(nil)

private func x11Enabled() -> Bool {
  _ = xlibThreadsInitialized
  let enabled = LinuxPlatformSkeleton.x11TestsEnabled(
    environment: ProcessInfo.processInfo.environment)
  if enabled {
    _ = serverAnchor
  }
  return enabled
}

/// Waits until `condition` holds, polling the X server through `peer`, for at most 5 s.
private func eventually(_ peer: X11TestPeer, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if condition() { return true }
    XSync(peer.display, 0)
    usleep(2000)
  }
  return condition()
}

@Suite(
  "M4-026 Linux X11 clipboard under Xvfb", .serialized, .tags(.x11),
  .enabled(if: x11Enabled(), "needs MACKVM_X11_TESTS=1 and an X server"))
struct LinuxX11ClipboardX11Tests {
  // Inside the serialized suite: it opens a display, and the X11 tests must not race it.
  @Test("a display that cannot be opened is subsystemUnavailable")
  func noDisplay() {
    do {
      let clipboard = try LinuxX11Clipboard(displayName: "unix:/nonexistent-mackvm-display:99")
      Issue.record("opened a display that does not exist: \(clipboard)")
    } catch {
      #expect(error.code == .lifecycle(.subsystemUnavailable))
    }
  }

  @Test("a write is served to another application as UTF8_STRING and text/plain")
  func writeThenPeerReads() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let content = "hello \u{4E2D}\u{6587} caf\u{E9}"
    #expect(try await clipboard.writePlainText(content, limit: limit(oneMiB)).get() == ())
    #expect(peer.owner != 0)
    let answer = try #require(peer.request(peer.utf8))
    #expect(answer.type == peer.utf8)
    #expect(answer.bytes == Array(content.utf8))
    let plain = peer.atom("text/plain;charset=utf-8")
    #expect(peer.request(plain)?.bytes == Array(content.utf8))
    await clipboard.stop()
  }

  @Test("TARGETS lists STRING only when the text is Latin-1, and STRING carries Latin-1")
  func targetsAndString() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    _ = await clipboard.writePlainText("caf\u{E9}", limit: try limit(64))
    #expect(
      peer.targetNames() == ["TARGETS", "UTF8_STRING", "text/plain;charset=utf-8", "STRING"])
    let string = peer.atom("STRING")
    #expect(peer.request(string)?.bytes == [0x63, 0x61, 0x66, 0xE9])
    _ = await clipboard.writePlainText("\u{4E2D}", limit: try limit(64))
    #expect(peer.targetNames() == ["TARGETS", "UTF8_STRING", "text/plain;charset=utf-8"])
    #expect(peer.request(string) == nil)
    #expect(peer.request(peer.atom("image/png")) == nil)
    await clipboard.stop()
  }

  @Test("another application's copy is read back with its hash")
  func peerWritesThenRead() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let content = "from the peer \u{1F600}"
    peer.serve(Array(content.utf8))
    let read = try #require(try await clipboard.readPlainText(limit: limit(oneMiB)).get())
    #expect(read.text == content)
    #expect(read.contentHash == LinuxX11ClipboardRules.contentHash(of: content))
    await clipboard.stop()
  }

  @Test("1 MiB goes out through INCR")
  func oneMiBOut() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let content = text(byteCount: oneMiB)
    #expect(try await clipboard.writePlainText(content, limit: limit(oneMiB)).get() == ())
    let answer = try #require(peer.request(peer.utf8))
    #expect(answer.usedINCR)
    #expect(answer.bytes.count == oneMiB)
    #expect(answer.bytes == Array(content.utf8))
    await clipboard.stop()
  }

  @Test("1 MiB comes in through INCR")
  func oneMiBIn() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let content = text(byteCount: oneMiB)
    peer.serve(Array(content.utf8))
    let read = try #require(try await clipboard.readPlainText(limit: limit(oneMiB)).get())
    #expect(read.text.utf8.count == oneMiB)
    #expect(read.text == content)
    await clipboard.stop()
  }

  @Test("a read over the limit is refused before the content is transferred")
  func readOverLimit() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    // Stated INCR size over the limit: no chunk may be requested.
    peer.serve(Array(text(byteCount: 2000).utf8), statedINCRSize: 2000)
    let incr = await clipboard.readPlainText(limit: try limit(1000))
    #expect(incr.failureCode == .clipboard(.oversized))
    #expect(peer.servedByteCount == 0)
    #expect(clipboard.transferredByteCount == 0)
    // Whole property over the limit.
    peer.serve(Array(text(byteCount: 1001).utf8))
    let whole = await clipboard.readPlainText(limit: try limit(1000))
    #expect(whole.failureCode == .clipboard(.oversized))
    #expect(clipboard.transferredByteCount == 0)
    // A size stated too small: the INCR reassembly stops at the limit.
    peer.serve(Array(text(byteCount: 3000).utf8), statedINCRSize: 10)
    let lying = await clipboard.readPlainText(limit: try limit(1000))
    #expect(lying.failureCode == .clipboard(.oversized))
    #expect(clipboard.transferredByteCount == 0)
    // Exactly at the limit is accepted.
    peer.serve(Array(text(byteCount: 1000).utf8))
    let exact = await clipboard.readPlainText(limit: try limit(1000))
    #expect((try? exact.get())??.text.utf8.count == 1000)
    await clipboard.stop()
  }

  @Test("an abandoned INCR transfer does not leak into the next read")
  func abandonedTransfer() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    // Refused on its stated size: the peer keeps a transfer open on our property.
    peer.serve(Array(text(byteCount: 2000).utf8), statedINCRSize: 2000)
    let refused = await clipboard.readPlainText(limit: try limit(1000))
    #expect(refused.failureCode == .clipboard(.oversized))
    let content = text(byteCount: 3000)
    peer.serve(Array(content.utf8), statedINCRSize: 3000)
    let read = await clipboard.readPlainText(limit: try limit(5000))
    #expect((try? read.get())??.text == content)
    await clipboard.stop()
  }

  @Test("a write over the limit is refused and leaves the clipboard as it was")
  func writeOverLimit() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    #expect(try await clipboard.writePlainText("kept", limit: limit(8)).get() == ())
    let refused = await clipboard.writePlainText("123456789", limit: try limit(8))
    #expect(refused.failureCode == .clipboard(.oversized))
    #expect(peer.request(peer.utf8)?.bytes == Array("kept".utf8))
    #expect(try await clipboard.writePlainText("12345678", limit: limit(8)).get() == ())
    await clipboard.stop()
  }

  @Test("malformed UTF-8 fails with invalidUTF8 and is never repaired")
  func invalidUTF8() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    peer.serve([0x61, 0xFF, 0xFE, 0x62])
    let read = await clipboard.readPlainText(limit: try limit(64))
    #expect(read.failureCode == .clipboard(.invalidUTF8))
    await clipboard.stop()
  }

  @Test("no owner reads as nil")
  func noOwner() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    peer.clearSelection()
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let read = await clipboard.readPlainText(limit: try limit(64))
    #expect(read.isSuccessNil)
    await clipboard.stop()
  }

  @Test("an owner that goes away leaves nothing to read")
  func ownerLoss() async throws {
    let peer = try X11TestPeer()
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    peer.serve(Array("short-lived".utf8))
    #expect((try? await clipboard.readPlainText(limit: limit(64)).get())??.text == "short-lived")
    peer.close()
    let observer = try X11TestPeer()
    defer { observer.close() }
    #expect(eventually(observer) { observer.owner == 0 })
    let read = await clipboard.readPlainText(limit: try limit(64))
    #expect(read.isSuccessNil)
    await clipboard.stop()
  }

  @Test("our ownership ends when another application copies")
  func ownershipLostToPeer() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    _ = await clipboard.writePlainText("ours", limit: try limit(64))
    peer.serve(Array("theirs".utf8))
    let read = try #require(try await clipboard.readPlainText(limit: limit(64)).get())
    #expect(read.text == "theirs")
  }

  @Test("an owner that never answers times out within the deadline")
  func ownerTimeout() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    peer.serve(Array("silent".utf8), answers: false)
    let started = ContinuousClock.now
    let read = await clipboard.readPlainText(limit: try limit(64))
    let elapsed = ContinuousClock.now - started
    #expect(read.failureCode == .timeout(.read))
    #expect(elapsed >= .seconds(2))
    #expect(elapsed < .seconds(4))
    #expect(peer.requestCount == 1)
    await clipboard.stop()
  }

  @Test("ownerChanges fires for another application's copy")
  func ownerChangesForPeer() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let changes = clipboard.ownerChanges
    peer.serve(Array("copied".utf8))
    var iterator = changes.makeAsyncIterator()
    let fired: Void? = await iterator.next()
    #expect(fired != nil)
    await clipboard.stop()
  }

  @Test("ownerChanges stays quiet for our own writes")
  func ownerChangesNotForSelf() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    peer.clearSelection()
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    _ = await clipboard.writePlainText("self", limit: try limit(64))
    _ = await clipboard.writePlainText("self again", limit: try limit(64))
    // The peer's request is answered by the backend's thread after it has handled the owner
    // notifications its own writes caused, which the server queued earlier on its connection.
    #expect(peer.request(peer.utf8)?.bytes == Array("self again".utf8))
    await clipboard.stop()
    var count = 0
    for await _ in clipboard.ownerChanges { count += 1 }
    #expect(count == 0)
  }

  @Test("a call from a cancelled task fails with cancellation and changes nothing")
  func cancelled() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    _ = await clipboard.writePlainText("before", limit: try limit(64))
    let bound = try limit(64)
    let results = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      let write = await clipboard.writePlainText("after", limit: bound)
      let read = await clipboard.readPlainText(limit: bound)
      return (write.failureCode, read.failureCode)
    }.value
    #expect(results.0 == .cancellation(.requested))
    #expect(results.1 == .cancellation(.requested))
    #expect(peer.request(peer.utf8)?.bytes == Array("before".utf8))
    await clipboard.stop()
  }

  @Test("stop is idempotent, gives up ownership, finishes ownerChanges and refuses later calls")
  func stopIdempotent() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    _ = await clipboard.writePlainText("owned", limit: try limit(64))
    await clipboard.stop()
    await clipboard.stop()
    await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      await clipboard.stop()
    }.value
    #expect(eventually(peer) { peer.owner == 0 })
    var count = 0
    for await _ in clipboard.ownerChanges { count += 1 }
    #expect(count == 0)
    let read = await clipboard.readPlainText(limit: try limit(64))
    let write = await clipboard.writePlainText("x", limit: try limit(64))
    #expect(read.failureCode == .lifecycle(.subsystemUnavailable))
    #expect(write.failureCode == .lifecycle(.subsystemUnavailable))
  }

  @Test("an X error on another display reaches the previous handler, and stop restores it")
  func errorHandlerScope() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let original = XSetErrorHandler(recordingErrorHandler)
    defer { XSetErrorHandler(original) }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    let before = recordedErrors.withLock { $0 }
    XDestroyWindow(peer.display, 0x1F_FFFF)  // no such window: BadWindow on the peer's display
    XSync(peer.display, 0)
    #expect(recordedErrors.withLock { $0 } == before + 1)
    await clipboard.stop()
    let installed = XSetErrorHandler(recordingErrorHandler)
    #expect(
      installed.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
        == unsafeBitCast(recordingErrorHandler as XErrorHandler, to: UnsafeRawPointer.self))
  }

  @Test("stop while a read waits on a silent owner ends the read")
  func stopDuringRead() async throws {
    let peer = try X11TestPeer()
    defer { peer.close() }
    let clipboard = try LinuxX11Clipboard(displayName: nil)
    peer.serve(Array("silent".utf8), answers: false)
    let bound = try limit(64)
    let pending = Task { await clipboard.readPlainText(limit: bound) }
    #expect(eventually(peer) { peer.requestCount == 1 })
    let started = ContinuousClock.now
    await clipboard.stop()
    let read = await pending.value
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(read.failureCode == .lifecycle(.subsystemUnavailable))
  }
}

extension Result where Failure == CoreError {
  fileprivate var failureCode: CoreErrorCode? {
    if case .failure(let error) = self { return error.code }
    return nil
  }
}

extension Result where Success == PlatformClipboardText?, Failure == CoreError {
  fileprivate var isSuccessNil: Bool {
    if case .success(nil) = self { return true }
    return false
  }
}

/// Errors seen by `recordingErrorHandler`, the handler installed before a clipboard is made.
private let recordedErrors = Mutex(0)

private func recordingErrorHandler(
  _ display: OpaquePointer?, _ event: UnsafeMutablePointer<XErrorEvent>?
) -> Int32 {
  recordedErrors.withLock { $0 += 1 }
  return 0
}

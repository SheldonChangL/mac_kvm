#if os(Linux)
  import BarrierCompatibility
  import CX11
  import Foundation
  import Glibc
  import KVMContracts
  import KVMCore
  import LinuxPlatform
  @testable import MacKVMClient
  import Testing

  // M4-020-FOLLOWUP-001: the Linux client app. The parser matrix and exit codes; the composition
  // root against an in-process first-party Barrier server (`BarrierServerProtocolSession` under
  // `ServerSession`) over an in-memory duplex stream, with fake backends; the trust flow; the
  // h.3/h.5/h.8 obligations; and the systemd unit's structure. Every wait is cancellation-aware
  // and every suite has a time limit, so a broken build fails instead of hanging.

  // MARK: - Test doubles

  /// Waits for a condition over a growing record.
  private final class Recorder<Entry: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var waiters:
      [(id: Int, check: ([Entry]) -> Bool, done: CheckedContinuation<Void, Never>)] =
        []
    private var nextID = 0

    func append(_ entry: Entry) {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        entries.append(entry)
        let ready = waiters.filter { $0.check(entries) }
        waiters.removeAll { $0.check(entries) }
        return ready.map(\.done)
      }
      for waiter in ready { waiter.resume() }
    }

    var all: [Entry] { lock.withLock { entries } }

    /// Completes once `check` holds, or when the waiting task is cancelled (the time limit).
    func wait(until check: @escaping ([Entry]) -> Bool) async {
      let id = lock.withLock { () -> Int in
        nextID += 1
        return nextID
      }
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let now = lock.withLock { () -> Bool in
            if check(entries) || Task.isCancelled { return true }
            waiters.append((id, check, continuation))
            return false
          }
          if now { continuation.resume() }
        }
      } onCancel: {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
          guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
          return waiters.remove(at: index).done
        }
        waiter?.resume()
      }
    }
  }

  private enum InjectorEntry: Equatable, Sendable {
    case inject(KVMEvent)
    case release(KVMEvent)
    case sweep(held: Int)
    case close
  }

  /// An injector that records every call and tracks what it holds, as the X11 one does.
  private final class FakeInjector: ClientInjector, @unchecked Sendable {
    let log = Recorder<InjectorEntry>()
    private let lock = NSLock()
    private var heldKeys: Set<String> = []
    private var heldButtons: Set<String> = []
    private var failNext: CoreError?

    func failNextInjection(with error: CoreError) { lock.withLock { failNext = error } }

    /// When set, the next injection runs this hook and then blocks its thread for good, as a
    /// drain worker parked in Xlib's I/O error handler does.
    private var parkHook: (@Sendable () -> Void)?
    func parkNextInjection(after hook: @escaping @Sendable () -> Void) {
      lock.withLock { parkHook = hook }
    }

    var heldCount: Int { lock.withLock { heldKeys.count + heldButtons.count } }

    private func track(_ event: KVMEvent) {
      lock.withLock {
        switch event {
        case .key(let key, let phase, _):
          if phase == .down {
            heldKeys.insert("\(key)")
          } else if phase == .up {
            heldKeys.remove("\(key)")
          }
        case .mouseButton(let button, let phase):
          if phase == .down {
            heldButtons.insert("\(button)")
          } else {
            heldButtons.remove("\(button)")
          }
        default:
          break
        }
      }
    }

    func inject(_ event: KVMEvent) -> CoreResult<InjectionOutcome> {
      if let hook = lock.withLock({ () -> (@Sendable () -> Void)? in
        defer { parkHook = nil }
        return parkHook
      }) {
        hook()
        DispatchSemaphore(value: 0).wait()
      }
      if let error = lock.withLock({ () -> CoreError? in
        defer { failNext = nil }
        return failNext
      }) {
        return .failure(error)
      }
      if case .key(_, .repeatKey, _) = event { return .success(.unsupported(.repeatNotInjected)) }
      track(event)
      log.append(.inject(event))
      return .success(.injected)
    }

    func flush() -> CoreResult<Void> { .success(()) }

    func releaseAllHeld() -> CoreResult<Void> {
      let held = lock.withLock { () -> Int in
        defer {
          heldKeys.removeAll()
          heldButtons.removeAll()
        }
        return heldKeys.count + heldButtons.count
      }
      log.append(.sweep(held: held))
      return .success(())
    }

    func release(_ event: KVMEvent) throws(CoreError) {
      track(event)
      log.append(.release(event))
    }

    func releaseRemaining() throws(CoreError) {
      _ = releaseAllHeld()
    }

    func close() -> CoreResult<Void> {
      _ = releaseAllHeld()
      log.append(.close)
      return .success(())
    }
  }

  private let testGeometry = PlatformScreenGeometry(
    originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

  private final class FakeScreen: ScreenBackend, @unchecked Sendable {
    let changes: AsyncStream<PlatformScreenGeometry>
    let continuation: AsyncStream<PlatformScreenGeometry>.Continuation
    let stops = Recorder<Bool>()

    init() {
      (changes, continuation) = AsyncStream.makeStream()
    }

    func currentGeometry() -> CoreResult<PlatformScreenGeometry> { .success(testGeometry) }

    func stop() async {
      stops.append(true)
      continuation.finish()
    }
  }

  private final class FakeClipboard: ClipboardBackend, @unchecked Sendable {
    let ownerChanges: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
    let writes = Recorder<String>()
    private let lock = NSLock()
    private var text: String?

    init() {
      (ownerChanges, continuation) = AsyncStream.makeStream()
    }

    func setLocalText(_ value: String) { lock.withLock { text = value } }

    func readPlainText(limit: ClipboardByteLimit) async -> CoreResult<PlatformClipboardText?> {
      let value = lock.withLock { text }
      return .success(value.map { PlatformClipboardText(text: $0, contentHash: "h-\($0.count)") })
    }

    func writePlainText(_ text: String, limit: ClipboardByteLimit) async -> CoreResult<Void> {
      writes.append(text)
      return .success(())
    }

    func stop() async { continuation.finish() }
  }

  private final class FakeLifecycle: ClientLifecycle, @unchecked Sendable {
    let signals: AsyncStream<LifecycleSignal>
    let continuation: AsyncStream<LifecycleSignal>.Continuation
    let polling = Recorder<Bool>()
    let stops = Recorder<Bool>()
    private let lock = NSLock()
    private var network = true

    init() {
      (signals, continuation) = AsyncStream.makeStream()
    }

    func start() {}
    var isNetworkAvailable: Bool { lock.withLock { network } }
    func setNetwork(_ value: Bool) { lock.withLock { network = value } }
    func setNetworkPolling(_ enabled: Bool) { polling.append(enabled) }

    func stop() {
      stops.append(true)
      continuation.finish()
    }
  }

  /// An in-memory trust store that counts writes.
  private final class FakeStore: SecureStorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [PeerKey: Data] = [:]
    private var writeCount = 0
    var unavailable = false

    init(_ records: [PeerKey: Data] = [:]) {
      self.records = records
    }

    var writes: Int { lock.withLock { writeCount } }
    func stored(_ peer: PeerKey) -> Data? { lock.withLock { records[peer] } }

    private static let failure = CoreError(
      code: .security(.secureStorageUnavailable), severity: .error,
      retryDisposition: .userActionRequired, cleanupDisposition: .notRequired)

    func loadTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Data?> {
      lock.withLock { unavailable ? .failure(Self.failure) : .success(records[peer]) }
    }

    func insertTrustedFingerprintIfAbsent(_ fingerprint: Data, for peer: PeerKey) async
      -> CoreResult<TrustInsertOutcome>
    {
      lock.withLock {
        if unavailable { return .failure(Self.failure) }
        if let stored = records[peer] { return .success(.existing(storedFingerprint: stored)) }
        writeCount += 1
        records[peer] = fingerprint
        return .success(.inserted)
      }
    }

    func removeTrustedFingerprint(for peer: PeerKey) async -> CoreResult<Void> {
      lock.withLock {
        if unavailable { return .failure(Self.failure) }
        writeCount += 1
        records[peer] = nil
        return .success(())
      }
    }
  }

  /// One end of an in-memory duplex byte stream; closing either end closes both directions.
  private final class LoopbackEnd: Transport, @unchecked Sendable {
    let incomingBytes: AsyncThrowingStream<Data, any Error>
    private let inbox: AsyncThrowingStream<Data, any Error>.Continuation
    private let outbox: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var closed = false
    let disconnects = Recorder<Bool>()

    init(
      incoming: (
        AsyncThrowingStream<Data, any Error>, AsyncThrowingStream<Data, any Error>.Continuation
      ),
      outgoing: AsyncThrowingStream<Data, any Error>.Continuation
    ) {
      (incomingBytes, inbox) = incoming
      outbox = outgoing
    }

    func connect() async throws(CoreError) {}

    func send(_ data: Data) async throws(CoreError) {
      guard lock.withLock({ !closed }) else {
        throw CoreError(
          code: .transport(.disconnected), severity: .error, retryDisposition: .backoff,
          cleanupDisposition: .notRequired)
      }
      outbox.yield(data)
    }

    func disconnect() async {
      lock.withLock { closed = true }
      inbox.finish()
      outbox.finish()
      disconnects.append(true)
    }
  }

  /// The client end with the TLS trust step in front: `connect()` asks the evaluator about the
  /// server's fingerprint and fails closed unless it accepts, as `LinuxTLSTransport` does.
  private final class PinnedEnd: Transport, @unchecked Sendable {
    let inner: LoopbackEnd
    let fingerprint: Data
    let evaluator: @Sendable (Data) -> LinuxTLSTrustDecision

    init(
      inner: LoopbackEnd, fingerprint: Data,
      evaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision
    ) {
      self.inner = inner
      self.fingerprint = fingerprint
      self.evaluator = evaluator
    }

    var incomingBytes: AsyncThrowingStream<Data, any Error> { inner.incomingBytes }

    func connect() async throws(CoreError) {
      if case .reject(let code) = evaluator(fingerprint) {
        await inner.disconnect()
        throw CoreError(
          code: .security(code), severity: .error, retryDisposition: .userActionRequired,
          cleanupDisposition: .completed)
      }
      try await inner.connect()
    }

    func send(_ data: Data) async throws(CoreError) { try await inner.send(data) }
    func disconnect() async { await inner.disconnect() }
  }

  /// A fake `KVMClock` whose sleeps end only on `fire()` or cancellation.
  private final class ManualClock: KVMClock, @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers:
      [Int: (duration: Duration, continuation: CheckedContinuation<Bool, Never>)] = [:]
    private var nextID = 0

    func sleep(for duration: Duration) async throws(CoreError) {
      let id = lock.withLock { () -> Int in
        nextID += 1
        return nextID
      }
      let fired = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
          let cancelled = lock.withLock { () -> Bool in
            if Task.isCancelled { return true }
            sleepers[id] = (duration, continuation)
            return false
          }
          if cancelled { continuation.resume(returning: false) }
        }
      } onCancel: {
        let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
        sleeper?.continuation.resume(returning: false)
      }
      guard fired else {
        throw CoreError(
          code: .cancellation(.requested), severity: .info, retryDisposition: .never,
          cleanupDisposition: .notRequired)
      }
    }

    func fire(duration: Duration) {
      let due = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
        let selected = sleepers.filter { $0.value.duration == duration }
        for id in selected.keys { sleepers.removeValue(forKey: id) }
        return selected.values.map(\.continuation)
      }
      for sleeper in due { sleeper.resume(returning: true) }
    }
  }

  /// One in-process server connection.
  private final class ServerSide: @unchecked Sendable {
    let barrier: BarrierServerProtocolSession
    let session: ServerSession
    let end: LoopbackEnd
    let client: LoopbackEnd
    let inbound = Recorder<KVMEvent>()
    let started: Task<Bool, Never>

    init(barrier: BarrierServerProtocolSession, end: LoopbackEnd, client: LoopbackEnd) {
      self.barrier = barrier
      self.end = end
      self.client = client
      let session = ServerSession(id: SessionID(), screen: ScreenID(), protocolSession: barrier)
      self.session = session
      let inbound = inbound
      started = Task {
        do {
          try await session.start()
        } catch {
          return false
        }
        Task { _ = await session.monitorPeer { inbound.append($0) } }
        return true
      }
    }
  }

  /// Hands each client transport an in-process server over a loopback pair.
  private final class LoopbackConnector: ClientConnector, @unchecked Sendable {
    let servers = Recorder<ServerSide>()
    let fingerprint: Data
    let screenName: String
    /// When `false`, no server answers: the client's handshake waits.
    var serve = true

    init(fingerprint: Data, screenName: String) {
      self.fingerprint = fingerprint
      self.screenName = screenName
    }

    func makeTransport(evaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision)
      -> any Transport
    {
      let toServer = AsyncThrowingStream<Data, any Error>.makeStream()
      let toClient = AsyncThrowingStream<Data, any Error>.makeStream()
      let serverEnd = LoopbackEnd(incoming: toServer, outgoing: toClient.continuation)
      let clientEnd = LoopbackEnd(incoming: toClient, outgoing: toServer.continuation)
      if serve,
        let barrier = BarrierServerProtocolSession(
          transport: serverEnd, expectedScreenNames: [screenName], clock: ManualClock(),
          handshakeTimeout: .seconds(30))
      {
        servers.append(ServerSide(barrier: barrier, end: serverEnd, client: clientEnd))
      } else {
        servers.append(
          ServerSide(
            barrier: BarrierServerProtocolSession(
              transport: LoopbackEnd(
                incoming: AsyncThrowingStream<Data, any Error>.makeStream(),
                outgoing: AsyncThrowingStream<Data, any Error>.makeStream().continuation),
              expectedScreenNames: [screenName], clock: ManualClock(),
              handshakeTimeout: .seconds(30))!,
            end: serverEnd, client: clientEnd))
      }
      return PinnedEnd(inner: clientEnd, fingerprint: fingerprint, evaluator: evaluator)
    }

    func server(_ index: Int) async -> ServerSide? {
      await servers.wait { $0.count > index }
      let all = servers.all
      return all.count > index ? all[index] : nil
    }
  }

  private enum OutputEntry: Equatable, Sendable {
    case status(String)
    case message(String)
    case error(String)
  }

  private final class RecordingOutput: ClientOutput, @unchecked Sendable {
    let lines = Recorder<OutputEntry>()
    func status(_ status: ClientStatus) { lines.append(.status(status.text)) }
    func message(_ text: String) { lines.append(.message(text)) }
    func error(_ text: String) { lines.append(.error(text)) }

    var text: String {
      lines.all.map { entry -> String in
        switch entry {
        case .status(let text), .message(let text), .error(let text): text
        }
      }.joined(separator: "\n")
    }
  }

  // MARK: - Harness

  private let secretHost = "mac-secret.example"
  private let screenName = "linux-desk"
  private let serverFingerprint = Data(
    (0..<32).map { (index: Int) -> UInt8 in UInt8(truncatingIfNeeded: index * 7 + 3) })
  private let otherFingerprint = Data(repeating: 0xEE, count: 32)
  private let none = ModifierState()

  private struct Harness {
    let clock = ManualClock()
    let injector = FakeInjector()
    let screen = FakeScreen()
    let clipboard = FakeClipboard()
    let lifecycle = FakeLifecycle()
    let output = RecordingOutput()
    let store: FakeStore
    let connector: LoopbackConnector
    let runtime: ClientRuntime
    let server = ClientServerAddress(secretHost)!

    init(
      trusted: Data? = serverFingerprint, interactive: Bool = false,
      prompt: @escaping @Sendable () async -> String? = { nil }
    ) {
      let server = ClientServerAddress(secretHost)!
      store = FakeStore(trusted.map { [server.peerKey: $0] } ?? [:])
      connector = LoopbackConnector(fingerprint: serverFingerprint, screenName: screenName)
      var settings = ClientRuntimeSettings(
        server: server, screenName: screenName, interactive: interactive)
      settings.clock = clock
      runtime = ClientRuntime(
        settings: settings,
        backends: ClientBackends(
          injector: injector, screen: screen, clipboard: clipboard, lifecycle: lifecycle,
          geometry: ClientGeometryCache(testGeometry)),
        connector: connector, trustStore: store, output: output, prompt: prompt)
    }

    func start() -> Task<ClientExitCode, Never> {
      let runtime = runtime
      return Task { await runtime.run() }
    }

    /// The `index`-th server, set up with the client.
    func readyServer(_ index: Int) async throws -> ServerSide {
      let side = try #require(await connector.server(index))
      #expect(await side.started.value)
      await runtime.manager.waitForState { $0 == .connected }
      return side
    }

    func injected(_ event: KVMEvent) async {
      await injector.log.wait { $0.contains(.inject(event)) }
    }
  }

  /// Resolves once, with the runtime's code or with `nil` on cancellation.
  private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var resolved = false
    private(set) var code: ClientExitCode?

    func install(_ continuation: CheckedContinuation<Void, Never>) {
      let now = lock.withLock { () -> Bool in
        if resolved { return true }
        waiter = continuation
        return false
      }
      if now { continuation.resume() }
    }

    func resolve(_ value: ClientExitCode?) {
      let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        guard !resolved else { return nil }
        resolved = true
        code = value
        defer { waiter = nil }
        return waiter
      }
      continuation?.resume()
    }
  }

  /// The runtime's exit code, or `nil` when the waiting test is cancelled (its time limit), so
  /// a runtime that never ends fails a named test instead of hanging the run.
  private func finished(_ run: Task<ClientExitCode, Never>) async -> ClientExitCode? {
    let box = ExitBox()
    Task { box.resolve(await run.value) }
    await withTaskCancellationHandler {
      await withCheckedContinuation { box.install($0) }
    } onCancel: {
      box.resolve(nil)
    }
    return box.code
  }

  private func key(_ index: UInt8, _ phase: KeyPhase) -> KVMEvent {
    .key(key: .letter(index), phase: phase, modifiers: none)
  }

  private func clipboardPayload(_ text: String) -> ClipboardPayload {
    ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: text, contentHash: "s")
  }

  // MARK: - Runtime

  @Suite("M4-020-FOLLOWUP-001 Linux client runtime", .serialized, .timeLimit(.minutes(1)))
  struct LinuxClientRuntimeTests {
    @Test("enter, move, key, button, leave and clipboard both ways through the composition root")
    func fullFlow() async throws {
      let harness = Harness()
      let run = harness.start()
      let server = try await harness.readyServer(0)
      #expect(server.barrier.clientScreen == BarrierClientScreen(width: 1600, height: 900))

      try await server.session.enter(at: NormalizedPoint(x: 0, y: 0.5))
      await harness.injected(.mouseMove(position: NormalizedPoint(x: 0, y: 450.0 / 899)))
      #expect(harness.runtime.coordinator.state == .active)

      try await server.session.forward(.mouseMove(position: NormalizedPoint(x: 0.25, y: 0.75)))
      await harness.injected(.mouseMove(position: NormalizedPoint(x: 400.0 / 1599, y: 674.0 / 899)))
      for phase in [ButtonPhase.down, .up] {
        try await server.session.forward(.mouseButton(button: .left, phase: phase))
        await harness.injected(.mouseButton(button: .left, phase: phase))
      }
      try await server.session.forward(key(2, .down))
      await harness.injected(key(2, .down))
      try await server.session.forward(key(2, .up))
      await harness.injected(key(2, .up))

      // Server to client clipboard reaches the local clipboard.
      try await server.session.forward(.clipboard(clipboardPayload("from the mac")))
      await harness.clipboard.writes.wait { $0.contains("from the mac") }

      // A local copy while active is sent to the server.
      harness.clipboard.setLocalText("from linux")
      harness.clipboard.continuation.yield()
      await server.inbound.wait { entries in
        entries.contains {
          if case .clipboard(let p) = $0 { p.utf8Text == "from linux" } else { false }
        }
      }

      // Leave: the screen goes inactive and later input is dropped.
      try await server.session.forward(key(3, .down))
      await harness.injected(key(3, .down))
      try await server.session.leave()
      await harness.injector.log.wait { $0.contains(.inject(key(3, .up))) }
      while harness.runtime.coordinator.state == .active, !Task.isCancelled { await Task.yield() }

      harness.runtime.requestTermination(signal: SIGTERM)
      #expect(await finished(run) == .success)
      #expect(harness.injector.log.all.last == .close)
      #expect(harness.lifecycle.stops.all.count == 1)
      #expect(harness.screen.stops.all.count == 1)

      // Status lines are the closed vocabulary: no host, port, screen name or fingerprint.
      let statusText = harness.output.lines.all.compactMap { entry -> String? in
        if case .status(let text) = entry { text } else { nil }
      }.joined(separator: "\n")
      #expect(!statusText.isEmpty)
      for secret in [secretHost, "24800", screenName, "from linux", "from the mac"] {
        #expect(!harness.output.text.contains(secret))
      }
    }

    @Test("killing the server stream releases every held key and starts the next generation")
    func serverStreamKilled() async throws {
      let harness = Harness()
      let run = harness.start()
      let first = try await harness.readyServer(0)
      try await first.session.enter(at: NormalizedPoint(x: 0.5, y: 0.5))
      try await first.session.forward(.key(key: .shift, phase: .down, modifiers: none))
      try await first.session.forward(key(0, .down))
      try await first.session.forward(.mouseButton(button: .right, phase: .down))
      await harness.injected(.mouseButton(button: .right, phase: .down))
      #expect(harness.injector.heldCount == 3)

      await first.session.close(reason: .userRequested)
      await harness.injector.log.wait { $0.contains(.sweep(held: 0)) }
      #expect(harness.injector.heldCount == 0)
      let released = harness.injector.log.all.compactMap { entry -> KVMEvent? in
        if case .release(let event) = entry { event } else { nil }
      }
      #expect(released.contains(.mouseButton(button: .right, phase: .up)))
      #expect(released.contains { if case .key(.letter(0), .up, _) = $0 { true } else { false } })
      #expect(released.contains { if case .key(.shift, .up, _) = $0 { true } else { false } })

      // The manager waits its first backoff delay, then a new generation connects.
      await harness.runtime.manager.waitForState {
        if case .waiting = $0 { true } else { false }
      }
      await harness.lifecycle.polling.wait { $0.contains(true) }
      harness.clock.fire(duration: .seconds(1))
      let second = try await harness.readyServer(1)
      #expect(second.barrier.clientScreen != nil)
      #expect(harness.runtime.coordinator.diagnostics.sessions == 2)
      #expect(harness.runtime.coordinator.diagnostics.cleanupsRun == 1)

      harness.runtime.requestTermination(signal: SIGINT)
      #expect(await finished(run) == .success)
    }

    @Test("h.5: a wake while connected releases the old input before the new session injects")
    func wakeReleasesBeforeNewSession() async throws {
      let harness = Harness()
      let run = harness.start()
      let first = try await harness.readyServer(0)
      try await first.session.enter(at: NormalizedPoint(x: 0.5, y: 0.5))
      try await first.session.forward(key(4, .down))
      await harness.injected(key(4, .down))

      harness.lifecycle.continuation.yield(.didResume)
      let second = try #require(await harness.connector.server(1))
      #expect(await second.started.value)
      await harness.runtime.manager.waitForState { $0 == .connected }
      let fresh = NormalizedPoint(x: 0.25, y: 0.25)
      try await second.session.enter(at: fresh)
      let freshMove = KVMEvent.mouseMove(position: NormalizedPoint(x: 400.0 / 1599, y: 225.0 / 899))
      await harness.injected(freshMove)

      let log = harness.injector.log.all
      let releaseIndex = try #require(log.firstIndex(of: .release(key(4, .up))))
      let newIndex = try #require(log.firstIndex(of: .inject(freshMove)))
      #expect(releaseIndex < newIndex)
      #expect(first.end.disconnects.all.count >= 1)

      harness.runtime.requestTermination(signal: SIGHUP)
      #expect(await finished(run) == .success)
    }

    @Test("h.3: the network state is reported before each wake")
    func networkReportedBeforeWake() async throws {
      let harness = Harness()
      let run = harness.start()
      _ = try await harness.readyServer(0)
      harness.lifecycle.setNetwork(false)
      harness.lifecycle.continuation.yield(.didResume)
      let recovery = harness.runtime.recovery!
      while await !recovery.awaitingNetworkAfterWake, !Task.isCancelled { await Task.yield() }
      #expect(await recovery.awaitingNetworkAfterWake)
      #expect(await recovery.networkAvailable == false)
      #expect(harness.connector.servers.all.count == 1)

      harness.lifecycle.setNetwork(true)
      harness.lifecycle.continuation.yield(.networkAvailable)
      let second = try #require(await harness.connector.server(1))
      #expect(await second.started.value)

      harness.runtime.requestTermination(signal: SIGTERM)
      #expect(await finished(run) == .success)
    }

    @Test("h.3: a cancelled connection attempt runs the cleanup and closes its transport")
    func cancelledAttemptIsCleanedUp() async throws {
      let harness = Harness()
      harness.connector.serve = false
      let run = harness.start()
      let stuck = try #require(await harness.connector.server(0))
      await harness.runtime.manager.waitForState { $0 == .connecting }
      harness.connector.serve = true
      await harness.runtime.connect()
      await stuck.client.disconnects.wait { !$0.isEmpty }
      _ = try await harness.readyServer(1)
      #expect(harness.runtime.coordinator.diagnostics.cleanupsRun == 1)
      #expect(harness.runtime.coordinator.diagnostics.sessions == 2)

      harness.runtime.requestTermination(signal: SIGTERM)
      #expect(await finished(run) == .success)
    }

    @Test("h.3: termination stops the monitors and refuses later connects")
    func terminationRefusesConnect() async throws {
      let harness = Harness()
      let run = harness.start()
      _ = try await harness.readyServer(0)
      harness.runtime.requestTermination(signal: SIGTERM)
      #expect(await finished(run) == .success)
      #expect(harness.lifecycle.stops.all.count == 1)
      await harness.runtime.connect()
      await ClientReconnector(runtime: harness.runtime).connect()
      #expect(await harness.runtime.manager.state == .idle)
      #expect(harness.connector.servers.all.count == 1)
    }

    @Test("an injection failure that loses the display runs the cleanup and exits 69")
    func displayLossFromInjector() async throws {
      let harness = Harness()
      let run = harness.start()
      let server = try await harness.readyServer(0)
      try await server.session.enter(at: NormalizedPoint(x: 0.5, y: 0.5))
      try await server.session.forward(key(5, .down))
      await harness.injected(key(5, .down))
      harness.injector.failNextInjection(
        with: CoreError(
          code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
          cleanupDisposition: .notRequired))
      try await server.session.forward(key(6, .down))
      #expect(await finished(run) == .unavailable)
      #expect(harness.runtime.coordinator.diagnostics.cleanupsRun == 1)
      // After a display loss nothing touches Xlib: no release, no sweep, no close.
      let afterLoss = harness.injector.log.all.filter { entry in
        switch entry {
        case .inject: false
        case .release, .sweep, .close: true
        }
      }
      #expect(afterLoss.isEmpty)
      #expect(server.end.disconnects.all.count >= 1)
    }

    @Test("a screen stream that ends without a stop is a display loss: exit 69")
    func displayLossFromScreen() async throws {
      let harness = Harness()
      let run = harness.start()
      _ = try await harness.readyServer(0)
      harness.screen.continuation.finish()
      #expect(await finished(run) == .unavailable)
    }

    @Test("review: a drain worker parked by a display loss does not hang the cleanup; exit 69")
    func displayLossParksTheDrainWorker() async throws {
      let harness = Harness()
      let run = harness.start()
      let server = try await harness.readyServer(0)
      try await server.session.enter(at: NormalizedPoint(x: 0.5, y: 0.5))
      try await server.session.forward(key(8, .down))
      await harness.injected(key(8, .down))
      let runtime = harness.runtime
      harness.injector.parkNextInjection { runtime.displayLost() }
      try await server.session.forward(key(7, .down))
      #expect(await finished(run) == .unavailable)
      #expect(harness.runtime.coordinator.diagnostics.cleanupsRun == 1)
    }

    @Test("a lost display reported by Xlib's I/O error handler ends with exit 69")
    func displayLossFromXlib() async throws {
      let harness = Harness()
      let relay = ClientDisplayLossRelay()
      relay.set { [runtime = harness.runtime] in runtime.displayLost() }
      let run = harness.start()
      _ = try await harness.readyServer(0)
      ClientXErrorHandlers.install(
        setError: { _ in nil }, setIOError: { _ in nil }, onDisplayLost: { relay.fire() })
      #expect(ClientXErrorHandlers.handleIOError())
      #expect(!ClientXErrorHandlers.handleIOError())
      ClientXErrorHandlers.restore(setError: { _ in nil }, setIOError: { _ in nil })
      #expect(await finished(run) == .unavailable)
    }
  }

  // MARK: - Trust

  @Suite("M4-020-FOLLOWUP-001 Linux client trust flow", .serialized, .timeLimit(.minutes(1)))
  struct LinuxClientTrustTests {
    @Test("an unknown fingerprint exits 78 with instructions that name no host; nothing written")
    func unknownNonInteractive() async throws {
      let harness = Harness(trusted: nil)
      let run = harness.start()
      #expect(await finished(run) == .trustDecisionNeeded)
      #expect(harness.store.writes == 0)
      let text = harness.output.text
      let display = try #require(LinuxFingerprintText.canonicalDisplay(of: serverFingerprint))
      let hex = try #require(LinuxFingerprintText.lowercaseHex(of: serverFingerprint))
      #expect(text.contains(display))
      #expect(text.contains("mackvm-client fingerprint trust <host>[:port] \(hex)"))
      #expect(!text.contains(secretHost))
      #expect(!text.contains("24800"))
      #expect(!text.contains(screenName))
      // The handshake failed closed: the server never saw a set-up client.
      #expect(harness.connector.servers.all.first?.barrier.clientScreen == nil)
    }

    @Test("interactive: trust stores the presented fingerprint once and connects")
    func unknownInteractiveTrust() async throws {
      let harness = Harness(trusted: nil, interactive: true, prompt: { "trust" })
      let run = harness.start()
      _ = try await harness.readyServer(1)
      #expect(harness.store.writes == 1)
      #expect(harness.store.stored(harness.server.peerKey) == serverFingerprint)
      harness.runtime.requestTermination(signal: SIGTERM)
      #expect(await finished(run) == .success)
    }

    @Test(
      "review: a signal or a display loss while the prompt waits declines and exits",
      arguments: [false, true])
    func promptInterrupted(byDisplayLoss: Bool) async {
      let harness = Harness(
        trusted: nil, interactive: true,
        prompt: {
          try? await Task.sleep(nanoseconds: 3_600_000_000_000)
          return "trust"
        })
      let run = harness.start()
      await harness.output.lines.wait { lines in
        lines.contains { entry in
          if case .message(let text) = entry { text.contains("Type trust") } else { false }
        }
      }
      if byDisplayLoss {
        harness.runtime.displayLost()
      } else {
        harness.runtime.requestTermination(signal: SIGINT)
      }
      #expect(await finished(run) == (byDisplayLoss ? .unavailable : .success))
      #expect(harness.store.writes == 0)
    }

    @Test("interactive: stdin closed without an answer stores nothing and exits 78")
    func promptEndOfInput() async {
      let harness = Harness(trusted: nil, interactive: true, prompt: { nil })
      #expect(await finished(harness.start()) == .trustDecisionNeeded)
      #expect(harness.store.writes == 0)
    }

    @Test("interactive: any other answer stores nothing and exits 78")
    func unknownInteractiveDecline() async {
      let harness = Harness(trusted: nil, interactive: true, prompt: { "yes" })
      #expect(await finished(harness.start()) == .trustDecisionNeeded)
      #expect(harness.store.writes == 0)
    }

    @Test("a changed fingerprint is refused, both shown, nothing replaced, exit 78")
    func changedFingerprint() async throws {
      let harness = Harness(trusted: otherFingerprint, interactive: true, prompt: { "trust" })
      #expect(await finished(harness.start()) == .trustDecisionNeeded)
      #expect(harness.store.writes == 0)
      #expect(harness.store.stored(harness.server.peerKey) == otherFingerprint)
      let text = harness.output.text
      #expect(
        text.contains(try #require(LinuxFingerprintText.canonicalDisplay(of: serverFingerprint))))
      #expect(
        text.contains(try #require(LinuxFingerprintText.canonicalDisplay(of: otherFingerprint))))
      #expect(!text.contains(secretHost))
    }

    @Test("an unusable trust store fails closed with exit 78")
    func storeUnavailable() async {
      let harness = Harness()
      harness.store.unavailable = true
      #expect(await finished(harness.start()) == .trustDecisionNeeded)
      #expect(harness.connector.servers.all.isEmpty)
    }

    @Test("the evaluator accepts only the stored value")
    func evaluator() {
      let observation = ClientTrustObservation()
      #expect(
        observation.evaluate(stored: serverFingerprint, presented: serverFingerprint) == .accept)
      #expect(
        observation.evaluate(stored: nil, presented: serverFingerprint) == .reject(.identityUnknown)
      )
      #expect(
        observation.evaluate(stored: otherFingerprint, presented: serverFingerprint)
          == .reject(.identityChanged))
      #expect(observation.evaluate(stored: nil, presented: Data([1])) == .reject(.trustRejected))
    }
  }

  // MARK: - Command line

  private final class XlibRecorder: ClientXlibSetup, @unchecked Sendable {
    let calls = Recorder<String>()
    var threadsOK = true
    func initializeThreads() -> Bool {
      calls.append("XInitThreads")
      return threadsOK
    }
    func installHandlers(onDisplayLost: @escaping @Sendable () -> Void) {
      calls.append("installHandlers")
    }
    func restoreHandlers() { calls.append("restoreHandlers") }
  }

  private func failure(_ code: CoreErrorCode) -> CoreError {
    CoreError(
      code: code, severity: .error, retryDisposition: .never, cleanupDisposition: .notRequired)
  }

  private struct ProcessHarness {
    let output = RecordingOutput()
    let xlib = XlibRecorder()
    let store: FakeStore
    let connector = LoopbackConnector(fingerprint: serverFingerprint, screenName: screenName)
    var variables = ["DISPLAY": ":0", "HOME": "/home/u"]
    var euid: uid_t = 1000
    var injectorError: CoreError?

    init(store: FakeStore = FakeStore()) {
      self.store = store
    }

    func process() -> ClientProcess {
      let xlib = xlib
      let injectorError = injectorError
      let factory = ClientBackendFactory(
        screen: { _ throws(CoreError) in
          xlib.calls.append("screen")
          return FakeScreen()
        },
        injector: { _, _ throws(CoreError) in
          xlib.calls.append("injector")
          if let injectorError { throw injectorError }
          return FakeInjector()
        },
        clipboard: { _ throws(CoreError) in
          xlib.calls.append("clipboard")
          return FakeClipboard()
        },
        lifecycle: { FakeLifecycle() })
      let connector = connector
      return ClientProcess(
        variables: variables, effectiveUserID: euid, stdinIsTerminal: false, output: output,
        trustStore: store, connector: { _ in connector }, xlib: xlib, factory: factory,
        prompt: { nil }, runtimeStarted: { $0.requestTermination(signal: SIGTERM) })
    }

    func run(_ arguments: [String]) async -> ClientExitCode {
      await ClientMain.run(arguments, process: process())
    }
  }

  /// Command lines the parser must reject (built in statements for the type checker).
  private let rejectedCommandLines: [[String]] = {
    var lines: [[String]] = [[], ["serve"], ["connect"], ["connect", "--name", "x"]]
    lines.append(["connect", "mac"])
    lines.append(["connect", "mac", "--name"])
    lines.append(["connect", "mac", "--name", ""])
    lines.append(["connect", "mac", "--name", "has space"])
    lines.append(["connect", "mac", "--name", "\u{E9}"])
    lines.append(["connect", "mac", "--name", String(repeating: "n", count: 65)])
    lines.append(["connect", "mac", "--name", "a", "--name", "b"])
    lines.append(["connect", "mac", "--name", "a", "--display"])
    lines.append(["connect", "mac", "--name", "a", "--display", "0"])
    lines.append(["connect", "mac", "--name", "a", "--display", ":x"])
    lines.append(["connect", "mac", "--name", "a", "--non-interactive", "--non-interactive"])
    lines.append(["connect", "mac", "--name", "a", "--port", "1"])
    for server in [
      "mac:0", "mac:65536", "mac:024800", "mac:", "fe80::1", "[fe80::1", ":24800", "a/b",
    ] {
      lines.append(["connect", server, "--name", "a"])
    }
    lines.append(["fingerprint"])
    lines.append(["fingerprint", "show"])
    lines.append(["fingerprint", "list", "mac"])
    lines.append(["fingerprint", "show", "mac", "extra"])
    lines.append(["fingerprint", "trust", "mac"])
    lines.append(["fingerprint", "trust", "mac", String(repeating: "a", count: 63)])
    lines.append(["fingerprint", "trust", "mac", String(repeating: "g", count: 64)])
    let short = Array(repeating: "AB", count: 31).joined(separator: ":")
    lines.append(["fingerprint", "trust", "mac", short])
    lines.append(["fingerprint", "trust", "mac", "A:" + short])
    return lines
  }()

  @Suite("M4-020-FOLLOWUP-001 Linux client command line", .serialized, .timeLimit(.minutes(1)))
  struct LinuxClientCommandLineTests {
    @Test("the parser accepts the documented forms")
    func parserAccepts() throws {
      let mac = try #require(ClientServerAddress("mac.local"))
      #expect(mac.port == 24_800)
      #expect(mac.peerKey.rawValue == "mac.local:24800")
      #expect(ClientServerAddress("Mac.Local:4242")?.peerKey.rawValue == "mac.local:4242")
      #expect(ClientServerAddress("10.0.0.2:65535")?.port == 65_535)
      #expect(ClientServerAddress("[fe80::1]:24801")?.host == "fe80::1")
      #expect(ClientServerAddress("[::1]")?.port == 24_800)

      #expect(
        ClientConfiguration.parse(["connect", "mac.local", "--name", "linux-desk"])
          == .connect(
            ClientConnectOptions(server: mac, screenName: "linux-desk", displayName: nil)))
      #expect(
        ClientConfiguration.parse([
          "connect", "mac.local:24801", "--display", ":1", "--name", "A_b-9", "--non-interactive",
        ])
          == .connect(
            ClientConnectOptions(
              server: ClientServerAddress("mac.local:24801")!, screenName: "A_b-9",
              displayName: ":1", nonInteractive: true)))
      #expect(
        ClientConfiguration.parse(["connect", "h", "--name", String(repeating: "n", count: 64)])
          != nil)
      #expect(
        ClientConfiguration.parse(["fingerprint", "show", "mac.local"]) == .fingerprintShow(mac))
      #expect(
        ClientConfiguration.parse(["fingerprint", "forget", "mac.local"]) == .fingerprintForget(mac)
      )
      let hex = String(repeating: "ab", count: 32)
      let colons = Array(repeating: "AB", count: 32).joined(separator: ":")
      let digest = Data(repeating: 0xAB, count: 32)
      #expect(
        ClientConfiguration.parse(["fingerprint", "trust", "mac.local", hex])
          == .fingerprintTrust(mac, digest))
      #expect(
        ClientConfiguration.parse(["fingerprint", "trust", "mac.local", colons])
          == .fingerprintTrust(mac, digest))
      #expect(ClientConfiguration.isDisplayName(":0.1"))
      #expect(ClientConfiguration.isDisplayName("host-a:10"))
    }

    @Test("the parser rejects malformed command lines", arguments: rejectedCommandLines)
    func parserRejects(_ arguments: [String]) {
      #expect(ClientConfiguration.parse(arguments) == nil)
    }

    @Test("exit codes: usage 64, root refused, no X11 display 69")
    func earlyExitCodes() async {
      var harness = ProcessHarness()
      #expect(await harness.run(["connect"]) == .usage)
      #expect(await harness.run(["fingerprint", "show", "mac", "x"]) == .usage)

      harness.euid = 0
      #expect(await harness.run(["fingerprint", "forget", "mac"]) == .failure)
      #expect(harness.store.writes == 0)

      harness.euid = 1000
      harness.variables = [:]
      #expect(await harness.run(["connect", "mac", "--name", "n"]) == .unavailable)
      harness.variables = ["DISPLAY": ":0", "WAYLAND_DISPLAY": "wayland-0"]
      #expect(await harness.run(["connect", "mac", "--name", "n"]) == .unavailable)
      #expect(harness.xlib.calls.all.isEmpty)
    }

    @Test("h.8: XInitThreads, then the handlers, then the displays; missing XTest exits 69")
    func bootstrapOrder() async {
      var harness = ProcessHarness()
      harness.injectorError = failure(.permission(.capabilityUnavailable))
      #expect(await harness.run(["connect", "mac", "--name", "n"]) == .unavailable)
      #expect(
        harness.xlib.calls.all == [
          "XInitThreads", "installHandlers", "screen", "injector", "restoreHandlers",
        ])
    }

    @Test("h.8: a failed XInitThreads opens no display")
    func threadsFailure() async {
      let harness = ProcessHarness()
      harness.xlib.threadsOK = false
      #expect(
        await harness.run(["connect", "mac", "--name", "n", "--display", ":3"]) == .unavailable)
      #expect(harness.xlib.calls.all == ["XInitThreads"])
    }

    @Test("connect runs the runtime after the bootstrap and ends on a signal with 0")
    func connectAndSignal() async {
      let harness = ProcessHarness(
        store: FakeStore([ClientServerAddress("mac")!.peerKey: serverFingerprint]))
      #expect(await harness.run(["connect", "mac", "--name", screenName]) == .success)
      #expect(
        harness.xlib.calls.all == [
          "XInitThreads", "installHandlers", "screen", "injector", "clipboard", "restoreHandlers",
        ])
    }

    @Test("fingerprint trust, forget and show")
    func fingerprintCommands() async throws {
      let harness = ProcessHarness()
      let hex = try #require(LinuxFingerprintText.lowercaseHex(of: serverFingerprint))
      #expect(await harness.run(["fingerprint", "trust", "mac", hex]) == .success)
      #expect(await harness.run(["fingerprint", "trust", "mac", hex.uppercased()]) == .success)
      #expect(harness.store.writes == 1)
      let other = String(repeating: "ee", count: 32)
      #expect(await harness.run(["fingerprint", "trust", "mac", other]) == .trustDecisionNeeded)
      #expect(harness.store.stored(ClientServerAddress("mac")!.peerKey) == serverFingerprint)

      #expect(await harness.run(["fingerprint", "show", "mac"]) == .success)
      let display = try #require(LinuxFingerprintText.canonicalDisplay(of: serverFingerprint))
      #expect(harness.output.text.contains("presented SHA-256: \(display)"))
      // show never sets up a session: the handshake was refused before any byte.
      #expect(harness.connector.servers.all.first?.barrier.clientScreen == nil)

      #expect(await harness.run(["fingerprint", "forget", "mac"]) == .success)
      #expect(harness.store.stored(ClientServerAddress("mac")!.peerKey) == nil)
      harness.store.unavailable = true
      #expect(await harness.run(["fingerprint", "trust", "mac", hex]) == .trustDecisionNeeded)
      #expect(await harness.run(["fingerprint", "forget", "mac"]) == .trustDecisionNeeded)
    }
  }

  // MARK: - Xlib handlers and the unit file

  @Suite(
    "M4-020-FOLLOWUP-001 Linux client Xlib handlers and unit", .serialized, .timeLimit(.minutes(1)))
  struct LinuxClientPlatformTests {
    @Test("h.8: the root handlers keep the previous ones, ignore protocol errors and restore")
    func handlerChain() {
      final class Slots: @unchecked Sendable {
        var error: XErrorHandler?
        var ioError: XIOErrorHandler?
        var setCalls = 0
      }
      let slots = Slots()
      let previous: XErrorHandler = { _, _ in 7 }
      let previousIO: XIOErrorHandler = { _ in 9 }
      slots.error = previous
      slots.ioError = previousIO
      let setError: ClientXErrorHandlers.SetError = { handler in
        defer { slots.error = handler }
        slots.setCalls += 1
        return slots.error
      }
      let setIOError: ClientXErrorHandlers.SetIOError = { handler in
        defer { slots.ioError = handler }
        return slots.ioError
      }
      ClientXErrorHandlers.install(setError: setError, setIOError: setIOError, onDisplayLost: {})
      ClientXErrorHandlers.install(setError: setError, setIOError: setIOError, onDisplayLost: {})
      #expect(slots.setCalls == 1)
      #expect(slots.error?(nil, nil) == 0)
      #expect(ClientXErrorHandlers.handleError() == 0)
      ClientXErrorHandlers.restore(setError: setError, setIOError: setIOError)
      #expect(slots.error?(nil, nil) == 7)
      #expect(slots.ioError?(nil) == 9)
      ClientXErrorHandlers.restore(setError: setError, setIOError: setIOError)
      #expect(slots.setCalls == 2)
    }

    @Test("the systemd user unit has the required keys and nothing unexpected")
    func unitFile() throws {
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let text = try String(
        contentsOf: root.appendingPathComponent("Apps/Linux/systemd/mackvm-client.service"),
        encoding: .utf8)
      var sections: [String: [String: String]] = [:]
      var order: [String] = []
      var current: String?
      for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("[") {
          #expect(line.hasSuffix("]"))
          current = String(line.dropFirst().dropLast())
          order.append(current!)
          continue
        }
        let section = try #require(current)
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        #expect(parts.count == 2)
        #expect(sections[section, default: [:]][parts[0]] == nil)
        sections[section, default: [:]][parts[0]] = parts[1]
      }
      #expect(order == ["Unit", "Service", "Install"])
      let unit = sections["Unit"] ?? [:]
      #expect(unit["Description"]?.contains("Barrier-compatible") == true)
      #expect(unit["After"] == "graphical-session.target")
      #expect(unit["PartOf"] == "graphical-session.target")
      let service = sections["Service"] ?? [:]
      let exec = try #require(service["ExecStart"])
      #expect(exec.hasPrefix("%h/.local/bin/mackvm-client connect "))
      #expect(exec.contains(" --name "))
      #expect(exec.hasSuffix(" --non-interactive"))
      #expect(service["Restart"] == "on-failure")
      #expect(service["RestartSec"] == "5")
      #expect(service["RestartPreventExitStatus"] == "64 69 78")
      #expect(service["Environment"] == nil)
      #expect(service["NoNewPrivileges"] == "yes")
      #expect(service["LockPersonality"] == "yes")
      #expect(service["RestrictSUIDSGID"] == "yes")
      #expect(service["RestrictAddressFamilies"] == "AF_UNIX AF_INET AF_INET6")
      #expect(service["UMask"] == "0077")
      #expect(service["User"] == nil)
      #expect(
        Set(service.keys) == [
          "ExecStart", "Restart", "RestartSec", "RestartPreventExitStatus", "NoNewPrivileges",
          "LockPersonality", "RestrictSUIDSGID", "RestrictAddressFamilies", "UMask",
        ])
      #expect(sections["Install"] == ["WantedBy": "graphical-session.target"])
      #expect(text.contains("not supported as root") || text.contains("never as root"))
    }
  }
#endif

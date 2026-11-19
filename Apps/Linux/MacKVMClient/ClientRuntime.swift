import BarrierCompatibility
import Foundation
import Glibc
import KVMContracts
import KVMCore
import LinuxPlatform
import NIOCore

// M4-020-FOLLOWUP-001: the composition root of the Linux client (plan b.16). First-party policy:
//
// - Wiring: the backends (screen, injector, clipboard, trust store, lifecycle monitor) behind
//   `ClientEffects`; `FailSafeCoordinator`, `CleanupHooks` and `ClientCoordinator` over them;
//   `ReconnectManager`, whose attempt builds a fresh transport and `BarrierClientProtocolSession`
//   per connection; `RecoveryCoordinator`, fed by the lifecycle monitor.
// - One cleanup per session generation (a.6.4): every exit of an attempt, a superseded attempt
//   included (h.3), ends its generation through `ClientCoordinator.terminate`, and the next
//   generation begins only after that cleanup returned (h.5). A terminate that returns
//   `skipped` does not wait; the runtime awaits every terminate it started before it begins the
//   next session, and treats `beginSession() == false` as wait-then-retry.
// - Trust (a.7): the stored fingerprint is read before each connection, and the TLS handshake
//   accepts only an equal one. Unknown and changed identities stop the reconnect generation
//   with `userActionRequired`; the runtime then prompts (interactive) or prints instructions and
//   exits 78. Nothing is stored without the person's `trust`.
// - Termination (SIGINT, SIGTERM, SIGHUP), display loss and stops end through `finish(...)`: the
//   monitors stop first, `connect()` is refused from then on (h.3), the current generation's
//   cleanup runs, and the backends are stopped. Display loss exits 69 (h.8).

// MARK: - Backends

/// The lifecycle calls the runtime needs beyond C-015. `LinuxLifecycleMonitor` provides them.
protocol ClientLifecycle: LifecycleBackend {
  func start()
  var isNetworkAvailable: Bool { get }
  func setNetworkPolling(_ enabled: Bool)
}

extension LinuxLifecycleMonitor: ClientLifecycle {}

/// Makes one single-use transport per connection attempt. Its TLS handshake must call
/// `evaluator` with the presented leaf fingerprint and fail closed unless it answers `.accept`.
protocol ClientConnector: Sendable {
  func makeTransport(evaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision)
    -> any Transport
}

/// The backends of one runtime, opened by `ClientBootstrap` in production.
struct ClientBackends: Sendable {
  var injector: any ClientInjector
  var screen: any ScreenBackend
  var clipboard: any ClipboardBackend
  var lifecycle: any ClientLifecycle
  /// The geometry the injector maps pointer positions with, updated from `screen.changes`.
  var geometry: ClientGeometryCache
}

/// The screen geometry the injector's `screen` callback reads. The callback runs under the
/// injector's lock, so it only reads this cache and never calls Xlib or the injector (M4-024).
final class ClientGeometryCache: @unchecked Sendable {
  private let lock = NSLock()
  private var geometry: PlatformScreenGeometry

  init(_ geometry: PlatformScreenGeometry) {
    self.geometry = geometry
  }

  var current: PlatformScreenGeometry { lock.withLock { geometry } }

  func update(_ geometry: PlatformScreenGeometry) {
    lock.withLock { self.geometry = geometry }
  }
}

// MARK: - Trust observation

/// What the handshake's trust evaluator decided, kept for the command line's display only. It is
/// never logged and never leaves the process except as the deliberate trust text (a.7).
final class ClientTrustObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var decision: LinuxTrustDecision?
  private var presentedDigest: Data?

  /// C-009 for one presented fingerprint against the record read before the connection.
  func evaluate(stored: Data?, presented: Data) -> LinuxTLSTrustDecision {
    let decision = LinuxTrustPolicy.decide(stored: stored, presented: presented)
    lock.withLock {
      self.decision = decision
      presentedDigest = Data(presented)
    }
    switch decision {
    case .allow: return .accept
    case .prompt: return .reject(.identityUnknown)
    case .identityChanged: return .reject(.identityChanged)
    case .reject(let code): return .reject(code)
    }
  }

  var lastDecision: LinuxTrustDecision? { lock.withLock { decision } }
  var presented: Data? { lock.withLock { presentedDigest } }
}

// MARK: - Runtime

/// The client's settings for one `connect`.
struct ClientRuntimeSettings: Sendable {
  var server: ClientServerAddress
  var screenName: String
  /// Prompt on an unknown identity; otherwise print instructions and exit 78.
  var interactive: Bool
  var clock: any KVMClock = ContinuousKVMClock()
  var handshakeTimeout: Duration = .seconds(10)
  /// Upper bound of the shutdown before the process exits anyway.
  var shutdownTimeout: Duration = .seconds(5)
  var backoff: ReconnectBackoff = .standard
}

/// How a runtime ended, before it is mapped to an exit code.
enum ClientEnding: Equatable, Sendable {
  case terminated(signal: Int32)
  case displayLost
  case stopped(CoreErrorCode)
}

/// The composition root of one `mackvm-client connect`.
final class ClientRuntime: @unchecked Sendable {
  private let settings: ClientRuntimeSettings
  private let backends: ClientBackends
  private let connector: any ClientConnector
  private let trustStore: any SecureStorageBackend
  private let output: any ClientOutput
  private let prompt: @Sendable () async -> String?
  private let localScreen: ScreenID
  private let clipboardLimit: ClipboardByteLimit

  let effects: ClientEffects
  let coordinator: ClientCoordinator
  private(set) var manager: ReconnectManager!
  private(set) var recovery: RecoveryCoordinator!

  private let lock = NSLock()
  private let promptGate = ClientPromptGate()
  private let slot: ClientSessionSlot
  private let terminations = ClientTerminations()
  private var freshGeneration = true
  private var refusing = false
  private var lastFailure: (error: CoreError, observation: ClientTrustObservation?)?
  private var finishTask: Task<ClientExitCode, Never>?
  private var pumps: [Task<Void, Never>] = []
  private let endings: AsyncStream<ClientEnding>
  private let endingContinuation: AsyncStream<ClientEnding>.Continuation

  init(
    settings: ClientRuntimeSettings, backends: ClientBackends, connector: any ClientConnector,
    trustStore: any SecureStorageBackend, output: any ClientOutput,
    prompt: @escaping @Sendable () async -> String?
  ) {
    self.settings = settings
    self.backends = backends
    self.connector = connector
    self.trustStore = trustStore
    self.output = output
    self.prompt = prompt
    (endings, endingContinuation) = AsyncStream.makeStream()
    let localScreen = ScreenID()
    let limit = ClipboardByteLimit(byteCount: BarrierClientProtocolSession.clipboardByteLimit)!
    let slot = ClientSessionSlot()
    let failureRelay = ClientFailureRelay()
    let effects = ClientEffects(
      injector: backends.injector,
      clipboard: ClientClipboardWriter(backend: backends.clipboard, limit: limit),
      output: output, onInjectionFailure: { failureRelay.fire($0) })
    self.localScreen = localScreen
    self.clipboardLimit = limit
    self.slot = slot
    self.effects = effects
    let failSafe = FailSafeCoordinator(safety: effects)
    coordinator = ClientCoordinator.make(
      localScreen: localScreen, effects: effects, clipboardLimit: limit,
      failSafe: failSafe,
      disconnect: { reason in await slot.close()?.disconnect(reason: reason) },
      clock: settings.clock)
    manager = ReconnectManager(backoff: settings.backoff, clock: settings.clock) {
      [weak self] established throws(CoreError) in
      guard let self else { throw ClientRuntime.cancelled }
      try await self.attempt(established)
    }
    recovery = RecoveryCoordinator(
      reconnector: ClientReconnector(runtime: self),
      onSleep: { [weak self] in await self?.endGeneration(.sleep) })
    failureRelay.set { [weak self] error in self?.injectionFailed(error) }
  }

  /// What an attempt throws when it was cancelled, or when its generation was ended from
  /// outside (a wake, a sleep, a termination). `backoff`, so a manager that was not superseded
  /// yet waits instead of stopping; the `connect()` or `disconnect()` that follows takes over.
  /// Bound of the `beginSession()` retry in `prepareGeneration` (5 ms each, 10 s in all). On
  /// expiry the attempt reports a superseded `backoff` failure and the manager retries later;
  /// it never polls forever.
  static let maximumBeginPolls = 2_000

  static let cancelled = CoreError(
    code: .cancellation(.superseded), severity: .info, retryDisposition: .backoff,
    cleanupDisposition: .completed)

  // MARK: Run

  /// Runs until a signal, a display loss or a stop that needs the person, and returns the exit
  /// code once the shutdown finished (or timed out).
  func run() async -> ClientExitCode {
    output.status(.starting)
    backends.lifecycle.start()
    startPumps()
    await connect()
    for await ending in endings {
      switch ending {
      case .terminated:
        return await finish(.termination, code: .success)
      case .displayLost:
        return await finish(.displayLost, code: .unavailable)
      case .stopped(let code):
        if let next = await handleStop(code) { return next }
      }
    }
    return await finish(.termination, code: .failure)
  }

  /// SIGINT, SIGTERM, SIGHUP.
  func requestTermination(signal: Int32) {
    output.status(.stopping(signal: signal))
    endingContinuation.yield(.terminated(signal: signal))
    promptGate.interrupt()
  }

  /// A backend reported that the X display is gone (h.8).
  func displayLost() {
    guard effects.markDisplayLost() else { return }
    output.status(.displayLost)
    endingContinuation.yield(.displayLost)
    promptGate.interrupt()
  }

  /// Starts a reconnect generation unless the runtime is terminating (h.3).
  func connect() async {
    guard !lock.withLock({ refusing }) else { return }
    await manager.connect()
  }

  private func injectionFailed(_ error: CoreError) {
    output.status(.injectionFailed(error.code))
    if error.code == .lifecycle(.subsystemUnavailable) {
      displayLost()
    }
    // Any other failure stops the drain; the next `inject` returns `false` and the
    // coordinator fails closed, which ends the session through its cleanup.
  }

  /// Handles a stopped reconnect generation. `nil` means the runtime goes on.
  private func handleStop(_ code: CoreErrorCode) async -> ClientExitCode? {
    let failure = lock.withLock { lastFailure }
    let observation = failure?.error.code == code ? failure?.observation : nil
    switch code {
    case .security(.identityUnknown):
      guard let presented = observation?.presented,
        observation?.lastDecision == .prompt
      else { return await finish(.termination, code: .trustDecisionNeeded) }
      guard settings.interactive else {
        output.message(ClientTrustText.unknownInstructions(presented: presented))
        return await finish(.termination, code: .trustDecisionNeeded)
      }
      output.message(ClientTrustText.unknownPrompt(presented: presented))
      // A signal or a display loss while the prompt waits is a decline: nothing is stored, and
      // the run loop then handles that ending with its own exit code.
      guard let answer = await promptGate.ask(prompt) else {
        output.message(ClientTrustText.notTrusted)
        if promptGate.wasInterrupted { return nil }
        return await finish(.termination, code: .trustDecisionNeeded)
      }
      guard answer.trimmingCharacters(in: .whitespaces) == "trust" else {
        output.message(ClientTrustText.notTrusted)
        return await finish(.termination, code: .trustDecisionNeeded)
      }
      let applied = await LinuxFirstUseTrust(store: trustStore).apply(
        ownerDecision: .trust, peer: settings.server.peerKey, presentedFingerprint: presented)
      guard case .success(.allow) = applied else {
        if case .failure = applied { output.status(.trustStoreUnavailable) }
        output.message(ClientTrustText.notTrusted)
        return await finish(.termination, code: .trustDecisionNeeded)
      }
      await connect()
      return nil
    case .security(.identityChanged):
      if case .identityChanged(let warning)? = observation?.lastDecision {
        output.message(ClientTrustText.changedWarning(warning))
      }
      return await finish(.termination, code: .trustDecisionNeeded)
    case .security(.secureStorageUnavailable):
      output.status(.trustStoreUnavailable)
      return await finish(.termination, code: .trustDecisionNeeded)
    case .security:
      output.message(ClientTrustText.rejected)
      return await finish(.termination, code: .trustDecisionNeeded)
    case .lifecycle(.subsystemUnavailable), .permission(.capabilityUnavailable):
      return await finish(.displayLost, code: .unavailable)
    default:
      return await finish(.termination, code: .failure)
    }
  }

  // MARK: Attempt

  /// One connection attempt for `ReconnectManager` (plan b.16, a.5).
  private func attempt(_ established: @escaping @Sendable () async -> Void) async throws(CoreError)
  {
    guard await prepareGeneration() else { throw Self.cancelled }
    slot.open()
    let observation = ClientTrustObservation()
    do throws(CoreError) {
      try await connectSession(observation: observation, established: established)
    } catch {
      // A failure caused by a cleanup claimed elsewhere is not this connection's verdict.
      if slot.superseded { throw Self.cancelled }
      record(error, observation: observation)
      if error.code.domain != .cancellation { output.status(.connectionEnded(error.code)) }
      throw error
    }
  }

  private func connectSession(
    observation: ClientTrustObservation, established: @escaping @Sendable () async -> Void
  ) async throws(CoreError) {
    let stored: Data?
    switch await trustStore.loadTrustedFingerprint(for: settings.server.peerKey) {
    case .success(let value):
      stored = value
    case .failure(let error):
      await endOwnGeneration(.transportFailure(error))
      throw error
    }
    let geometry = backends.geometry.current
    guard
      let screen = BarrierLocalScreen(
        originX: geometry.originX, originY: geometry.originY, width: geometry.width,
        height: geometry.height, cursorX: geometry.cursorX, cursorY: geometry.cursorY),
      let session = BarrierClientProtocolSession(
        transport: connector.makeTransport { observation.evaluate(stored: stored, presented: $0) },
        screenName: settings.screenName, localScreen: localScreen, screen: screen,
        clock: settings.clock, handshakeTimeout: settings.handshakeTimeout)
    else {
      let error = CoreError(
        code: .protocolViolation(.invariantViolation), severity: .error,
        retryDisposition: .never, cleanupDisposition: .notRequired)
      await endOwnGeneration(.protocolViolation(error))
      throw error
    }
    guard slot.install(session), !Task.isCancelled else {
      await session.disconnect(reason: .cancellation(.superseded))
      await endOwnGeneration(.cancelled)
      throw Self.cancelled
    }
    output.status(.connecting)
    do throws(CoreError) {
      try await session.connect()
    } catch {
      await endOwnGeneration(
        Task.isCancelled ? .cancelled : CleanupHooks.trigger(for: .failure(error)))
      // A cleanup claimed elsewhere (a wake, a sleep, a signal) may have run before this
      // session was installed; the session is closed here either way. Idempotent.
      await session.disconnect(reason: .failure(error))
      throw error
    }
    guard !Task.isCancelled, !lock.withLock({ refusing }) else {
      await endOwnGeneration(.cancelled)
      await session.disconnect(reason: .cancellation(.superseded))
      throw Self.cancelled
    }
    await established()
    output.status(.connected)
    try await runSession(session)
  }

  /// Feeds the session's events to the coordinator until the session ends, then returns or
  /// throws as the session ended (a.5).
  private func runSession(_ session: BarrierClientProtocolSession) async throws(CoreError) {
    let ending = ClientStreamEnding()
    let (relay, relayContinuation) = AsyncThrowingStream<KVMEvent, any Error>.makeStream()
    let pump = Task {
      do {
        for try await event in session.events {
          relayContinuation.yield(Self.withContentHash(event))
        }
        relayContinuation.finish()
      } catch {
        ending.set(error)
        relayContinuation.finish(throwing: error)
      }
    }
    let coordinator = coordinator
    let run = terminations.start { await coordinator.run(relay) }
    let outcome = await withTaskCancellationHandler {
      await run.value
    } onCancel: {
      run.cancel()
    }
    if outcome.ran { output.status(.cleanup(outcome.disposition)) }
    // When another caller claimed this generation's cleanup, its disconnect may have missed a
    // session installed late; closing it again is idempotent.
    await session.disconnect(reason: .cancellation(.superseded))
    await pump.value
    if Task.isCancelled { throw Self.cancelled }
    if let error = ending.error as? CoreError { throw error }
    output.status(.connectionEnded(nil))
  }

  private func record(_ error: CoreError, observation: ClientTrustObservation) {
    lock.withLock { lastFailure = (error, observation) }
  }

  /// Opens the next session generation: the first attempt uses the one the coordinator began at
  /// `init`; later ones wait for every terminate the runtime started, then retry
  /// `beginSession()` until the previous cleanup has returned. `false` when terminating or
  /// cancelled.
  private func prepareGeneration() async -> Bool {
    let fresh = lock.withLock { () -> Bool in
      defer { freshGeneration = false }
      return freshGeneration
    }
    if fresh { return !lock.withLock({ refusing }) }
    var polls = 0
    while true {
      if lock.withLock({ refusing }) || Task.isCancelled { return false }
      if coordinator.beginSession() {
        effects.startSession()
        return true
      }
      await terminations.waitForAll()
      if coordinator.beginSession() {
        effects.startSession()
        return true
      }
      // The claimed cleanup was started by a terminate this runtime did not track (the
      // coordinator's own `run`, already awaited, never leaves one behind); poll briefly.
      polls += 1
      if polls >= Self.maximumBeginPolls { return false }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  /// Ends the current generation from outside its attempt (a wake, a sleep, a termination): the
  /// attempt then reports a superseded connection instead of the error the cleanup causes.
  func endGeneration(_ trigger: CleanupTrigger) async {
    slot.markSuperseded()
    await endOwnGeneration(trigger)
  }

  /// Ends the current generation with its one cleanup and waits for it, or returns at once
  /// when another caller already claimed it.
  private func endOwnGeneration(_ trigger: CleanupTrigger) async {
    let coordinator = coordinator
    let task = terminations.start { await coordinator.terminate(trigger) }
    let outcome = await task.value
    if outcome.ran { output.status(.cleanup(outcome.disposition)) }
  }

  // MARK: Pumps

  private func startPumps() {
    let lifecycle = backends.lifecycle
    let screen = backends.screen
    let clipboard = backends.clipboard
    let tasks = [
      Task { [weak self] in
        for await signal in lifecycle.signals {
          guard let self else { return }
          await self.handle(signal)
        }
      },
      Task { [weak self] in
        for await geometry in screen.changes {
          guard let self else { return }
          await self.screenChanged(geometry)
        }
        self?.backendStreamEnded()
      },
      Task { [weak self] in
        for await _ in clipboard.ownerChanges {
          guard let self else { return }
          await self.localClipboardChanged()
        }
        self?.backendStreamEnded()
      },
      Task { [weak self] in
        guard let self else { return }
        await self.watchReconnects()
      },
    ]
    lock.withLock { pumps = tasks }
  }

  /// The lifecycle monitor's signals, through `RecoveryCoordinator` (M1-061, h.3).
  private func handle(_ signal: LifecycleSignal) async {
    switch signal {
    case .didResume:
      output.status(.resumed)
      // h.3: the current network state is reported before each wake.
      await recovery.handle(.networkAvailable(backends.lifecycle.isNetworkAvailable))
      await recovery.handle(.didWake)
    case .networkAvailable:
      output.status(.networkAvailable(true))
      await recovery.handle(.networkAvailable(true))
    case .networkUnavailable:
      output.status(.networkAvailable(false))
      await recovery.handle(.networkAvailable(false))
    case .willSuspend:
      await recovery.handle(.willSleep)
    case .terminationRequested:
      endingContinuation.yield(.terminated(signal: SIGTERM))
    }
  }

  private func screenChanged(_ geometry: PlatformScreenGeometry) async {
    backends.geometry.update(geometry)
    guard
      let screen = BarrierLocalScreen(
        originX: geometry.originX, originY: geometry.originY, width: geometry.width,
        height: geometry.height, cursorX: geometry.cursorX, cursorY: geometry.cursorY)
    else { return }
    try? await slot.current?.updateScreen(screen)
  }

  /// An inbound clipboard with the content hash the loop guard compares (M4-026-FOLLOWUP-001).
  /// The protocol session leaves it empty, so without this every server clipboard after the
  /// first in a session matched the first and was dropped as `loopRejected`. It is made the
  /// way the X11 backend hashes a local read (C-015 SHA-256), so both directions agree.
  static func withContentHash(_ event: KVMEvent) -> KVMEvent {
    guard case .clipboard(let payload) = event else { return event }
    return .clipboard(
      ClipboardPayload(
        transactionID: payload.transactionID, origin: payload.origin,
        utf8Text: payload.utf8Text,
        contentHash: LinuxX11ClipboardRules.contentHash(of: payload.utf8Text)))
  }

  /// A local copy while input is on this screen is offered to the server (a.8). The text is
  /// read only while active, and never logged.
  private func localClipboardChanged() async {
    guard coordinator.state == .active else { return }
    guard case .success(let read?) = await backends.clipboard.readPlainText(limit: clipboardLimit)
    else { return }
    let payload = ClipboardPayload(
      transactionID: ClipboardTransactionID(), origin: .local, utf8Text: read.text,
      contentHash: read.contentHash)
    guard let admitted = coordinator.localClipboardChanged(payload) else { return }
    try? await slot.current?.send(.clipboard(admitted))
  }

  /// A screen or clipboard stream ended without a stop: the display is gone (h.8).
  private func backendStreamEnded() {
    guard !lock.withLock({ refusing }) else { return }
    displayLost()
  }

  /// Reports reconnect states, arms the network poll while a reconnect waits, and turns a
  /// stopped generation into an ending.
  private func watchReconnects() async {
    var previous = ReconnectState.idle
    while !Task.isCancelled {
      let seen = ClientStateBox()
      let last = previous
      await manager.waitForState { state in
        guard state != last else { return false }
        seen.set(state)
        return true
      }
      guard let state = seen.state else { return }
      previous = state
      switch state {
      case .waiting(_, let delay):
        backends.lifecycle.setNetworkPolling(true)
        output.status(.waitingToReconnect(seconds: Int(delay.components.seconds)))
      case .connected:
        backends.lifecycle.setNetworkPolling(false)
      case .stopped(let code):
        backends.lifecycle.setNetworkPolling(true)
        output.status(.stopped(code))
        endingContinuation.yield(.stopped(code))
      case .idle, .connecting:
        break
      }
    }
  }

  // MARK: Finish

  /// The one shutdown (h.3): refuse `connect()`, stop the monitors, run the current
  /// generation's cleanup, stop the manager and the backends. Bounded by
  /// `settings.shutdownTimeout`; later callers get the first caller's code.
  func finish(_ trigger: CleanupTrigger, code: ClientExitCode) async -> ClientExitCode {
    let task = lock.withLock { () -> Task<ClientExitCode, Never> in
      if let finishTask { return finishTask }
      refusing = true
      // Not a task group: a group waits for every child, so a shutdown step stuck in Xlib
      // would defeat the bound.
      let clock = settings.clock
      let timeout = settings.shutdownTimeout
      let task = Task { [self] in
        let gate = ClientOnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let timer = Task {
            try? await clock.sleep(for: timeout)
            if gate.claim() {
              self.output.status(.shutdownTimedOut)
              continuation.resume()
            }
          }
          Task {
            await self.shutdown(trigger)
            if gate.claim() {
              timer.cancel()
              continuation.resume()
            }
          }
        }
        return code
      }
      finishTask = task
      return task
    }
    return await task.value
  }

  private func shutdown(_ trigger: CleanupTrigger) async {
    backends.lifecycle.stop()
    // Release first, with its own bound, so a later step that blocks cannot leave input held
    // when the shutdown bound cuts it (review of PR #370). The cleanup below releases again.
    if !effects.sweepBeforeShutdown() { output.status(.cleanup(.partial)) }
    await endGeneration(trigger)
    await manager.disconnect()
    await terminations.waitForAll()
    let tasks = lock.withLock { pumps }
    for task in tasks { task.cancel() }
    endingContinuation.finish()
    // After a display loss the backends are left as they are: stopping them could reach Xlib on
    // the dead connection, and the process exits next (h.8).
    guard !effects.isDisplayLost else { return }
    await backends.screen.stop()
    await backends.clipboard.stop()
    if case .failure = effects.shutdown() {
      output.status(.cleanup(.partial))
    }
  }
}

// MARK: - Helpers

/// The reconnector `RecoveryCoordinator` drives (M1-061). A wake first ends the current
/// generation, so its held input is released before the new session injects (h.5); once the
/// runtime is terminating, `connect()` is refused (h.3).
final class ClientReconnector: RecoveryReconnector, @unchecked Sendable {
  private weak var runtime: ClientRuntime?

  init(runtime: ClientRuntime) {
    self.runtime = runtime
  }

  func connect() async {
    guard let runtime else { return }
    await runtime.endGeneration(.cancelled)
    await runtime.connect()
  }

  func disconnect() async {
    await runtime?.manager.disconnect()
  }
}

/// The session of the current generation, for the cleanup's disconnect and for outbound sends.
/// Once the cleanup closed it, a session made late by its attempt is refused.
final class ClientSessionSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var session: BarrierClientProtocolSession?
  private var closed = true
  private var endedOutside = false

  func open() {
    lock.withLock {
      session = nil
      closed = false
      endedOutside = false
    }
  }

  /// Records that the current generation is being ended from outside its attempt.
  func markSuperseded() {
    lock.withLock { endedOutside = true }
  }

  /// Whether the current generation was ended from outside its attempt.
  var superseded: Bool { lock.withLock { endedOutside } }

  /// `false` when the generation's cleanup already closed the slot.
  func install(_ session: BarrierClientProtocolSession) -> Bool {
    lock.withLock {
      guard !closed else { return false }
      self.session = session
      return true
    }
  }

  var current: BarrierClientProtocolSession? { lock.withLock { closed ? nil : session } }

  /// Closes the slot and hands back its session, if any.
  func close() -> BarrierClientProtocolSession? {
    lock.withLock {
      closed = true
      defer { session = nil }
      return session
    }
  }
}

/// Every terminate the runtime started, so the next generation can wait for them.
final class ClientTerminations: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UInt64: Task<CleanupOutcome, Never>] = [:]
  private var next: UInt64 = 0

  func start(_ body: @escaping @Sendable () async -> CleanupOutcome) -> Task<CleanupOutcome, Never>
  {
    lock.withLock {
      next &+= 1
      let id = next
      let task = Task { [weak self] in
        let outcome = await body()
        self?.remove(id)
        return outcome
      }
      tasks[id] = task
      return task
    }
  }

  func waitForAll() async {
    let pending = lock.withLock { Array(tasks.values) }
    for task in pending { _ = await task.value }
  }

  private func remove(_ id: UInt64) {
    _ = lock.withLock { tasks.removeValue(forKey: id) }
  }
}

/// Lets exactly one of two racing completions resume a continuation.
private final class ClientOnceGate: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      defer { claimed = true }
      return !claimed
    }
  }
}

/// The error that ended a session's event stream.
private final class ClientStreamEnding: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: (any Error)?

  func set(_ error: any Error) { lock.withLock { stored = error } }
  var error: (any Error)? { lock.withLock { stored } }
}

private final class ClientStateBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: ReconnectState?

  func set(_ state: ReconnectState) { lock.withLock { value = state } }
  var state: ReconnectState? { lock.withLock { value } }
}

/// Lets the effects report an injection failure to the runtime built after them.
private final class ClientFailureRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (CoreError) -> Void)?

  func set(_ handler: @escaping @Sendable (CoreError) -> Void) {
    lock.withLock { self.handler = handler }
  }

  func fire(_ error: CoreError) {
    let handler = lock.withLock { self.handler }
    handler?(error)
  }
}

// MARK: - Commands

/// `LinuxTLSTransport` over one shared single-thread event loop group (plan b.16).
struct ClientTLSConnector: ClientConnector {
  static let connectTimeout: Duration = .seconds(10)

  let server: ClientServerAddress
  let group: any EventLoopGroup

  func makeTransport(evaluator: @escaping @Sendable (Data) -> LinuxTLSTrustDecision)
    -> any Transport
  {
    LinuxTLSTransport(
      request: LinuxTLSConnectionRequest(
        host: server.host, port: server.port, connectTimeout: Self.connectTimeout),
      group: group, trustEvaluator: evaluator)
  }
}

/// Everything `ClientMain` reads from the process, injected so tests can run it with fakes.
struct ClientProcess: Sendable {
  var variables: [String: String]
  var effectiveUserID: uid_t
  var stdinIsTerminal: Bool
  var output: any ClientOutput
  var trustStore: any SecureStorageBackend
  var connector: @Sendable (ClientServerAddress) -> any ClientConnector
  var xlib: any ClientXlibSetup
  var factory: ClientBackendFactory
  var prompt: @Sendable () async -> String?
  /// Called once the runtime exists, so SIGINT, SIGTERM and SIGHUP reach it.
  var runtimeStarted: @Sendable (ClientRuntime) -> Void
  var settings: @Sendable (ClientConnectOptions, Bool) -> ClientRuntimeSettings = {
    options, interactive in
    ClientRuntimeSettings(
      server: options.server, screenName: options.screenName, interactive: interactive)
  }
}

/// The command dispatch of `mackvm-client`.
enum ClientMain {
  static func run(_ arguments: [String], process: ClientProcess) async -> ClientExitCode {
    guard let command = ClientConfiguration.parse(arguments) else {
      process.output.error(ClientConfiguration.usage)
      return .usage
    }
    // The trust store accepts state owned by the effective user; as root that is root-owned
    // state anywhere (M4-021-FOLLOWUP-001), so root is refused before anything is read.
    guard process.effectiveUserID != 0 else {
      process.output.error(ClientTrustText.rootUnsupported)
      return .failure
    }
    switch command {
    case .connect(let options):
      return await connect(options, process: process)
    case .fingerprintShow(let server):
      return await show(server, process: process)
    case .fingerprintTrust(let server, let digest):
      return await trust(digest, for: server, process: process)
    case .fingerprintForget(let server):
      switch await process.trustStore.removeTrustedFingerprint(for: server.peerKey) {
      case .success:
        process.output.message("forgotten")
        return .success
      case .failure:
        process.output.status(.trustStoreUnavailable)
        return .trustDecisionNeeded
      }
    }
  }

  private static func connect(_ options: ClientConnectOptions, process: ClientProcess) async
    -> ClientExitCode
  {
    var variables = process.variables
    if let display = options.displayName {
      variables[LinuxDisplayEnvironment.displayVariable] = display
    }
    guard LinuxDisplayEnvironment.detect(environment: variables).isSupported else {
      process.output.error(
        "no X11 display: set DISPLAY or pass --display (Wayland is not supported)")
      return .unavailable
    }
    let lost = ClientDisplayLossRelay()
    let opened = await ClientBootstrap.open(
      displayName: options.displayName, xlib: process.xlib, factory: process.factory,
      onDisplayLost: { lost.fire() })
    let backends: ClientBackends
    switch opened {
    case .success(let value):
      backends = value
    case .failure(let error):
      process.output.error(
        "the X11 display or XTest is unavailable (\(ClientReport.name(of: error.code)))")
      return .unavailable
    }
    let interactive = !options.nonInteractive && process.stdinIsTerminal
    let runtime = ClientRuntime(
      settings: process.settings(options, interactive), backends: backends,
      connector: process.connector(options.server), trustStore: process.trustStore,
      output: process.output, prompt: process.prompt)
    lost.set { [weak runtime] in runtime?.displayLost() }
    process.runtimeStarted(runtime)
    let code = await runtime.run()
    // After a display loss the root's handlers stay: a thread that still reaches the dead
    // connection must not fall back to Xlib's default, which exits with another code.
    if !runtime.effects.isDisplayLost { process.xlib.restoreHandlers() }
    return code
  }

  /// Connects once with an evaluator that records and refuses, so no application byte is sent,
  /// then shows the presented and the trusted fingerprint.
  private static func show(_ server: ClientServerAddress, process: ClientProcess) async
    -> ClientExitCode
  {
    let observation = ClientTrustObservation()
    let transport = process.connector(server).makeTransport { presented in
      _ = observation.evaluate(stored: nil, presented: presented)
      return .reject(.identityUnknown)
    }
    var failure: CoreErrorCode?
    do throws(CoreError) {
      try await transport.connect()
    } catch {
      failure = error.code
    }
    await transport.disconnect()
    guard let presented = observation.presented else {
      process.output.status(.connectionEnded(failure))
      return .failure
    }
    let trusted: Data?
    switch await process.trustStore.loadTrustedFingerprint(for: server.peerKey) {
    case .success(let value):
      trusted = value
    case .failure:
      process.output.status(.trustStoreUnavailable)
      return .trustDecisionNeeded
    }
    process.output.message(
      ClientTrustText.show(server: server, presented: presented, trusted: trusted))
    return .success
  }

  private static func trust(
    _ digest: Data, for server: ClientServerAddress, process: ClientProcess
  ) async -> ClientExitCode {
    switch await process.trustStore.insertTrustedFingerprintIfAbsent(digest, for: server.peerKey) {
    case .success(.inserted):
      process.output.message("trusted")
      return .success
    case .success(.existing(let stored)) where stored == digest:
      process.output.message("already trusted")
      return .success
    case .success(.existing):
      process.output.message(
        "a different fingerprint is trusted for this server; run `mackvm-client fingerprint forget` first"
      )
      return .trustDecisionNeeded
    case .failure:
      process.output.status(.trustStoreUnavailable)
      return .trustDecisionNeeded
    }
  }
}

/// Lets the display-loss handler, installed before the runtime exists, reach it.
final class ClientDisplayLossRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable () -> Void)?
  private var pending = false

  func set(_ handler: @escaping @Sendable () -> Void) {
    let fireNow = lock.withLock { () -> Bool in
      self.handler = handler
      return pending
    }
    if fireNow { handler() }
  }

  func fire() {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      pending = true
      return self.handler
    }
    handler?()
  }
}

/// Races the interactive trust prompt against a signal or a display loss.
final class ClientPromptGate: @unchecked Sendable {
  private let lock = NSLock()
  private var waiter: CheckedContinuation<String?, Never>?
  private var interrupted = false

  /// The answer, or `nil` when interrupted (or when stdin ended). The prompt's own read keeps
  /// running on its thread and is ignored.
  func ask(_ prompt: @escaping @Sendable () async -> String?) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let now = lock.withLock { () -> Bool in
        if interrupted { return true }
        waiter = continuation
        return false
      }
      if now {
        continuation.resume(returning: nil)
        return
      }
      Task {
        let answer = await prompt()
        self.resolve(answer)
      }
    }
  }

  var wasInterrupted: Bool { lock.withLock { interrupted } }

  func interrupt() {
    let waiting = lock.withLock { () -> CheckedContinuation<String?, Never>? in
      interrupted = true
      defer { waiter = nil }
      return waiter
    }
    waiting?.resume(returning: nil)
  }

  private func resolve(_ answer: String?) {
    let waiting = lock.withLock { () -> CheckedContinuation<String?, Never>? in
      defer { waiter = nil }
      return waiter
    }
    waiting?.resume(returning: answer)
  }
}

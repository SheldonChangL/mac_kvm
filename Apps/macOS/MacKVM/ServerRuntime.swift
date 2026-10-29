import BarrierCompatibility
import CoreGraphics
import Foundation
import KVMContracts
import KVMCore
import MacPlatform

/// Composes one server run: the TLS listener, the admission gate, the single
/// client session with its ordered outbox, and the coordinator.
final class ServerRuntime: @unchecked Sendable {
  static let handshakeTimeout = Duration.seconds(5)
  static let connectTimeout = Duration.seconds(5)
  static let outboxCapacity = 1024
  static let tickInterval = Duration.milliseconds(20)
  /// How long a shutdown waits for queued releases and the leave to go out.
  static let flushTimeout = Duration.milliseconds(500)

  let configuration: ServerConfiguration
  let localScreen = ScreenID()
  let clientScreen = ScreenID()
  let desktop: CGRect
  let clients = ClientSlot()
  let effects: MacServerEffects
  let coordinator: ServerCoordinator
  private let identity: MacServerIdentity
  private let listener: MacTLSServerListener
  private let gate: BarrierListenerTransport
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []
  private var stopping = false
  private var onFailure: (@Sendable (String) -> Void)?

  /// Builds the runtime; `nil` with a reported reason when the configuration
  /// or the desktop geometry is unusable.
  init?(
    configuration: ServerConfiguration, identity: MacServerIdentity, desktop: CGRect,
    suppressor: LocalEventSuppressor?, cursor: CursorRestorer?,
    inputCapturable: @escaping @Sendable () -> Bool
  ) {
    self.configuration = configuration
    self.identity = identity
    self.desktop = desktop
    effects = MacServerEffects(
      desktop: desktop, edge: configuration.edge, suppressor: suppressor, cursor: cursor,
      clients: clients)
    guard
      let edgeDetection = EdgeDetector.Configuration(
        activationDelay: .milliseconds(50), cornerDeadZone: 20),
      let coordinatorConfiguration = ServerCoordinatorConfiguration(
        localScreen: localScreen,
        localSize: EdgeDetector.ScreenSize(width: desktop.width, height: desktop.height),
        links: [ScreenLink(from: localScreen, edge: configuration.edge, to: clientScreen)],
        edgeDetection: edgeDetection, entryInset: 1, reentryInset: 2),
      let coordinator = ServerCoordinator(
        configuration: coordinatorConfiguration, effects: effects,
        canForward: BarrierServerProtocolSession.canSend, inputCapturable: inputCapturable),
      let policy = try? BarrierListenerPolicy(
        maximumConcurrentConnections: 2, connectTimeout: Self.connectTimeout)
    else {
      report("unusable configuration or desktop geometry")
      return nil
    }
    self.coordinator = coordinator
    listener = MacTLSServerListener(
      port: configuration.port, scope: configuration.scope, identity: identity)
    gate = BarrierListenerTransport(policy: policy, clock: ContinuousKVMClock())
    effects.onEnterTimeout { [weak coordinator] screen in coordinator?.enterTimedOut(screen) }
  }

  /// Called once if the server cannot go on (the listener died).
  func onFailure(_ handler: @escaping @Sendable (String) -> Void) {
    lock.withLock { onFailure = handler }
  }

  /// Starts listening and the background tasks.
  func start() async throws(CoreError) {
    try await listener.start()
    report(
      "listening" + (configuration.scope == .loopback ? " on loopback only" : "")
        + "; the client is beyond the \(configuration.edge.rawValue) edge")
    let accept = Task { [self] in
      for await transport in listener.connections {
        Task { await self.serve(transport) }
      }
      let (stopping, failure) = lock.withLock { (self.stopping, self.onFailure) }
      if !stopping { failure?("the listener stopped") }
    }
    let ticker = Task { [coordinator] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.tickInterval)
        coordinator.tick(at: uptime())
      }
    }
    tasks = [accept, ticker]
  }

  /// Returns input to local, sends what is queued for the client, then closes
  /// everything.
  func shutdown(_ trigger: InputLifecycleTrigger) async {
    lock.withLock { stopping = true }
    coordinator.dispatch(.lifecycle(trigger))
    if let outbox = clients.outbox {
      let deadline = ContinuousClock.now + Self.flushTimeout
      while outbox.count > 0, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      // The last dequeued write may still be in flight.
      try? await Task.sleep(for: .milliseconds(100))
    }
    for task in tasks { task.cancel() }
    listener.stop()
    await clients.session?.close(reason: .applicationTermination)
    await gate.stop()
  }

  // MARK: Sessions

  private func serve(_ transport: MacTLSTransport) async {
    let admission: BarrierListenerAdmission
    do {
      admission = try await gate.admit(transport)
    } catch {
      report("connection refused before the handshake: \(error)")
      return
    }
    guard
      let protocolSession = BarrierServerProtocolSession(
        transport: transport, expectedScreenNames: [configuration.clientName],
        clock: ContinuousKVMClock(), handshakeTimeout: Self.handshakeTimeout),
      let outbox = CaptureQueue(capacity: Self.outboxCapacity)
    else {
      await transport.disconnect()
      await gate.release(admission)
      return
    }
    let session = ServerSession(
      id: SessionID(), screen: clientScreen, protocolSession: protocolSession)
    do {
      try await session.start()
    } catch {
      report("client handshake failed: \(error.code)")
      await gate.release(admission)
      return
    }
    guard let size = protocolSession.clientScreen,
      clients.claim(screen: clientScreen, session: session, outbox: outbox)
    else {
      report("a client is already connected; refusing another")
      await session.close(reason: .userRequested)
      await gate.release(admission)
      return
    }
    let sender = Task { await self.send(outbox, through: session) }
    guard coordinator.clientReady(clientScreen, width: size.width, height: size.height) else {
      report("the client reported an unusable screen size; disconnecting")
      await session.close(reason: .userRequested)
      outbox.close()
      clients.release(clientScreen)
      await sender.value
      await gate.release(admission)
      return
    }
    report("client ready (\(size.width)x\(size.height))")

    let reason = await session.monitorPeer()
    outbox.close()
    clients.release(clientScreen)
    coordinator.clientGone(clientScreen)
    await sender.value
    await gate.release(admission)
    report("client disconnected: \(Self.describe(reason))")
  }

  /// Writes the outbox to the session in order and reports the outcomes.
  private func send(_ outbox: CaptureQueue, through session: ServerSession) async {
    while true {
      let next: KVMEvent?
      do {
        next = try await outbox.next()
      } catch {
        // Overflow: the coordinator has already failed open and the producer
        // resets the queue before it queues the releases and the leave.
        await Task.yield()
        continue
      }
      guard let event = next else { return }
      switch event {
      case .enterScreen(_, let position):
        do {
          try await session.enter(at: position)
          coordinator.enterCompleted(clientScreen, success: true)
        } catch {
          coordinator.enterCompleted(clientScreen, success: false)
        }
      case .leaveScreen:
        try? await session.leave()
        coordinator.leaveCompleted(clientScreen)
      default:
        do {
          try await session.forward(event)
        } catch {
          coordinator.deliveryFailed(clientScreen)
        }
      }
    }
  }

  private static func describe(_ reason: DisconnectReason) -> String {
    switch reason {
    case .userRequested: "closed by the server"
    case .transportClosed: "connection closed"
    case .cancellation(let why): "cancelled (\(why))"
    case .failure(let error): "failed (\(error.code))"
    case .applicationTermination: "server quitting"
    }
  }
}

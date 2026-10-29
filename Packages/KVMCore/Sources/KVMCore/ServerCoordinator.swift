// The single owner of the M2 server's input state (composition root, M2-035).
// It runs the M2-008 reducer and executes its effects in order, composing the
// M2-010 enter trigger, the M2-019 remote pointer tracker and the M2-020 return
// flow. Every state change happens under one lock, so the tap callback, the
// session tasks and the timers can all report to it. It never awaits: network
// effects are handed to `ServerCoordinatorEffects.deliver`, which only queues.
//
// Remote pointer motion arrives as relative deltas because the local cursor is
// parked while remote (M2-019 expects a re-anchored cursor). Key and button
// state is tracked twice: what the remote holds, so a leave can release it, and
// what passed to the local system, so its release goes back there as well.

import Foundation
import KVMContracts

/// The platform and network effects the coordinator drives.
///
/// Calls happen while the coordinator holds its lock, in reducer order. An
/// implementation must return promptly, must not wait for the network and
/// must never call back into the coordinator synchronously.
package protocol ServerCoordinatorEffects: Sendable {
  /// Remembers where the local cursor is before input switches away.
  func saveLocalCursor()
  /// Starts swallowing forwardable local input and parks the local cursor.
  func enableSuppression()
  /// Stops swallowing local input. Idempotent.
  func disableSuppression()
  /// Puts the local cursor at a normalized position on the local desktop.
  func restoreLocalCursor(at position: NormalizedPoint)
  /// Runs the fail-safe local recovery. `cursorWasParked` says whether the
  /// cursor was parked for remote input and must be restored.
  func recoverLocal(cursorWasParked: Bool)
  /// Queues `event` for in-order delivery to `screen`'s session. Returns
  /// `false` when it cannot be queued; the coordinator then fails open.
  func deliver(_ event: KVMEvent, to screen: ScreenID) -> Bool
  func startEnterTimeout(for screen: ScreenID)
  func cancelEnterTimeout(for screen: ScreenID)
}

/// Fixed geometry and policy for one server run.
package struct ServerCoordinatorConfiguration: Sendable {
  package let localScreen: ScreenID
  /// The local desktop in logical points, origin top-left.
  package let localSize: EdgeDetector.ScreenSize
  package let links: [ScreenLink]
  package let edgeDetection: EdgeDetector.Configuration
  /// Remote pixels inside the arrival edge where an enter places the pointer.
  package let entryInset: Int
  /// Local points inside the return edge where a leave places the cursor.
  package let reentryInset: Double

  fileprivate let router: ScreenRouter
  fileprivate let leaveFlow: LeaveRemoteFlow

  /// Returns `nil` when the links do not form a valid topology around
  /// `localScreen` or the return geometry does not fit the local size.
  package init?(
    localScreen: ScreenID, localSize: EdgeDetector.ScreenSize, links: [ScreenLink],
    edgeDetection: EdgeDetector.Configuration, entryInset: Int, reentryInset: Double
  ) {
    var screens = [localScreen]
    for link in links {
      for screen in [link.from, link.to] where !screens.contains(screen) {
        screens.append(screen)
      }
    }
    guard let topology = try? ScreenTopology(screens: screens, links: links),
      let router = ScreenRouter(localScreen: localScreen, topology: topology),
      let returnMapper = ReturnCoordinateMapper(
        localSize: ReturnCoordinateMapper.LogicalSize(
          width: localSize.width, height: localSize.height),
        reentryInset: reentryInset, cornerDeadZone: edgeDetection.cornerDeadZone),
      entryInset >= 0
    else { return nil }
    self.localScreen = localScreen
    self.localSize = localSize
    self.links = links
    self.edgeDetection = edgeDetection
    self.entryInset = entryInset
    self.reentryInset = reentryInset
    self.router = router
    self.leaveFlow = LeaveRemoteFlow(returnMapper: returnMapper)
  }
}

/// Where a swallowed event goes after the coordinator has seen it.
package enum SuppressedInputDisposition: Equatable, Sendable {
  /// Stay swallowed: it was forwarded to the remote, or deliberately dropped.
  case swallow
  /// Give it back to the local system: input is local again, or its down
  /// went to the local system.
  case passLocally
}

/// Owns the input state of the server role. State lives behind one `NSLock`,
/// hence `@unchecked Sendable`.
package final class ServerCoordinator: @unchecked Sendable {
  private struct State {
    var input = InputState.local
    /// Ready clients and their geometry.
    var mappers: [ScreenID: OutboundCoordinateMapper] = [:]
    var trigger: EnterRemoteTrigger
    /// The activated edge and entry point, from the enter request to commit.
    var pendingEnter: EnterIntent?
    /// The remote pointer and the local edge it left through, while remote.
    var tracker: RemotePointerTracker?
    var leftThrough: ScreenEdge?
    var cursorParked = false
    /// Whether local input can be captured at all (no secure input active).
    var capturable = true
    /// Set by a forced return to local; the edge stays inert until the
    /// pointer has moved `rearmDistance` away from every linked edge.
    var edgeDisarmed = false
    /// Keys and buttons physically held, as far as observed.
    var heldKeys: [VirtualKey] = []
    var heldButtons: [MouseButton] = []
    /// Keys and buttons whose down went to the local system.
    var localKeys: [VirtualKey] = []
    var localButtons: [MouseButton] = []
    /// Keys (with their modifiers at press) and buttons the remote holds.
    var remoteKeys: [(VirtualKey, ModifierState)] = []
    var remoteButtons: [MouseButton] = []
  }

  /// Local points the pointer must move away from the linked edges before a
  /// forced return to local lets the edge activate again.
  package static let rearmDistance: Double = 50
  /// Upper bound on one relative motion, in local points per axis.
  static let maximumMotion: Double = 10_000

  private let configuration: ServerCoordinatorConfiguration
  private let effects: any ServerCoordinatorEffects
  private let canForward: @Sendable (KVMEvent) -> Bool
  private let inputCapturable: @Sendable () -> Bool
  private let lock = NSLock()
  private var current: State

  /// `canForward` says whether the remote can receive an input event; other
  /// input is swallowed while remote and never delivered. `inputCapturable`
  /// says whether local input can be captured at all; it is false while the
  /// system routes keys past every event tap (secure input), and is checked
  /// on each tick without the lock held.
  package init?(
    configuration: ServerCoordinatorConfiguration, effects: any ServerCoordinatorEffects,
    canForward: @escaping @Sendable (KVMEvent) -> Bool,
    inputCapturable: @escaping @Sendable () -> Bool = { true }
  ) {
    guard
      let trigger = EnterRemoteTrigger(
        router: configuration.router, configuration: configuration.edgeDetection,
        localSize: configuration.localSize, remoteMappers: [:])
    else { return nil }
    self.configuration = configuration
    self.effects = effects
    self.canForward = canForward
    self.inputCapturable = inputCapturable
    current = State(trigger: trigger)
    current.capturable = inputCapturable()
  }

  /// The current input state.
  package var state: InputState {
    lock.withLock { current.input }
  }

  // MARK: Local input

  /// Records an event that went to the local system and, while local, runs
  /// edge detection on pointer samples. `timestamp` is monotonic.
  package func observeLocal(_ event: KVMEvent, at timestamp: Duration) {
    lock.withLock {
      notePhysical(event)
      noteLocal(event)
      guard case .mouseMove(let position) = event, current.input == .local else { return }
      let x = position.x * (configuration.localSize.width - 1)
      let y = position.y * (configuration.localSize.height - 1)
      if current.edgeDisarmed {
        guard distanceToLinkedEdges(x: x, y: y) >= Self.rearmDistance else { return }
        current.edgeDisarmed = false
      }
      let intent = current.trigger.pointer(
        x: x, y: y, at: timestamp, state: current.input, available: Set(current.mappers.keys))
      if let intent { requestEnter(intent) }
    }
  }

  /// Completes an edge dwell when the pointer rests on the edge, and returns
  /// input to local when it can no longer be captured.
  package func tick(at timestamp: Duration) {
    let capturable = inputCapturable()
    lock.withLock {
      current.capturable = capturable
      if !capturable, current.input != .local {
        apply(.captureFailure)
        return
      }
      guard current.input == .local, !current.edgeDisarmed,
        let intent = current.trigger.tick(
          at: timestamp, state: current.input, available: Set(current.mappers.keys))
      else { return }
      requestEnter(intent)
    }
  }

  // MARK: Remote input

  /// Routes a swallowed key, button or scroll event.
  package func handleSuppressed(_ event: KVMEvent) -> SuppressedInputDisposition {
    lock.withLock {
      notePhysical(event)
      if returnsToLocal(event) { return .passLocally }
      guard case .remote(let target) = current.input else { return .passLocally }
      switch event {
      case .key, .mouseButton, .scroll:
        guard canForward(event) else { return .swallow }
        noteRemote(event)
        if !effects.deliver(event, to: target) { apply(.captureFailure) }
        return .swallow
      default:
        return .swallow
      }
    }
  }

  /// Applies relative pointer motion in local points while remote. Returns
  /// `false` when input is not remote, so the motion belongs to the local
  /// system.
  package func moveRemote(deltaX: Double, deltaY: Double) -> Bool {
    lock.withLock {
      guard case .remote(let target) = current.input, var tracker = current.tracker,
        let mapper = current.mappers[target], deltaX.isFinite, deltaY.isFinite
      else { return false }
      let limit = Self.maximumMotion
      let motion = Self.apply(
        deltaX: min(max(deltaX, -limit), limit), deltaY: min(max(deltaY, -limit), limit),
        to: &tracker, localSize: configuration.localSize)
      current.tracker = tracker
      switch motion {
      case .returned where holdsRemoteInput:
        // Held input locks the pointer to the client, as a drag or a held
        // key must not end on this Mac (its repeats would reach local apps).
        if !effects.deliver(.mouseMove(position: mapper.normalized(tracker.position)), to: target) {
          apply(.captureFailure)
        }
      case .moved(let point):
        if !effects.deliver(.mouseMove(position: mapper.normalized(point)), to: target) {
          apply(.captureFailure)
        }
      case .returned:
        if let edge = current.leftThrough,
          let intent = configuration.leaveFlow.intent(
            for: motion, target: target, leftThrough: edge)
        {
          apply(intent.action)
        }
      }
      return true
    }
  }

  // MARK: Sessions and outcomes

  /// A client finished its handshake and reported its screen size. Returns
  /// `false`, and the client stays unreachable, when the size is unusable.
  @discardableResult
  package func clientReady(_ screen: ScreenID, width: Int, height: Int) -> Bool {
    lock.withLock {
      guard
        let mapper = OutboundCoordinateMapper(
          remoteSize: OutboundCoordinateMapper.LogicalSize(
            width: Double(width), height: Double(height)),
          entryInset: configuration.entryInset)
      else { return false }
      current.mappers[screen] = mapper
      rebuildTrigger()
      return true
    }
  }

  /// A client's session ended.
  package func clientGone(_ screen: ScreenID) {
    lock.withLock {
      current.mappers[screen] = nil
      rebuildTrigger()
      apply(.sessionLost(screen))
    }
  }

  /// The queued enter was written (or failed).
  package func enterCompleted(_ screen: ScreenID, success: Bool) {
    lock.withLock { apply(success ? .enterDelivered(screen) : .enterFailed(screen)) }
  }

  package func enterTimedOut(_ screen: ScreenID) {
    lock.withLock { apply(.enterTimeout(screen)) }
  }

  /// The queued leave was written or abandoned.
  package func leaveCompleted(_ screen: ScreenID) {
    lock.withLock { apply(.leaveCompleted(screen)) }
  }

  /// A queued delivery to `screen` failed; its session is gone.
  package func deliveryFailed(_ screen: ScreenID) {
    lock.withLock { apply(.sessionLost(screen)) }
  }

  /// Applies a forced-local action (escape, capture failure, lifecycle).
  package func dispatch(_ action: InputAction) {
    lock.withLock { apply(action) }
  }

  // MARK: Reducer and effects (lock held)

  private func requestEnter(_ intent: EnterIntent) {
    guard current.capturable else { return }
    current.pendingEnter = intent
    apply(intent.action)
  }

  /// Reduces `action` and runs its effects; effects that fail queue
  /// follow-up actions, which are reduced in turn.
  private func apply(_ action: InputAction) {
    var queue = [action]
    while !queue.isEmpty {
      let previous = current.input
      let transition = InputStateReducer.reduce(previous, queue.removeFirst())
      current.input = transition.state
      for effect in transition.effects {
        execute(effect, followUps: &queue)
      }
      if previous != .local, transition.state == .local,
        transition.effects.contains(.restoreLocal)
      {
        current.edgeDisarmed = true
      }
      if current.input == .local {
        current.pendingEnter = nil
        current.tracker = nil
        current.leftThrough = nil
        current.remoteKeys = []
        current.remoteButtons = []
        current.cursorParked = false
      }
    }
  }

  private func execute(_ effect: InputEffect, followUps: inout [InputAction]) {
    switch effect {
    case .saveLocalCursor:
      effects.saveLocalCursor()
    case .sendEnter(let target, let position):
      if !effects.deliver(.enterScreen(screen: target, position: position), to: target) {
        followUps.append(.enterFailed(target))
      }
    case .startEnterTimeout(let target):
      effects.startEnterTimeout(for: target)
    case .cancelEnterTimeout(let target):
      effects.cancelEnterTimeout(for: target)
    case .enableSuppression:
      guard case .remote(let target) = current.input, let intent = current.pendingEnter,
        let mapper = current.mappers[target]
      else {
        if case .remote(let target) = current.input { followUps.append(.sessionLost(target)) }
        return
      }
      current.tracker = mapper.tracker(entering: intent.edge, at: intent.entryPoint)
      current.leftThrough = intent.edge
      current.pendingEnter = nil
      current.cursorParked = true
      effects.enableSuppression()
    case .disableSuppression:
      effects.disableSuppression()
    case .releaseRemoteInput(let target, let delivery):
      let releases =
        current.remoteKeys.reversed().map { KVMEvent.key(key: $0.0, phase: .up, modifiers: $0.1) }
        + current.remoteButtons.reversed().map { KVMEvent.mouseButton(button: $0, phase: .up) }
      current.remoteKeys = []
      current.remoteButtons = []
      for release in releases where !effects.deliver(release, to: target) {
        if delivery == .required { followUps.append(.sessionLost(target)) }
        break
      }
    case .sendLeave(let target, _):
      if !effects.deliver(.leaveScreen(screen: target), to: target),
        current.input == .leavingRemote(target)
      {
        followUps.append(.leaveCompleted(target))
      }
    case .restoreLocalCursor(let position):
      effects.restoreLocalCursor(at: position)
      current.cursorParked = false
    case .restoreLocal:
      effects.recoverLocal(cursorWasParked: current.cursorParked)
      current.cursorParked = false
    }
  }

  // MARK: Bookkeeping (lock held)

  /// Whether the remote holds a button or a non-modifier key.
  private var holdsRemoteInput: Bool {
    let modifiers: [VirtualKey] = [.shift, .control, .option, .command]
    return !current.remoteButtons.isEmpty
      || current.remoteKeys.contains { !modifiers.contains($0.0) }
  }

  /// The smallest distance, in local points, from `(x, y)` to a linked edge.
  private func distanceToLinkedEdges(x: Double, y: Double) -> Double {
    let maxX = configuration.localSize.width - 1
    let maxY = configuration.localSize.height - 1
    let distances = configuration.links.compactMap { link -> Double? in
      guard link.from == configuration.localScreen else { return nil }
      switch link.edge {
      case .left: return x
      case .right: return maxX - x
      case .top: return y
      case .bottom: return maxY - y
      }
    }
    return distances.min() ?? .infinity
  }

  private func rebuildTrigger() {
    guard
      var trigger = EnterRemoteTrigger(
        router: configuration.router, configuration: configuration.edgeDetection,
        localSize: configuration.localSize, remoteMappers: current.mappers)
    else { return }
    for key in current.heldKeys {
      trigger.observe(.key(key: key, phase: .down, modifiers: ModifierState()))
    }
    for button in current.heldButtons {
      trigger.observe(.mouseButton(button: button, phase: .down))
    }
    current.trigger = trigger
  }

  /// Physical key and button state, which gates the enter trigger. Caps Lock
  /// reports its toggle state, not a held key, so it never gates.
  private func notePhysical(_ event: KVMEvent) {
    switch event {
    case .key(.capsLock, _, _):
      return
    case .key(let key, .down, _):
      if !current.heldKeys.contains(key) { current.heldKeys.append(key) }
    case .key(let key, .up, _):
      current.heldKeys.removeAll { $0 == key }
    case .mouseButton(let button, .down):
      if !current.heldButtons.contains(button) { current.heldButtons.append(button) }
    case .mouseButton(let button, .up):
      current.heldButtons.removeAll { $0 == button }
    default:
      return
    }
    current.trigger.observe(event)
  }

  private func noteLocal(_ event: KVMEvent) {
    switch event {
    case .key(.capsLock, _, _):
      break
    case .key(let key, .down, _):
      if !current.localKeys.contains(key) { current.localKeys.append(key) }
    case .key(let key, .up, _):
      current.localKeys.removeAll { $0 == key }
    case .mouseButton(let button, .down):
      if !current.localButtons.contains(button) { current.localButtons.append(button) }
    case .mouseButton(let button, .up):
      current.localButtons.removeAll { $0 == button }
    default:
      break
    }
  }

  private func noteRemote(_ event: KVMEvent) {
    switch event {
    case .key(.capsLock, _, _):
      break
    case .key(let key, .down, let modifiers):
      if !current.remoteKeys.contains(where: { $0.0 == key }) {
        current.remoteKeys.append((key, modifiers))
      }
    case .key(let key, .up, _):
      current.remoteKeys.removeAll { $0.0 == key }
    case .mouseButton(let button, .down):
      if !current.remoteButtons.contains(button) { current.remoteButtons.append(button) }
    case .mouseButton(let button, .up):
      current.remoteButtons.removeAll { $0 == button }
    default:
      break
    }
  }

  /// Whether a repeat or release belongs to a down the local system saw.
  private func returnsToLocal(_ event: KVMEvent) -> Bool {
    switch event {
    case .key(let key, .repeatKey, _):
      return current.localKeys.contains(key)
    case .key(let key, .up, _):
      guard current.localKeys.contains(key) else { return false }
      current.localKeys.removeAll { $0 == key }
      return true
    case .mouseButton(let button, .up):
      guard current.localButtons.contains(button) else { return false }
      current.localButtons.removeAll { $0 == button }
      return true
    default:
      return false
    }
  }

  /// Feeds a relative motion to the tracker in steps no larger than half the
  /// local size, because the tracker takes normalized positions around an
  /// anchor. Stops at the first step that returns.
  private static func apply(
    deltaX: Double, deltaY: Double, to tracker: inout RemotePointerTracker,
    localSize: EdgeDetector.ScreenSize
  ) -> RemotePointerTracker.Motion {
    let spanX = localSize.width - 1
    let spanY = localSize.height - 1
    let limitX = max(spanX / 2 - 1, 1)
    let limitY = max(spanY / 2 - 1, 1)
    let steps = max(1, Int((max(abs(deltaX) / limitX, abs(deltaY) / limitY)).rounded(.up)))
    let anchor = NormalizedPoint(x: 0.5, y: 0.5)
    let size = OutboundCoordinateMapper.LogicalSize(
      width: localSize.width, height: localSize.height)
    var motion = RemotePointerTracker.Motion.moved(tracker.position)
    for _ in 0..<steps {
      let position = NormalizedPoint(
        x: 0.5 + deltaX / Double(steps) / spanX, y: 0.5 + deltaY / Double(steps) / spanY)
      motion = tracker.apply(localPosition: position, anchor: anchor, localSize: size)
      if case .returned = motion { break }
    }
    return motion
  }
}

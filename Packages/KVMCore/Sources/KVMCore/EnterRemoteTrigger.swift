import KVMContracts

/// A deduplicated request to switch input to a remote screen.
package struct EnterIntent: Equatable, Sendable {
  /// The reducer action to dispatch: `edgeActivated(target:entry:)`.
  package let action: InputAction
  /// The local edge that was activated.
  package let edge: ScreenEdge
  /// The remote entry point, for starting the M2-019 tracker.
  package let entryPoint: OutboundCoordinateMapper.RemotePoint
}

/// Turns local pointer samples into enter intents (M2-010).
///
/// Composes the M2-017 `EdgeDetector`, the M2-031 `ScreenRouter` and one
/// M2-019 `OutboundCoordinateMapper` per remote screen. An intent is emitted
/// only in the `local` state with no local key or button held (M2-008
/// activation precondition), only once per edge dwell, only for a linked edge
/// whose neighbor has a ready session and known geometry. Any other state
/// resets the dwell, so a trigger never repeats while a switch is in flight.
/// The trigger is a pure value with no clock, network or platform dependency.
package struct EnterRemoteTrigger: Sendable {
  private let router: ScreenRouter
  private let remoteMappers: [ScreenID: OutboundCoordinateMapper]
  private var detector: EdgeDetector
  private var heldButtons: [MouseButton] = []
  private var heldKeys: [VirtualKey] = []

  /// Returns `nil` for a local size smaller than 2×2 points or non-finite.
  package init?(
    router: ScreenRouter, configuration: EdgeDetector.Configuration,
    localSize: EdgeDetector.ScreenSize, remoteMappers: [ScreenID: OutboundCoordinateMapper]
  ) {
    guard localSize.width.isFinite, localSize.height.isFinite, localSize.width >= 2,
      localSize.height >= 2
    else { return nil }
    self.router = router
    self.remoteMappers = remoteMappers
    self.detector = EdgeDetector(
      configuration: configuration, screenSize: localSize, linkedEdges: router.linkedEdges)
  }

  /// Records local key and button state from captured events.
  ///
  /// The owner calls this for every event captured while input is local.
  /// Releases without a matching press are ignored.
  package mutating func observe(_ event: KVMEvent) {
    switch event {
    case .mouseButton(let button, .down):
      if !heldButtons.contains(button) { heldButtons.append(button) }
    case .mouseButton(let button, .up):
      heldButtons.removeAll { $0 == button }
    case .key(let key, .down, _):
      if !heldKeys.contains(key) { heldKeys.append(key) }
    case .key(let key, .up, _):
      heldKeys.removeAll { $0 == key }
    default:
      break
    }
  }

  /// Processes one local pointer sample in local logical points.
  package mutating func pointer(
    x: Double, y: Double, at timestamp: Duration, state: InputState, available: Set<ScreenID>
  ) -> EnterIntent? {
    guard state == .local, heldButtons.isEmpty, heldKeys.isEmpty else {
      detector.reset()
      return nil
    }
    return intent(for: detector.update(x: x, y: y, at: timestamp), available: available)
  }

  /// Evaluates a pending dwell without a new sample.
  package mutating func tick(at timestamp: Duration, state: InputState, available: Set<ScreenID>)
    -> EnterIntent?
  {
    guard state == .local, heldButtons.isEmpty, heldKeys.isEmpty else {
      detector.reset()
      return nil
    }
    return intent(for: detector.tick(at: timestamp), available: available)
  }

  private func intent(for signal: EdgeDetector.Signal, available: Set<ScreenID>) -> EnterIntent? {
    guard case .activated(let edge, let offset) = signal,
      case .target(let target) = router.target(across: edge, available: available),
      let mapper = remoteMappers[target]
    else { return nil }
    let entryPoint = mapper.entryPoint(leaving: edge, offset: offset)
    return EnterIntent(
      action: .edgeActivated(target: target, entry: mapper.normalized(entryPoint)), edge: edge,
      entryPoint: entryPoint)
  }
}

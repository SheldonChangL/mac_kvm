import KVMContracts

/// A request to leave the remote screen through its return edge.
package struct LeaveIntent: Equatable, Sendable {
  /// The reducer action: `returnEdge(target:localPosition:)`.
  package let action: InputAction
  /// The local re-entry point for the M2-021 cursor restorer.
  package let localPoint: ReturnCoordinateMapper.LocalPoint
}

/// Remote → LeavingRemote → Local triggers (M2-012).
///
/// Three triggers leave a remote screen: the return edge (from the M2-019
/// tracker), the emergency escape (M2-014) and session end. Each maps to one
/// reducer action; the M2-008 table makes the leave local-first (suppression
/// off before any send) and makes repeated or stale leaves no-ops.
package struct LeaveRemoteFlow: Equatable, Sendable {
  package let returnMapper: ReturnCoordinateMapper

  package init(returnMapper: ReturnCoordinateMapper) {
    self.returnMapper = returnMapper
  }

  /// The leave intent for a tracker motion, or `nil` unless it returned.
  /// `edge` is the local edge the pointer originally left through.
  package func intent(
    for motion: RemotePointerTracker.Motion, target: ScreenID, leftThrough edge: ScreenEdge
  ) -> LeaveIntent? {
    guard case .returned(let offset) = motion else { return nil }
    let point = returnMapper.reentryPoint(leftThrough: edge, offset: offset)
    return LeaveIntent(
      action: .returnEdge(target: target, localPosition: returnMapper.normalized(point)),
      localPoint: point)
  }

  /// The escape trigger; never waits for the remote side.
  package static let escapeAction = InputAction.emergencyEscape

  /// The trigger for a lost or closed session.
  package static func sessionEndAction(for target: ScreenID) -> InputAction {
    .sessionLost(target)
  }
}

import KVMContracts

/// Where captured input goes for the current input state.
package enum RouteDecision: Equatable, Sendable {
  /// Input stays on the Mac.
  case local
  /// Input is routed to this committed remote screen.
  case remote(ScreenID)
  /// The committed target is invalid or has no session; nothing may be sent
  /// and the owner must apply `recoveryAction`.
  case rollback(ScreenID)

  /// The reducer action that recovers from a rollback.
  package var recoveryAction: InputAction? {
    if case .rollback(let screen) = self { return .sessionLost(screen) }
    return nil
  }
}

/// Result of resolving an activated local edge.
package enum EdgeTarget: Equatable, Sendable {
  case target(ScreenID)
  case unlinked
  case unavailable
}

/// Pure target selection from topology and input state (M2-031, C-013).
///
/// The MVP routes only between the local Mac screen and its direct
/// neighbors. The router never sends; it returns decisions that the owner
/// executes, and an invalid target becomes a rollback decision.
package struct ScreenRouter: Equatable, Sendable {
  package let localScreen: ScreenID
  package let topology: ScreenTopology

  /// Returns `nil` when `localScreen` is not in `topology`.
  package init?(localScreen: ScreenID, topology: ScreenTopology) {
    guard topology.screens.contains(localScreen) else { return nil }
    self.localScreen = localScreen
    self.topology = topology
  }

  /// Local edges that have a linked neighbor, for the M2-017 detector.
  package var linkedEdges: Set<ScreenEdge> {
    Set(ScreenEdge.allCases.filter { topology.neighbor(of: localScreen, across: $0) != nil })
  }

  /// Resolves an activated local edge against the screens that currently
  /// have a ready session.
  package func target(across edge: ScreenEdge, available: Set<ScreenID>) -> EdgeTarget {
    guard let neighbor = topology.neighbor(of: localScreen, across: edge) else { return .unlinked }
    return available.contains(neighbor) ? .target(neighbor) : .unavailable
  }

  /// Routes captured input for `state`. Only committed `remote` routes
  /// remotely, and only to a direct neighbor that still has a session.
  package func route(_ state: InputState, available: Set<ScreenID>) -> RouteDecision {
    guard case .remote(let screen) = state else { return .local }
    let adjacent = linkedEdges.contains {
      topology.neighbor(of: localScreen, across: $0) == screen
    }
    return adjacent && available.contains(screen) ? .remote(screen) : .rollback(screen)
  }
}

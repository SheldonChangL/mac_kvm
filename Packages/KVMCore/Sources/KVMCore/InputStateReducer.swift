import KVMContracts

/// The four explicit server input states frozen by M2-008.
///
/// There is no separate remote flag: whether local input is suppressed is
/// derived from the state and is true only for the committed `remote` state.
package enum InputState: Equatable, Sendable {
  case local
  case enteringRemote(ScreenID)
  case remote(ScreenID)
  case leavingRemote(ScreenID)

  /// True only for committed `remote`; M2-001 forbids suppression elsewhere.
  package var suppressesLocalInput: Bool {
    if case .remote = self { return true }
    return false
  }
}

/// Process lifecycle triggers that force the input state back to local.
package enum InputLifecycleTrigger: Equatable, Sendable {
  case sleep
  case termination
}

/// Inputs to the reducer. Target-bearing actions for a different target than
/// the current one are stale and ignored.
package enum InputAction: Equatable, Sendable {
  case edgeActivated(target: ScreenID, entry: NormalizedPoint)
  case enterDelivered(ScreenID)
  case enterFailed(ScreenID)
  case enterTimeout(ScreenID)
  case returnEdge(target: ScreenID, localPosition: NormalizedPoint)
  case leaveCompleted(ScreenID)
  case sessionLost(ScreenID)
  case emergencyEscape
  case captureFailure
  case lifecycle(InputLifecycleTrigger)
}

/// Whether a failing effect may fail the surrounding operation.
///
/// `bestEffort` effects run during recovery; their failure must not block or
/// undo the transition that emitted them.
package enum InputEffectDelivery: Equatable, Sendable {
  case required
  case bestEffort
}

/// Side effects requested by a transition, in execution order.
///
/// The reducer performs none of them. `restoreLocal` is the C-011 composite:
/// stop suppression, release locally held keys and buttons, and restore the
/// local cursor; executors must make it idempotent.
package enum InputEffect: Equatable, Sendable {
  case saveLocalCursor
  case sendEnter(target: ScreenID, entry: NormalizedPoint)
  case startEnterTimeout(ScreenID)
  case cancelEnterTimeout(ScreenID)
  case enableSuppression
  case disableSuppression
  case releaseRemoteInput(ScreenID, InputEffectDelivery)
  case sendLeave(ScreenID, InputEffectDelivery)
  case restoreLocalCursor(NormalizedPoint)
  case restoreLocal
}

/// The next state plus the ordered effects of one transition.
package struct InputTransition: Equatable, Sendable {
  package let state: InputState
  package let effects: [InputEffect]

  package init(state: InputState, effects: [InputEffect]) {
    self.state = state
    self.effects = effects
  }
}

/// Pure implementation of the M2-008 transition table (C-012).
///
/// The reducer has no clock, network, UI or platform dependency. It is total:
/// every state and action pair yields a defined transition.
package enum InputStateReducer {
  package static func reduce(_ state: InputState, _ action: InputAction) -> InputTransition {
    switch state {
    case .local:
      return reduceLocal(action)
    case .enteringRemote(let target):
      return reduceEntering(target, action)
    case .remote(let target):
      return reduceRemote(target, action)
    case .leavingRemote(let target):
      return reduceLeaving(target, action)
    }
  }

  private static func isForcedLocal(_ action: InputAction) -> Bool {
    switch action {
    case .emergencyEscape, .captureFailure, .lifecycle:
      return true
    default:
      return false
    }
  }

  private static func reduceLocal(_ action: InputAction) -> InputTransition {
    if case .edgeActivated(let target, let entry) = action {
      return InputTransition(
        state: .enteringRemote(target),
        effects: [
          .saveLocalCursor, .sendEnter(target: target, entry: entry), .startEnterTimeout(target),
        ]
      )
    }
    if isForcedLocal(action) {
      return InputTransition(state: .local, effects: [.restoreLocal])
    }
    return InputTransition(state: .local, effects: [])
  }

  private static func reduceEntering(_ target: ScreenID, _ action: InputAction) -> InputTransition {
    let unchanged = InputTransition(state: .enteringRemote(target), effects: [])
    let rollback = InputTransition(
      state: .local,
      effects: [.cancelEnterTimeout(target), .sendLeave(target, .bestEffort), .restoreLocal]
    )
    if isForcedLocal(action) {
      return rollback
    }
    switch action {
    case .enterDelivered(let id) where id == target:
      return InputTransition(
        state: .remote(target), effects: [.cancelEnterTimeout(target), .enableSuppression])
    case .enterFailed(let id) where id == target, .enterTimeout(let id) where id == target:
      return rollback
    case .sessionLost(let id) where id == target:
      return InputTransition(state: .local, effects: [.cancelEnterTimeout(target), .restoreLocal])
    default:
      return unchanged
    }
  }

  private static func reduceRemote(_ target: ScreenID, _ action: InputAction) -> InputTransition {
    if isForcedLocal(action) {
      return InputTransition(
        state: .local,
        effects: [
          .disableSuppression, .releaseRemoteInput(target, .bestEffort),
          .sendLeave(target, .bestEffort), .restoreLocal,
        ]
      )
    }
    switch action {
    case .returnEdge(let id, let position) where id == target:
      return InputTransition(
        state: .leavingRemote(target),
        effects: [
          .disableSuppression, .releaseRemoteInput(target, .required),
          .sendLeave(target, .required), .restoreLocalCursor(position),
        ]
      )
    case .sessionLost(let id) where id == target:
      return InputTransition(state: .local, effects: [.disableSuppression, .restoreLocal])
    default:
      return InputTransition(state: .remote(target), effects: [])
    }
  }

  private static func reduceLeaving(_ target: ScreenID, _ action: InputAction) -> InputTransition {
    if isForcedLocal(action) {
      return InputTransition(state: .local, effects: [.restoreLocal])
    }
    switch action {
    case .leaveCompleted(let id) where id == target:
      return InputTransition(state: .local, effects: [])
    case .sessionLost(let id) where id == target:
      return InputTransition(state: .local, effects: [.restoreLocal])
    default:
      return InputTransition(state: .leavingRemote(target), effects: [])
    }
  }
}

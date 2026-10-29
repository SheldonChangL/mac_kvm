import Foundation
import KVMContracts
import KVMCore
import Testing

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09, value))
}

private let target = ScreenID(rawValue: fixedUUID(1))
private let other = ScreenID(rawValue: fixedUUID(2))
private let entry = NormalizedPoint(x: 0, y: 0.25)
private let back = NormalizedPoint(x: 1, y: 0.75)

private let allStates: [InputState] = [
  .local, .enteringRemote(target), .remote(target), .leavingRemote(target),
]

private let allActions: [InputAction] = [
  .edgeActivated(target: target, entry: entry),
  .edgeActivated(target: other, entry: entry),
  .enterDelivered(target), .enterDelivered(other),
  .enterFailed(target), .enterFailed(other),
  .enterTimeout(target), .enterTimeout(other),
  .returnEdge(target: target, localPosition: back),
  .returnEdge(target: other, localPosition: back),
  .leaveCompleted(target), .leaveCompleted(other),
  .sessionLost(target), .sessionLost(other),
  .emergencyEscape, .captureFailure,
  .lifecycle(.sleep), .lifecycle(.termination),
]

private let forcedLocalActions: [InputAction] = [
  .emergencyEscape, .captureFailure, .lifecycle(.sleep), .lifecycle(.termination),
]

private func reduce(_ state: InputState, _ action: InputAction) -> InputTransition {
  InputStateReducer.reduce(state, action)
}

@Suite("M2-009 InputStateReducer")
struct InputStateReducerTests {
  @Test("happy path: edge enters, delivery commits, return edge leaves")
  func happyPath() {
    let entering = reduce(.local, .edgeActivated(target: target, entry: entry))
    #expect(entering.state == .enteringRemote(target))
    #expect(
      entering.effects == [
        .saveLocalCursor, .sendEnter(target: target, entry: entry),
        .startEnterTimeout(target),
      ])

    let committed = reduce(entering.state, .enterDelivered(target))
    #expect(committed.state == .remote(target))
    #expect(committed.effects == [.cancelEnterTimeout(target), .enableSuppression])

    let leaving = reduce(committed.state, .returnEdge(target: target, localPosition: back))
    #expect(leaving.state == .leavingRemote(target))
    #expect(
      leaving.effects == [
        .disableSuppression, .releaseRemoteInput(target, .required),
        .sendLeave(target, .required), .restoreLocalCursor(back),
      ])

    let done = reduce(leaving.state, .leaveCompleted(target))
    #expect(done.state == .local)
    #expect(done.effects.isEmpty)
  }

  @Test("rollback: enter failure and timeout return to local and cancel the timer")
  func rollback() {
    for action in [InputAction.enterFailed(target), .enterTimeout(target)] {
      let result = reduce(.enteringRemote(target), action)
      #expect(result.state == .local)
      #expect(
        result.effects == [
          .cancelEnterTimeout(target), .sendLeave(target, .bestEffort), .restoreLocal,
        ])
    }
    let lost = reduce(.enteringRemote(target), .sessionLost(target))
    #expect(lost.state == .local)
    #expect(lost.effects == [.cancelEnterTimeout(target), .restoreLocal])
  }

  @Test("emergency, capture failure and lifecycle reach local in one step from every state")
  func forcedLocal() {
    for state in allStates {
      for action in forcedLocalActions {
        let result = reduce(state, action)
        #expect(result.state == .local, "\(state) \(action)")
        #expect(result.effects.contains(.restoreLocal), "\(state) \(action)")
        #expect(!result.effects.contains(.enableSuppression))
      }
    }
    let fromRemote = reduce(.remote(target), .emergencyEscape)
    #expect(
      fromRemote.effects == [
        .disableSuppression, .releaseRemoteInput(target, .bestEffort),
        .sendLeave(target, .bestEffort), .restoreLocal,
      ])
    let fromEntering = reduce(.enteringRemote(target), .captureFailure)
    #expect(
      fromEntering.effects == [
        .cancelEnterTimeout(target), .sendLeave(target, .bestEffort), .restoreLocal,
      ])
    #expect(reduce(.leavingRemote(target), .lifecycle(.termination)).effects == [.restoreLocal])
    #expect(reduce(.local, .emergencyEscape).effects == [.restoreLocal])
  }

  @Test("session loss in remote disables suppression without sending")
  func sessionLossInRemote() {
    let result = reduce(.remote(target), .sessionLost(target))
    #expect(result.state == .local)
    #expect(result.effects == [.disableSuppression, .restoreLocal])
    let leaving = reduce(.leavingRemote(target), .sessionLost(target))
    #expect(leaving.state == .local)
    #expect(leaving.effects == [.restoreLocal])
  }

  @Test("boundary: stale targets and duplicate triggers are ignored")
  func staleAndDuplicate() {
    let staleActions: [(InputState, InputAction)] = [
      (.enteringRemote(target), .edgeActivated(target: target, entry: entry)),
      (.enteringRemote(target), .edgeActivated(target: other, entry: entry)),
      (.enteringRemote(target), .enterDelivered(other)),
      (.enteringRemote(target), .enterFailed(other)),
      (.enteringRemote(target), .enterTimeout(other)),
      (.enteringRemote(target), .sessionLost(other)),
      (.remote(target), .returnEdge(target: other, localPosition: back)),
      (.remote(target), .sessionLost(other)),
      (.remote(target), .edgeActivated(target: other, entry: entry)),
      (.remote(target), .enterDelivered(target)),
      (.leavingRemote(target), .leaveCompleted(other)),
      (.leavingRemote(target), .edgeActivated(target: target, entry: entry)),
      (.local, .enterDelivered(target)),
      (.local, .returnEdge(target: target, localPosition: back)),
      (.local, .sessionLost(target)),
      (.local, .leaveCompleted(target)),
    ]
    for (state, action) in staleActions {
      let result = reduce(state, action)
      #expect(result.state == state, "\(state) \(action)")
      #expect(result.effects.isEmpty, "\(state) \(action)")
    }
  }

  @Test("invariant: suppression is enabled only on entry to remote and derived from state")
  func suppressionInvariant() {
    for state in allStates {
      for action in allActions {
        let result = reduce(state, action)
        if result.effects.contains(.enableSuppression) {
          #expect(result.state == .remote(target))
          #expect(state == .enteringRemote(target))
        }
        if case .remote = state, result.state != state {
          let first = result.effects.first
          #expect(first == .disableSuppression || first == .restoreLocal, "\(action)")
        }
        #expect(result.state.suppressesLocalInput == (result.state == .remote(target)))
      }
    }
    #expect(!InputState.local.suppressesLocalInput)
    #expect(!InputState.enteringRemote(target).suppressesLocalInput)
    #expect(!InputState.leavingRemote(target).suppressesLocalInput)
    #expect(InputState.remote(target).suppressesLocalInput)
  }

  @Test("idempotency: repeating any action never re-enables suppression or leaves local")
  func idempotency() {
    for state in allStates {
      for action in allActions {
        let first = reduce(state, action)
        let second = reduce(first.state, action)
        if first.state == .local, forcedLocalActions.contains(action) {
          #expect(second.state == .local)
          #expect(second.effects == [.restoreLocal])
        }
        if first.state == state {
          #expect(second == first, "\(state) \(action)")
        }
        #expect(!second.effects.contains(.enableSuppression) || first.state != .remote(target))
      }
    }
  }

  @Test("every state and action pair has a defined deterministic result")
  func totality() {
    for state in allStates {
      for action in allActions {
        #expect(reduce(state, action) == reduce(state, action))
      }
    }
  }
}

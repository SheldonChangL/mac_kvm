import Foundation
import KVMContracts
import KVMCore
import Testing

private let linux = ScreenID(
  rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 2)))
private let other = ScreenID(
  rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x12, 3)))

private func makeFlow() throws -> LeaveRemoteFlow {
  let mapper = try #require(
    ReturnCoordinateMapper(
      localSize: ReturnCoordinateMapper.LogicalSize(width: 1001, height: 501), reentryInset: 2,
      cornerDeadZone: 30))
  return LeaveRemoteFlow(returnMapper: mapper)
}

@Suite("M2-012 LeaveRemoteFlow")
struct LeaveRemoteFlowTests {
  @Test("return edge yields returnEdge with the local re-entry point")
  func returnEdge() throws {
    let flow = try makeFlow()
    let intent = try #require(
      flow.intent(for: .returned(offset: 0.5), target: linux, leftThrough: .right))
    #expect(intent.localPoint == ReturnCoordinateMapper.LocalPoint(x: 998, y: 250))
    #expect(
      intent.action
        == .returnEdge(target: linux, localPosition: NormalizedPoint(x: 998.0 / 1000, y: 0.5)))
    #expect(flow.intent(for: .moved(.init(x: 5, y: 5)), target: linux, leftThrough: .right) == nil)
  }

  @Test("escape and session loss trigger leave without remote acknowledgement")
  func otherTriggers() {
    #expect(LeaveRemoteFlow.escapeAction == .emergencyEscape)
    #expect(LeaveRemoteFlow.sessionEndAction(for: linux) == .sessionLost(linux))
    for action in [LeaveRemoteFlow.escapeAction, LeaveRemoteFlow.sessionEndAction(for: linux)] {
      let result = InputStateReducer.reduce(.remote(linux), action)
      #expect(result.state == .local)
      #expect(result.effects.first == .disableSuppression)
    }
  }

  @Test("leave sends then restores local; repeated and stale leaves are safe")
  func sequence() throws {
    let flow = try makeFlow()
    let intent = try #require(
      flow.intent(for: .returned(offset: 0.25), target: linux, leftThrough: .right))
    var state = InputState.remote(linux)
    let leaving = InputStateReducer.reduce(state, intent.action)
    state = leaving.state
    #expect(state == .leavingRemote(linux))
    #expect(leaving.effects.contains(.sendLeave(linux, .required)))
    #expect(InputStateReducer.reduce(state, intent.action).effects.isEmpty)
    #expect(InputStateReducer.reduce(state, .leaveCompleted(other)).state == state)
    let done = InputStateReducer.reduce(state, .leaveCompleted(linux))
    #expect(done.state == .local)
    #expect(InputStateReducer.reduce(done.state, intent.action).state == .local)
  }
}

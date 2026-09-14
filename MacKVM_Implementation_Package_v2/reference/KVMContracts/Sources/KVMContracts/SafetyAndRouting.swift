import Foundation

public protocol InputSafetyController: Sendable {
    func releaseAllKeys() async
    func releaseAllMouseButtons() async
    func restoreLocalInput() async
    func clearTransientState() async
}

public enum InputState: Equatable, Sendable {
    case local
    case enteringRemote(device: DeviceID)
    case remote(device: DeviceID)
    case leavingRemote(device: DeviceID)
}

public enum InputAction: Equatable, Sendable {
    case edgeActivated(device: DeviceID)
    case enterConfirmed(device: DeviceID)
    case enterFailed(device: DeviceID)
    case returnEdge(device: DeviceID)
    case leaveConfirmed(device: DeviceID)
    case terminalFailure
    case emergencyEscape
}

public enum InputEffect: Equatable, Sendable {
    case requestEnter(DeviceID)
    case beginRemoteRouting(DeviceID)
    case requestLeave(DeviceID)
    case restoreLocal
    case none
}

public protocol InputStateReducing: Sendable {
    func reduce(state: InputState, action: InputAction) -> (InputState, [InputEffect])
}

public enum ScreenEdge: String, Codable, Sendable { case left, right, top, bottom }
public struct ScreenLink: Codable, Equatable, Sendable {
    public let source: ScreenID
    public let edge: ScreenEdge
    public let target: ScreenID
    public init(source: ScreenID, edge: ScreenEdge, target: ScreenID) { self.source = source; self.edge = edge; self.target = target }
}

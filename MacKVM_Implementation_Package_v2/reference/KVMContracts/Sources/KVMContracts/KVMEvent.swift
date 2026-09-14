import Foundation

public struct DeviceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct ScreenID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct SessionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public enum MouseButton: UInt8, Codable, Sendable { case left = 1, right = 2, middle = 3, auxiliary = 4 }
public enum ButtonPhase: UInt8, Codable, Sendable { case down = 1, up = 2 }
public enum KeyPhase: UInt8, Codable, Sendable { case down = 1, up = 2, repeatKey = 3 }

public struct ModifierState: Codable, Equatable, Sendable {
    public var shift: Bool
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var capsLock: Bool
    public init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false, capsLock: Bool = false) {
        self.shift = shift; self.control = control; self.option = option; self.command = command; self.capsLock = capsLock
    }
}

public enum VirtualKey: Codable, Equatable, Sendable {
    case letter(UInt8)
    case digit(UInt8)
    case enter, escape, tab, space, backspace, delete
    case left, right, up, down, home, end, pageUp, pageDown
    case function(UInt8)
    case shift, control, option, command, capsLock
    case volumeUp, volumeDown, mute
    case unknown(UInt32)
}

public struct ClipboardTransactionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
}

public enum ClipboardOrigin: Codable, Equatable, Sendable { case local, remote(DeviceID) }
public struct ClipboardPayload: Codable, Equatable, Sendable {
    public let transactionID: ClipboardTransactionID
    public let origin: ClipboardOrigin
    public let utf8Text: String
    public let contentHash: String
    public init(transactionID: ClipboardTransactionID, origin: ClipboardOrigin, utf8Text: String, contentHash: String) {
        self.transactionID = transactionID; self.origin = origin; self.utf8Text = utf8Text; self.contentHash = contentHash
    }
}

public enum KVMEvent: Codable, Equatable, Sendable {
    case mouseMove(position: NormalizedPoint)
    case mouseButton(button: MouseButton, phase: ButtonPhase)
    case scroll(deltaX: Int32, deltaY: Int32)
    case key(key: VirtualKey, phase: KeyPhase, modifiers: ModifierState)
    case clipboard(ClipboardPayload)
    case enterScreen(screen: ScreenID, position: NormalizedPoint)
    case leaveScreen(screen: ScreenID)
}

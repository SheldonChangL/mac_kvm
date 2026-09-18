import Foundation

public struct NormalizedPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double

  public init(x: Double, y: Double) {
    self.x = Self.normalize(x)
    self.y = Self.normalize(y)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      x: try container.decode(Double.self, forKey: .x),
      y: try container.decode(Double.self, forKey: .y)
    )
  }

  private enum CodingKeys: String, CodingKey {
    case x
    case y
  }

  private static func normalize(_ value: Double) -> Double {
    value.isNaN ? 0 : min(max(value, 0), 1)
  }
}

public enum MouseButton: UInt8, Codable, Equatable, Sendable {
  case left = 1
  case right = 2
  case middle = 3
  case auxiliary = 4
}

public enum ButtonPhase: UInt8, Codable, Equatable, Sendable {
  case down = 1
  case up = 2
}

public enum KeyPhase: UInt8, Codable, Equatable, Sendable {
  case down = 1
  case up = 2
  case repeatKey = 3
}

public struct ModifierState: Codable, Equatable, Sendable {
  public var shift: Bool
  public var control: Bool
  public var option: Bool
  public var command: Bool
  public var capsLock: Bool

  public init(
    shift: Bool = false,
    control: Bool = false,
    option: Bool = false,
    command: Bool = false,
    capsLock: Bool = false
  ) {
    self.shift = shift
    self.control = control
    self.option = option
    self.command = command
    self.capsLock = capsLock
  }
}

public enum VirtualKey: Codable, Equatable, Sendable {
  case letter(UInt8)
  case digit(UInt8)
  case enter
  case escape
  case tab
  case space
  case backspace
  case delete
  case left
  case right
  case up
  case down
  case home
  case end
  case pageUp
  case pageDown
  case function(UInt8)
  case shift
  case control
  case option
  case command
  case capsLock
  case volumeUp
  case volumeDown
  case mute
  case unknown(UInt32)
}

public struct ClipboardTransactionID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public init() {
    self.init(rawValue: UUID())
  }
}

public enum ClipboardOrigin: Codable, Equatable, Sendable {
  case local
  case remote(DeviceID)
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
  public let transactionID: ClipboardTransactionID
  public let origin: ClipboardOrigin
  public let utf8Text: String
  public let contentHash: String

  public init(
    transactionID: ClipboardTransactionID,
    origin: ClipboardOrigin,
    utf8Text: String,
    contentHash: String
  ) {
    self.transactionID = transactionID
    self.origin = origin
    self.utf8Text = utf8Text
    self.contentHash = contentHash
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

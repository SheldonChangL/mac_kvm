import CoreGraphics
import KVMContracts

/// Why a `VirtualKey` has no macOS key code.
///
/// The reasons are closed and carry no payload, so a rejection can be counted
/// or reported without ever exposing the rejected raw code or payload value
/// (Frozen Decision 8, M1-042 unknown-key policy rule 7).
///
/// A rejected key was never mapped, so it must never be injected and never be
/// recorded as pressed in any key or modifier ledger. No cleanup is owed for
/// it (M1-042 unknown-key policy rule 5).
enum MacKeyCodeMappingFailure: String, Error, CaseIterable, Codable, Hashable, Sendable {
  /// `VirtualKey.unknown`. In catalog v1 the raw value has no source
  /// namespace, so it is opaque and is never reused as a platform key code.
  case unknownKey

  /// A `letter`, `digit` or `function` payload outside its catalog v1 domain.
  /// Such a value is not a catalog member and is rejected like `unknown`.
  case payloadOutOfDomain

  /// A catalog v1 member for which the macOS SDK declares no virtual key code.
  /// In catalog v1 this is exactly F21 through F24.
  case noMacOSBaseline
}

/// Maps a C-005 catalog v1 `VirtualKey` to its macOS US ANSI baseline
/// `CGKeyCode`.
///
/// Every code is transcribed from the `kVK_` constants in the SDK's
/// `HIToolbox/Events.h`, which documents them as identifying physical keys,
/// with the `ANSI` constants "labeled according to the key position on an
/// ANSI-standard US keyboard". That matches the positional, layout-free meaning
/// M1-042 gives `letter` and `digit`. Carbon is not imported here; the test
/// suite checks every literal against the SDK constant it was taken from.
///
/// The mapper is a caseless enum: it has no instances and no stored state, owns
/// no task, queue, event source or other resource, and each call derives its
/// result only from its argument. There is therefore nothing to cancel and
/// nothing to clean up, and calls are safe from any thread.
///
/// Everything here is `internal`, so `CGKeyCode` never reaches the package
/// surface, `KVMEvent` or any wire schema. The future keyboard injector lives
/// in this module and consumes the result directly.
enum MacKeyCodeMapper {
  /// The C-005 `VirtualKey` catalog version this table covers.
  static let catalogVersion = 2

  /// US ANSI punctuation key codes in `PunctuationKey` order (catalog v2):
  /// kVK_ANSI_Minus, Equal, LeftBracket, RightBracket, Backslash, Semicolon,
  /// Quote, Grave, Comma, Period and Slash.
  private static let punctuationCodes: [CGKeyCode] = [
    0x1B, 0x18, 0x21, 0x1E, 0x2A, 0x29, 0x27, 0x32, 0x2B, 0x2F, 0x2C,
  ]

  /// Returns the macOS key code for `key`, or the reason it has none.
  ///
  /// The switch is exhaustive with no `default`, so a later catalog member
  /// fails compilation until it is mapped or explicitly rejected (M1-042
  /// unknown-key policy rule 6).
  static func keyCode(for key: VirtualKey) -> Result<CGKeyCode, MacKeyCodeMappingFailure> {
    switch key {
    case .letter(let index):
      guard Int(index) < letters.count else { return .failure(.payloadOutOfDomain) }
      return .success(letters[Int(index)])
    case .digit(let index):
      guard Int(index) < digits.count else { return .failure(.payloadOutOfDomain) }
      return .success(digits[Int(index)])
    case .function(let number):
      if (1...functionKeys.count).contains(Int(number)) {
        return .success(functionKeys[Int(number) - 1])
      }
      // F21-F24 are catalog v1 members with no macOS key code.
      if (21...24).contains(number) {
        return .failure(.noMacOSBaseline)
      }
      return .failure(.payloadOutOfDomain)
    case .enter: return .success(0x24)  // kVK_Return
    case .escape: return .success(0x35)  // kVK_Escape
    case .tab: return .success(0x30)  // kVK_Tab
    case .space: return .success(0x31)  // kVK_Space
    case .backspace: return .success(0x33)  // kVK_Delete
    case .delete: return .success(0x75)  // kVK_ForwardDelete
    case .left: return .success(0x7B)  // kVK_LeftArrow
    case .right: return .success(0x7C)  // kVK_RightArrow
    case .up: return .success(0x7E)  // kVK_UpArrow
    case .down: return .success(0x7D)  // kVK_DownArrow
    case .home: return .success(0x73)  // kVK_Home
    case .end: return .success(0x77)  // kVK_End
    case .pageUp: return .success(0x74)  // kVK_PageUp
    case .pageDown: return .success(0x79)  // kVK_PageDown
    // Modifiers are side-agnostic in catalog v1 and map to the left-side key,
    // which the SDK names without a side prefix.
    case .shift: return .success(0x38)  // kVK_Shift
    case .control: return .success(0x3B)  // kVK_Control
    case .option: return .success(0x3A)  // kVK_Option
    case .command: return .success(0x37)  // kVK_Command
    case .capsLock: return .success(0x39)  // kVK_CapsLock
    case .volumeUp: return .success(0x48)  // kVK_VolumeUp
    case .volumeDown: return .success(0x49)  // kVK_VolumeDown
    case .mute: return .success(0x4A)  // kVK_Mute
    case .punctuation(let key): return .success(punctuationCodes[Int(key.rawValue)])
    case .unknown:
      return .failure(.unknownKey)
    }
  }

  /// `kVK_ANSI_A` through `kVK_ANSI_Z`, indexed by catalog letter `0...25`.
  private static let letters: [CGKeyCode] = [
    0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22,  // A B C D E F G H I
    0x26, 0x28, 0x25, 0x2E, 0x2D, 0x1F, 0x23, 0x0C, 0x0F,  // J K L M N O P Q R
    0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06,  // S T U V W X Y Z
  ]

  /// `kVK_ANSI_0` through `kVK_ANSI_9`, indexed by catalog digit `0...9`.
  private static let digits: [CGKeyCode] = [
    0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19,
  ]

  /// `kVK_F1` through `kVK_F20`, indexed by function number minus one. The SDK
  /// declares no constant above `kVK_F20`.
  private static let functionKeys: [CGKeyCode] = [
    0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,  // F1-F10
    0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,  // F11-F20
  ]
}

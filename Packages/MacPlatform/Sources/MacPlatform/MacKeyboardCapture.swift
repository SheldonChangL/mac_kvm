import CoreGraphics
import KVMContracts

/// Maps physical keyboard `CGEvent`s from the server event tap to `KVMEvent`
/// (M2-005).
///
/// The key table is the exact inverse of the M1-044 `MacKeyCodeMapper` US
/// ANSI baseline, so capture and injection cannot disagree, plus the SDK's
/// right-side modifier codes (`kVK_RightShift` 0x3C, `kVK_RightControl`
/// 0x3E, `kVK_RightOption` 0x3D, `kVK_RightCommand` 0x36), which map to the
/// side-agnostic catalog v1 modifiers. Per the M1-042 adapter rules, a code
/// with no v1 member becomes `unknown(rawCode)`; it is neither dropped nor
/// coerced.
///
/// Key down, key up and autorepeat map to `.down`, `.up` and `.repeatKey`.
/// `flagsChanged` maps a modifier key to `.down` when its flag is set after
/// the change and `.up` otherwise; the fn key does the same with
/// `maskSecondaryFn` and maps to `unknown(rawCode)`. `ModifierState` is read from the event
/// flags (the M1-046 ledger is not yet available).
///
/// The mapper is pure, never logs, and never retains key identity, so it is
/// safe inside the tap callback and cannot leak typed content.
package enum MacKeyboardCapture {
  package static func map(_ event: CGEvent) -> MacCapturedInput? {
    let code = CGKeyCode(clamping: event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = modifierState(event.flags)
    let mapped: KVMEvent
    switch event.type {
    case .keyDown:
      let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      mapped = .key(
        key: virtualKey(code), phase: repeated ? .repeatKey : .down, modifiers: modifiers)
    case .keyUp:
      mapped = .key(key: virtualKey(code), phase: .up, modifiers: modifiers)
    case .flagsChanged:
      if let (key, isSet) = modifierChange(code, modifiers) {
        mapped = .key(key: key, phase: isSet ? .down : .up, modifiers: modifiers)
      } else if code == functionKeyCode {
        let isSet = event.flags.contains(.maskSecondaryFn)
        mapped = .key(key: .unknown(UInt32(code)), phase: isSet ? .down : .up, modifiers: modifiers)
      } else {
        // No phase can be derived for any other flagsChanged code.
        return nil
      }
    default:
      return nil
    }
    return MacCapturedInput(event: mapped, timestamp: event.timestamp)
  }

  private static func virtualKey(_ code: CGKeyCode) -> VirtualKey {
    table[code] ?? .unknown(UInt32(code))
  }

  private static func modifierState(_ flags: CGEventFlags) -> ModifierState {
    ModifierState(
      shift: flags.contains(.maskShift), control: flags.contains(.maskControl),
      option: flags.contains(.maskAlternate), command: flags.contains(.maskCommand),
      capsLock: flags.contains(.maskAlphaShift))
  }

  private static func modifierChange(_ code: CGKeyCode, _ state: ModifierState) -> (
    VirtualKey, Bool
  )? {
    switch table[code] {
    case .shift: (.shift, state.shift)
    case .control: (.control, state.control)
    case .option: (.option, state.option)
    case .command: (.command, state.command)
    case .capsLock: (.capsLock, state.capsLock)
    default: nil
    }
  }

  /// `kVK_Function`: the fn key has no catalog v1 member but reports its
  /// state through `maskSecondaryFn`, so it maps to `unknown(rawCode)`.
  private static let functionKeyCode: CGKeyCode = 0x3F

  private static let rightSideModifiers: [CGKeyCode: VirtualKey] = [
    0x3C: .shift,  // kVK_RightShift
    0x3E: .control,  // kVK_RightControl
    0x3D: .option,  // kVK_RightOption
    0x36: .command,  // kVK_RightCommand
  ]

  /// Inverse of `MacKeyCodeMapper` over every catalog v1 member it maps.
  private static let table: [CGKeyCode: VirtualKey] = {
    var members: [VirtualKey] = (0..<26).map { .letter(UInt8($0)) }
    members += (0..<10).map { .digit(UInt8($0)) }
    members += (1...24).map { .function(UInt8($0)) }
    members += [
      .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
      .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp, .volumeDown,
      .mute,
    ]
    members += PunctuationKey.allCases.map { .punctuation($0) }
    var table = rightSideModifiers
    for member in members {
      if case .success(let code) = MacKeyCodeMapper.keyCode(for: member) {
        table[code] = member
      }
    }
    return table
  }()
}

import Carbon.HIToolbox
import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

private func key(_ code: Int, down: Bool, flags: CGEventFlags = []) throws -> CGEvent {
  let event = try #require(
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down))
  event.flags = flags
  return event
}

private func flagsChanged(_ code: Int, flags: CGEventFlags) throws -> CGEvent {
  let event = try key(code, down: true, flags: flags)
  event.type = .flagsChanged
  return event
}

private let none = ModifierState()

@Suite("M2-005 MacKeyboardCapture")
struct MacKeyboardCaptureTests {
  @Test("key down, up and autorepeat map through the M1-044 table")
  func phases() throws {
    #expect(
      MacKeyboardCapture.map(try key(kVK_ANSI_A, down: true))?.event
        == .key(key: .letter(0), phase: .down, modifiers: none))
    #expect(
      MacKeyboardCapture.map(try key(kVK_ANSI_A, down: false))?.event
        == .key(key: .letter(0), phase: .up, modifiers: none))
    let repeated = try key(kVK_Return, down: true)
    repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    #expect(
      MacKeyboardCapture.map(repeated)?.event
        == .key(key: .enter, phase: .repeatKey, modifiers: none))
  }

  @Test("every catalog key code round-trips through capture")
  func roundTrip() throws {
    var keys: [VirtualKey] =
      (0..<26).map { .letter(UInt8($0)) } + (0..<10).map { .digit(UInt8($0)) }
    keys += (1...20).map { .function(UInt8($0)) }
    keys += [
      .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
      .pageUp, .pageDown, .volumeUp, .volumeDown, .mute,
    ]
    for virtualKey in keys {
      let code = try MacKeyCodeMapper.keyCode(for: virtualKey).get()
      let captured = MacKeyboardCapture.map(try key(Int(code), down: true))
      #expect(captured?.event == .key(key: virtualKey, phase: .down, modifiers: none))
    }
  }

  @Test("modifier flags are reported on every key event")
  func modifiers() throws {
    let flags: CGEventFlags = [
      .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift,
    ]
    let all = ModifierState(shift: true, control: true, option: true, command: true, capsLock: true)
    #expect(
      MacKeyboardCapture.map(try key(kVK_Delete, down: true, flags: flags))?.event
        == .key(key: .backspace, phase: .down, modifiers: all))
  }

  @Test("flagsChanged reports modifier press and release, both sides")
  func flagsChangedEvents() throws {
    let pressed = ModifierState(shift: true)
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_Shift, flags: .maskShift))?.event
        == .key(key: .shift, phase: .down, modifiers: pressed))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_RightShift, flags: []))?.event
        == .key(key: .shift, phase: .up, modifiers: none))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_RightCommand, flags: .maskCommand))?.event
        == .key(key: .command, phase: .down, modifiers: ModifierState(command: true)))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_RightOption, flags: .maskAlternate))?.event
        == .key(key: .option, phase: .down, modifiers: ModifierState(option: true)))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_RightControl, flags: []))?.event
        == .key(key: .control, phase: .up, modifiers: none))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_CapsLock, flags: .maskAlphaShift))?.event
        == .key(key: .capsLock, phase: .down, modifiers: ModifierState(capsLock: true)))
    #expect(MacKeyboardCapture.map(try flagsChanged(kVK_ANSI_A, flags: [])) == nil)
  }

  @Test("unmapped key codes become unknown(raw) instead of being dropped")
  func unknown() throws {
    // macOS creates a fn key event as `flagsChanged`; its phase comes from the fn flag.
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_Function, flags: .maskSecondaryFn))?.event
        == .key(key: .unknown(UInt32(kVK_Function)), phase: .down, modifiers: none))
    #expect(
      MacKeyboardCapture.map(try flagsChanged(kVK_Function, flags: []))?.event
        == .key(key: .unknown(UInt32(kVK_Function)), phase: .up, modifiers: none))
    #expect(
      MacKeyboardCapture.map(try key(kVK_ANSI_KeypadEnter, down: false))?.event
        == .key(key: .unknown(UInt32(kVK_ANSI_KeypadEnter)), phase: .up, modifiers: none))
  }

  @Test("timestamps are preserved and non-keyboard events are ignored")
  func timestampsAndOthers() throws {
    let event = try key(kVK_Space, down: true)
    event.timestamp = 42
    #expect(MacKeyboardCapture.map(event)?.timestamp == 42)
    let mouse = try #require(
      CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
        mouseButton: .left))
    #expect(MacKeyboardCapture.map(mouse) == nil)
  }
}

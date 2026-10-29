import Foundation
import KVMContracts
import KVMCore
import Testing

private let chord = ModifierState(control: true, option: true, command: true)
private let target = ScreenID(
  rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x14, 1)))

private func key(_ key: VirtualKey, _ phase: KeyPhase, _ modifiers: ModifierState) -> KVMEvent {
  .key(key: key, phase: phase, modifiers: modifiers)
}

@Suite("M2-014 EmergencyEscape")
struct EmergencyEscapeTests {
  @Test("the documented chord on key down is the escape, with Delete or Return")
  func chordMatches() {
    #expect(EmergencyEscape.action(for: key(.backspace, .down, chord)) == .emergencyEscape)
    #expect(EmergencyEscape.action(for: key(.enter, .down, chord)) == .emergencyEscape)
    var withShift = chord
    withShift.shift = true
    withShift.capsLock = true
    #expect(EmergencyEscape.action(for: key(.backspace, .down, withShift)) == .emergencyEscape)
  }

  @Test("boundary: missing modifiers, other keys, key up and repeat do not match")
  func nonMatches() {
    #expect(EmergencyEscape.action(for: key(.backspace, .up, chord)) == nil)
    #expect(EmergencyEscape.action(for: key(.backspace, .repeatKey, chord)) == nil)
    #expect(EmergencyEscape.action(for: key(.delete, .down, chord)) == nil)
    #expect(EmergencyEscape.action(for: key(.escape, .down, chord)) == nil)
    for missing in [\ModifierState.control, \.option, \.command] {
      var partial = chord
      partial[keyPath: missing] = false
      #expect(EmergencyEscape.action(for: key(.backspace, .down, partial)) == nil)
    }
    #expect(EmergencyEscape.action(for: .mouseButton(button: .left, phase: .down)) == nil)
    #expect(EmergencyEscape.action(for: .scroll(deltaX: 0, deltaY: 1)) == nil)
  }

  @Test("escape restores local from every state without waiting for the remote side")
  func escapeIsLocalFirst() {
    for state in [
      InputState.local, .enteringRemote(target), .remote(target), .leavingRemote(target),
    ] {
      let result = InputStateReducer.reduce(state, .emergencyEscape)
      #expect(result.state == .local)
      #expect(result.effects.last == .restoreLocal)
      for effect in result.effects {
        if case .sendLeave(_, let delivery) = effect { #expect(delivery == .bestEffort) }
        if case .releaseRemoteInput(_, let delivery) = effect { #expect(delivery == .bestEffort) }
      }
    }
  }

  @Test("the chord is never forwarded to a remote target")
  func neverForwarded() {
    #expect(EmergencyEscape.isChordKey(key(.backspace, .down, chord)))
    #expect(EmergencyEscape.isChordKey(key(.backspace, .up, chord)))
    #expect(EmergencyEscape.isChordKey(key(.enter, .up, chord)))
    #expect(!EmergencyEscape.isChordKey(key(.backspace, .down, ModifierState())))
    #expect(!EmergencyEscape.isChordKey(key(.enter, .down, ModifierState())))
  }
}

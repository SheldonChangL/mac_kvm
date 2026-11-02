import Foundation
import KVMContracts
import KVMCore
import Testing

// The fixtures follow the key events the client session composes (M1-043, "The `modifiers`
// field, for consumers"), which come from the wire contract M1-PROTOCOL-003 ("Keys"):
// - on any key other than a modifier, `modifiers` is the state in effect while the key is
//   pressed, repeated or released;
// - on a modifier key's own press it is the state before the press, and on its own release the
//   state including the key, so the key's own bit is the opposite of the state after the event;
// - Caps Lock arrives as a press and a release for each toggle. Turning the lock on, the press
//   lacks the lock bit and the release has it; turning it off, both have it.

// MARK: - Fixtures

/// The four modifiers a key holds while it is pressed.
private let heldModifierKeys: [VirtualKey] = [.shift, .control, .option, .command]

/// Every other `VirtualKey` case, with the edges of the payload domains.
private let otherKeys: [VirtualKey] = [
  .letter(0), .letter(25), .digit(0), .digit(9), .enter, .escape, .tab, .space, .backspace,
  .delete, .left, .right, .up, .down, .home, .end, .pageUp, .pageDown, .function(1),
  .function(12), .capsLock, .volumeUp, .volumeDown, .mute, .punctuation(.minus),
  .punctuation(.slash), .unknown(0), .unknown(42), .unknown(UInt32.max),
]

private let phases: [KeyPhase] = [.down, .up, .repeatKey]

/// The flag of `modifier` in `state`.
private func flag(_ modifier: VirtualKey, in state: ModifierState) -> Bool {
  switch modifier {
  case .shift: return state.shift
  case .control: return state.control
  case .option: return state.option
  case .command: return state.command
  case .capsLock: return state.capsLock
  default:
    Issue.record("not a modifier key")
    return false
  }
}

/// `state` with the flag of `modifier` set to `value`.
private func setting(
  _ modifier: VirtualKey, to value: Bool, in state: ModifierState
) -> ModifierState {
  var state = state
  switch modifier {
  case .shift: state.shift = value
  case .control: state.control = value
  case .option: state.option = value
  case .command: state.command = value
  case .capsLock: state.capsLock = value
  default: Issue.record("not a modifier key")
  }
  return state
}

/// The state with exactly the flags of `keys` set.
private func modifiers(_ keys: VirtualKey...) -> ModifierState {
  keys.reduce(ModifierState()) { setting($1, to: true, in: $0) }
}

/// The state whose flags are the bits of `mask`, in the order shift, control, option, command,
/// capsLock.
private func modifiers(mask: Int) -> ModifierState {
  ModifierState(
    shift: mask & 1 != 0, control: mask & 2 != 0, option: mask & 4 != 0,
    command: mask & 8 != 0, capsLock: mask & 16 != 0)
}

/// The flags set in `state` and clear in `other`.
private func flags(_ state: ModifierState, without other: ModifierState) -> ModifierState {
  ModifierState(
    shift: state.shift && !other.shift, control: state.control && !other.control,
    option: state.option && !other.option, command: state.command && !other.command,
    capsLock: state.capsLock && !other.capsLock)
}

/// Compiles only for a `Sendable` type.
private func requireSendable<T: Sendable>(_: T.Type) {}

private func key(
  _ key: VirtualKey, _ phase: KeyPhase, _ modifiers: ModifierState = ModifierState()
) -> KVMEvent {
  .key(key: key, phase: phase, modifiers: modifiers)
}

/// A modifier key's own press as the wire delivers it: the state before the press, so the key's
/// own bit is clear. `others` is the rest of the state in effect.
private func press(
  _ modifier: VirtualKey, with others: ModifierState = ModifierState()
) -> KVMEvent {
  key(modifier, .down, setting(modifier, to: false, in: others))
}

/// A modifier key's own release as the wire delivers it: the state including the key.
private func release(
  _ modifier: VirtualKey, with others: ModifierState = ModifierState()
) -> KVMEvent {
  key(modifier, .up, setting(modifier, to: true, in: others))
}

private func fixedUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x46, value))
}

/// Every kind of event that is not a key event.
private let nonKeyEvents: [KVMEvent] = [
  .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)),
  .mouseButton(button: .left, phase: .down),
  .mouseButton(button: .auxiliary, phase: .up),
  .scroll(deltaX: -1, deltaY: 1),
  .clipboard(
    ClipboardPayload(
      transactionID: ClipboardTransactionID(rawValue: fixedUUID(1)), origin: .local,
      utf8Text: "", contentHash: "m1-046-hash")),
  .enterScreen(screen: ScreenID(rawValue: fixedUUID(2)), position: NormalizedPoint(x: 0, y: 1)),
  .leaveScreen(screen: ScreenID(rawValue: fixedUUID(2))),
]

// MARK: - The first-party server chain

/// The client events the first-party server chain (encoder, decoder and mapper) delivers for one
/// server capture event, as M1-043's round-trip table states it ("Round trip with the first-party
/// server", pinned by its `encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey`).
/// A capture event carries the state after the event.
///
/// - A press or release of Shift, Control, Option or Command: the same key and phase, with the
///   key's own bit inverted.
/// - Caps Lock: each toggle becomes a press and a release. Turned on (the capture's press), the
///   press lacks the lock bit and the release has it; turned off (the capture's release), both
///   have it. A repeat sends nothing.
/// - Every other key event, a modifier's repeat included: unchanged.
///
/// The test target cannot import the encoder, decoder and mapper, so the table stands in for
/// them.
private func serverChain(_ event: KVMEvent) -> [KVMEvent] {
  guard case .key(let pressed, let phase, let after) = event else { return [event] }
  if pressed == .capsLock {
    guard phase != .repeatKey else { return [] }
    return [
      key(.capsLock, .down, setting(.capsLock, to: phase == .up, in: after)),
      key(.capsLock, .up, setting(.capsLock, to: true, in: after)),
    ]
  }
  if heldModifierKeys.contains(pressed), phase != .repeatKey {
    return [key(pressed, phase, setting(pressed, to: !flag(pressed, in: after), in: after))]
  }
  return [event]
}

/// A server capture session. Each event carries the state after it, as the server's capture
/// reports it (M2-005): a modifier key reports a press while its flag is set after the change, so
/// releasing one side of a modifier while the other side is still held reports a press.
private let serverSession: [KVMEvent] = [
  // Shift+A, then Control+Shift+Tab with a repeat.
  key(.shift, .down, modifiers(.shift)),
  key(.letter(0), .down, modifiers(.shift)),
  key(.letter(0), .up, modifiers(.shift)),
  key(.shift, .up),
  key(.control, .down, modifiers(.control)),
  key(.shift, .down, modifiers(.control, .shift)),
  key(.tab, .down, modifiers(.control, .shift)),
  key(.tab, .repeatKey, modifiers(.control, .shift)),
  key(.tab, .up, modifiers(.control, .shift)),
  key(.shift, .up, modifiers(.control)),
  key(.control, .up),
  // Option and Command, released in press order.
  key(.option, .down, modifiers(.option)),
  key(.letter(4), .down, modifiers(.option)),
  key(.letter(4), .up, modifiers(.option)),
  key(.command, .down, modifiers(.option, .command)),
  key(.option, .up, modifiers(.command)),
  key(.digit(2), .down, modifiers(.command)),
  key(.digit(2), .up, modifiers(.command)),
  key(.command, .up),
  // Both Shift keys: left down, right down, left up (still a press), right up.
  key(.shift, .down, modifiers(.shift)),
  key(.shift, .down, modifiers(.shift)),
  key(.shift, .down, modifiers(.shift)),
  key(.letter(1), .down, modifiers(.shift)),
  key(.letter(1), .up, modifiers(.shift)),
  key(.shift, .up),
  // Caps Lock on, typing, Shift with the lock on, Caps Lock off, typing.
  key(.capsLock, .down, modifiers(.capsLock)),
  key(.letter(2), .down, modifiers(.capsLock)),
  key(.letter(2), .up, modifiers(.capsLock)),
  key(.shift, .down, modifiers(.shift, .capsLock)),
  key(.punctuation(.slash), .down, modifiers(.shift, .capsLock)),
  key(.punctuation(.slash), .up, modifiers(.shift, .capsLock)),
  key(.shift, .up, modifiers(.capsLock)),
  key(.capsLock, .up),
  key(.letter(2), .down),
  key(.letter(2), .up),
  // A modifier's repeat, then a function key with the modifier held. (The encoder sends nothing
  // for a key outside its table, so the chain never delivers an unknown key.)
  key(.control, .down, modifiers(.control)),
  key(.control, .repeatKey, modifiers(.control)),
  key(.function(5), .down, modifiers(.control)),
  key(.function(5), .up, modifiers(.control)),
  key(.control, .up),
]

// MARK: - Reference rules for random sequences

/// The state the rules give after `history`, derived from the whole history rather than step by
/// step: a held modifier is held when its last press or release was a press (repeats change
/// nothing), and the lock bit is the last key event's.
private func expectedState(after history: [KVMEvent]) -> ModifierState {
  var state = ModifierState()
  for modifier in heldModifierKeys {
    let last = history.last { event in
      guard case .key(let pressed, let phase, _) = event else { return false }
      return pressed == modifier && phase != .repeatKey
    }
    if case .key(_, .down, _)? = last {
      state = setting(modifier, to: true, in: state)
    }
  }
  for event in history.reversed() {
    if case .key(_, _, let reported) = event {
      state.capsLock = reported.capsLock
      break
    }
  }
  return state
}

/// The discrepancy the rules give for `event`, given the events before it and the state after
/// it. The event's modifiers, with a held modifier's own bit on its own press or release taken
/// from the key, are compared field by field with that state; the lock bit is compared with the
/// previous key event's bit (clear when there is none), unless this event or the previous key
/// event is a Caps Lock event.
private func expectedDiscrepancy(
  _ event: KVMEvent, before history: [KVMEvent], after state: ModifierState
) -> ModifierDiscrepancy {
  guard case .key(let pressed, let phase, var reported) = event else {
    return ModifierDiscrepancy()
  }
  if heldModifierKeys.contains(pressed), phase != .repeatKey {
    reported = setting(pressed, to: phase == .down, in: reported)
  }
  var previousLock = false
  var previousWasCapsLock = false
  for earlier in history.reversed() {
    if case .key(let previousKey, _, let previousModifiers) = earlier {
      previousLock = previousModifiers.capsLock
      previousWasCapsLock = previousKey == .capsLock
      break
    }
  }
  var compared = state
  if pressed != .capsLock, !previousWasCapsLock {
    compared.capsLock = previousLock
  }
  return ModifierDiscrepancy(
    implied: flags(reported, without: compared), stale: flags(compared, without: reported))
}

/// A seeded generator, so that a failing sequence can be replayed.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }
}

private func randomEvent(_ generator: inout SplitMix64) -> KVMEvent {
  let reported = modifiers(mask: Int.random(in: 0..<32, using: &generator))
  let phase = phases[Int.random(in: 0..<phases.count, using: &generator)]
  switch Int.random(in: 0..<10, using: &generator) {
  case 0..<5:
    let modifier = heldModifierKeys[Int.random(in: 0..<heldModifierKeys.count, using: &generator)]
    return key(modifier, phase, reported)
  case 5..<9:
    return key(otherKeys[Int.random(in: 0..<otherKeys.count, using: &generator)], phase, reported)
  default:
    return nonKeyEvents[Int.random(in: 0..<nonKeyEvents.count, using: &generator)]
  }
}

// MARK: - Determinism helpers

private struct Step: Equatable, Sendable {
  let state: ModifierState
  let discrepancy: ModifierDiscrepancy
}

private func run(_ events: [KVMEvent]) -> [Step] {
  var ledger = ModifierStateLedger()
  return events.map { event in
    let discrepancy = ledger.apply(event)
    return Step(state: ledger.state, discrepancy: discrepancy)
  }
}

/// The production file's code lines: trimmed, without `//` comments and blank lines.
private func productionCode() throws -> [String] {
  let url = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // KVMCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // KVMCore
    .appendingPathComponent("Sources/KVMCore/ModifierStateLedger.swift")
  let text = try String(contentsOf: url, encoding: .utf8)
  return text.components(separatedBy: "\n").compactMap { line in
    let code = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
    return code.isEmpty ? nil : code
  }
}

// MARK: - Tests

@Suite("M1-046 Modifier state ledger")
struct ModifierStateLedgerTests {
  @Test func newLedgerHoldsNothingAndAgreesWithAnEmptyReport() {
    let ledger = ModifierStateLedger()
    #expect(ledger.state == ModifierState())
    #expect(ledger == ModifierStateLedger())
    #expect(ledger.reconcile(with: ModifierState()) == ModifierDiscrepancy())
    #expect(ledger.reconcile(with: ModifierState()).isEmpty)
  }

  @Test func discrepancyIsEmptyOnlyWhenNoFieldDiffers() {
    #expect(ModifierDiscrepancy().isEmpty)
    #expect(ModifierDiscrepancy().implied == ModifierState())
    #expect(ModifierDiscrepancy().stale == ModifierState())
    for modifier in heldModifierKeys + [.capsLock] {
      let one = modifiers(modifier)
      #expect(!ModifierDiscrepancy(implied: one).isEmpty)
      #expect(!ModifierDiscrepancy(stale: one).isEmpty)
      #expect(ModifierDiscrepancy(implied: one).implied == one)
      #expect(ModifierDiscrepancy(stale: one).stale == one)
    }
  }

  @Test func eachModifierKeyHoldsItsOwnFlagFromItsPressToItsRelease() {
    for modifier in heldModifierKeys {
      var ledger = ModifierStateLedger()
      #expect(ledger.apply(press(modifier)).isEmpty)
      #expect(ledger.state == modifiers(modifier))
      #expect(ledger.apply(release(modifier)).isEmpty)
      #expect(ledger.state == ModifierState())
    }
    // All four, pressed in order and released in reverse, each frame carrying the others.
    var ledger = ModifierStateLedger()
    var held = ModifierState()
    for modifier in heldModifierKeys {
      #expect(ledger.apply(press(modifier, with: held)).isEmpty)
      held = setting(modifier, to: true, in: held)
      #expect(ledger.state == held)
    }
    for modifier in heldModifierKeys.reversed() {
      #expect(ledger.apply(release(modifier, with: held)).isEmpty)
      held = setting(modifier, to: false, in: held)
      #expect(ledger.state == held)
    }
    #expect(ledger.state == ModifierState())
  }

  @Test func ownBitOfAModifierPressOrReleaseIsNotComparedButItsOtherBitsAre() {
    for modifier in heldModifierKeys {
      // The wire's inverted own bit: clear on the press, set on the release. A tap leaves
      // nothing held and reports nothing.
      var ledger = ModifierStateLedger()
      #expect(ledger.apply(key(modifier, .down)).isEmpty)
      #expect(flag(modifier, in: ledger.state))
      #expect(ledger.apply(key(modifier, .up, modifiers(modifier))).isEmpty)
      #expect(ledger.state == ModifierState())
      // An own bit that says otherwise changes neither the state nor the report: with the sides
      // collapsed, the key cannot tell whether the other side is held.
      #expect(ledger.apply(key(modifier, .down, modifiers(modifier))).isEmpty)
      #expect(ledger.state == modifiers(modifier))
      #expect(ledger.apply(key(modifier, .up)).isEmpty)
      #expect(ledger.state == ModifierState())
    }
    // The other bits of a modifier's own frame are reconciled like any key's.
    var ledger = ModifierStateLedger()
    let control = modifiers(.control)
    #expect(
      ledger.apply(press(.shift, with: control)) == ModifierDiscrepancy(implied: control))
    #expect(ledger.state == modifiers(.shift))
    #expect(ledger.apply(press(.option, with: modifiers(.shift))).isEmpty)
    #expect(ledger.apply(release(.option)) == ModifierDiscrepancy(stale: modifiers(.shift)))
    #expect(ledger.state == modifiers(.shift))
  }

  @Test func bothSidesOfAModifierCollapseAndTheFirstReleaseReleases() {
    // Left and right arrive as the same side-agnostic key (M1-042).
    var ledger = ModifierStateLedger()
    #expect(ledger.apply(press(.shift)).isEmpty)
    #expect(ledger.apply(key(.shift, .down, modifiers(.shift))).isEmpty)
    #expect(ledger.state == modifiers(.shift))
    // The first release on either side releases: release over stuck input (M1-042 costs).
    #expect(ledger.apply(release(.shift)).isEmpty)
    #expect(ledger.state == ModifierState())
    // The other side's release finds nothing to clear.
    #expect(ledger.apply(release(.shift)).isEmpty)
    #expect(ledger.state == ModifierState())

    // The first-party server's sequence for left down, right down, left up, right up: three
    // presses, then one release. Nothing stays held after the last release.
    for modifier in heldModifierKeys {
      var server = ModifierStateLedger()
      for _ in 0..<3 {
        #expect(server.apply(press(modifier)).isEmpty)
        #expect(server.state == modifiers(modifier))
      }
      #expect(server.apply(release(modifier)).isEmpty)
      #expect(server.state == ModifierState())
    }
  }

  @Test func capsLockFollowsTheFramesLockBitThroughBothTogglePatterns() {
    var ledger = ModifierStateLedger()
    let lock = modifiers(.capsLock)
    // Turning the lock on: the press lacks the bit, the release has it.
    #expect(ledger.apply(key(.capsLock, .down)).isEmpty)
    #expect(ledger.state == ModifierState())
    #expect(ledger.apply(key(.capsLock, .up, lock)).isEmpty)
    #expect(ledger.state == lock)
    #expect(ledger.apply(key(.letter(0), .down, lock)).isEmpty)
    #expect(ledger.apply(key(.letter(0), .up, lock)).isEmpty)
    #expect(ledger.state == lock)
    // Turning it off: both frames have the bit, so the bit last seen stays set ...
    #expect(ledger.apply(key(.capsLock, .down, lock)).isEmpty)
    #expect(ledger.state == lock)
    #expect(ledger.apply(key(.capsLock, .up, lock)).isEmpty)
    #expect(ledger.state == lock)
    // ... until the next key's frame, which shows the lock off. The toggle explains the change,
    // so it is not reported.
    #expect(ledger.apply(key(.letter(0), .down)).isEmpty)
    #expect(ledger.state == ModifierState())
    // A later change that no Caps Lock event explains is reported once, then taken.
    #expect(ledger.apply(key(.letter(0), .up, lock)) == ModifierDiscrepancy(implied: lock))
    #expect(ledger.state == lock)
    #expect(ledger.apply(key(.letter(4), .down, lock)).isEmpty)
    // Caps Lock is never a held modifier: its frames change no held flag.
    #expect(ledger.apply(press(.shift, with: lock)).isEmpty)
    #expect(ledger.apply(key(.capsLock, .down, modifiers(.shift))).isEmpty)
    #expect(ledger.apply(key(.capsLock, .up, modifiers(.shift, .capsLock))).isEmpty)
    #expect(ledger.state == modifiers(.shift, .capsLock))
  }

  @Test func lockBitChangesThatNoCapsLockEventExplainsAreReportedOnce() {
    // The server's lock was on before the pointer entered: no Caps Lock event arrives.
    var ledger = ModifierStateLedger()
    let lock = modifiers(.capsLock)
    #expect(ledger.apply(key(.letter(1), .down, lock)) == ModifierDiscrepancy(implied: lock))
    #expect(ledger.state == lock)
    #expect(ledger.apply(key(.letter(1), .repeatKey, lock)).isEmpty)
    #expect(ledger.apply(key(.letter(1), .up, lock)).isEmpty)
    // Every kind of key event carries the bit: a modifier's own press, an unknown key.
    #expect(ledger.apply(press(.shift)) == ModifierDiscrepancy(stale: lock))
    #expect(ledger.state == modifiers(.shift))
    #expect(
      ledger.apply(key(.unknown(42), .up, modifiers(.shift, .capsLock)))
        == ModifierDiscrepancy(implied: lock))
    #expect(ledger.state == modifiers(.shift, .capsLock))
    // Events other than keys carry no lock bit and leave it alone.
    for event in nonKeyEvents {
      #expect(ledger.apply(event).isEmpty)
    }
    #expect(ledger.state == modifiers(.shift, .capsLock))
    #expect(ledger.apply(key(.space, .down, modifiers(.shift, .capsLock))).isEmpty)
  }

  @Test func reconcileReportsEveryFieldOnItsOwnAgainstEveryLedgerState() {
    for heldMask in 0..<16 {
      for lockSeen in [false, true] {
        var ledger = ModifierStateLedger()
        var held = ModifierState()
        for modifier in heldModifierKeys where flag(modifier, in: modifiers(mask: heldMask)) {
          _ = ledger.apply(press(modifier, with: held))
          held = setting(modifier, to: true, in: held)
        }
        held.capsLock = lockSeen
        _ = ledger.apply(key(.space, .up, held))
        #expect(ledger.state == held)
        for reportedMask in 0..<32 {
          let reported = modifiers(mask: reportedMask)
          let expected = ModifierDiscrepancy(
            implied: flags(reported, without: held), stale: flags(held, without: reported))
          let result = ledger.reconcile(with: reported)
          #expect(result == expected, "held \(heldMask) lock \(lockSeen) reported \(reportedMask)")
          #expect(result.isEmpty == (reported == held))
          // After a key event other than Caps Lock, the next key event compares the lock bit
          // too, then takes it.
          var applied = ledger
          let event = applied.apply(key(.letter(7), .down, reported))
          #expect(event == expected, "held \(heldMask) lock \(lockSeen) reported \(reportedMask)")
          #expect(applied.state == setting(.capsLock, to: reported.capsLock, in: held))
        }
      }
    }
  }

  @Test func modifierHeldAtEnterIsReportedAsImpliedAndNeverSynthesized() {
    // Shift was held on the server before the pointer entered this screen: no press arrives,
    // only the masks of later keys show it (Product Owner decision of 2026-11-02: report only).
    var ledger = ModifierStateLedger()
    let shift = modifiers(.shift)
    #expect(ledger.apply(key(.letter(0), .down, shift)) == ModifierDiscrepancy(implied: shift))
    #expect(
      ledger.apply(key(.letter(0), .repeatKey, shift)) == ModifierDiscrepancy(implied: shift))
    #expect(ledger.apply(key(.letter(0), .up, shift)) == ModifierDiscrepancy(implied: shift))
    #expect(ledger.state == ModifierState())
    // Its release carries the state including Shift; the own bit is not compared, and there is
    // nothing to clear.
    #expect(ledger.apply(release(.shift)).isEmpty)
    #expect(ledger.state == ModifierState())
    #expect(ledger.apply(key(.letter(0), .down)).isEmpty)
    // Every combination of held modifiers is reported and none is adopted.
    for mask in 1..<16 {
      var fresh = ModifierStateLedger()
      let reported = modifiers(mask: mask)
      #expect(fresh.apply(key(.space, .down, reported)) == ModifierDiscrepancy(implied: reported))
      #expect(fresh.state == ModifierState())
    }
  }

  @Test func staleModifierIsReportedAndStaysHeldUntilItsOwnRelease() {
    var ledger = ModifierStateLedger()
    let control = modifiers(.control)
    #expect(ledger.apply(press(.control)).isEmpty)
    // The server reports Control released, but its release never arrived.
    #expect(ledger.apply(key(.letter(2), .down)) == ModifierDiscrepancy(stale: control))
    #expect(ledger.apply(key(.letter(2), .up)) == ModifierDiscrepancy(stale: control))
    // The ledger keeps it, so a release-all still releases Control (Frozen Decision 7).
    #expect(ledger.state == control)
    // Only its own release clears it.
    #expect(ledger.apply(release(.control)).isEmpty)
    #expect(ledger.state == ModifierState())
    // Every combination of held modifiers can be stale at once.
    for mask in 1..<16 {
      var stale = ModifierStateLedger()
      var held = ModifierState()
      for modifier in heldModifierKeys where flag(modifier, in: modifiers(mask: mask)) {
        _ = stale.apply(press(modifier, with: held))
        held = setting(modifier, to: true, in: held)
      }
      #expect(stale.apply(key(.space, .down)) == ModifierDiscrepancy(stale: held))
      #expect(stale.state == held)
    }
  }

  @Test func repeatOfAModifierChangesNothingAndAnUnheldRepeatIsImplied() {
    for modifier in heldModifierKeys {
      let own = modifiers(modifier)
      var ledger = ModifierStateLedger()
      // A repeat of a modifier that was never pressed: the server says it is held.
      #expect(ledger.apply(key(modifier, .repeatKey, own)) == ModifierDiscrepancy(implied: own))
      #expect(ledger.state == ModifierState())
      // A repeat of a held modifier carries it in effect and changes nothing.
      #expect(ledger.apply(press(modifier)).isEmpty)
      #expect(ledger.apply(key(modifier, .repeatKey, own)).isEmpty)
      #expect(ledger.state == own)
      // A repeat that says released is reported stale; the modifier stays held.
      #expect(ledger.apply(key(modifier, .repeatKey)) == ModifierDiscrepancy(stale: own))
      #expect(ledger.state == own)
    }
  }

  @Test func otherKeysNeverChangeTheHeldModifiers() {
    let shift = modifiers(.shift)
    let control = modifiers(.control)
    for other in otherKeys {
      for phase in phases {
        var ledger = ModifierStateLedger()
        _ = ledger.apply(press(.shift))
        #expect(ledger.apply(key(other, phase, shift)).isEmpty)
        #expect(ledger.state == shift)
        #expect(
          ledger.apply(key(other, phase, control))
            == ModifierDiscrepancy(implied: control, stale: shift))
        #expect(ledger.state == shift)
      }
    }
  }

  @Test func eventsOtherThanKeysChangeNothingAndReportNothing() {
    var ledger = ModifierStateLedger()
    _ = ledger.apply(press(.shift))
    _ = ledger.apply(press(.control, with: modifiers(.shift)))
    _ = ledger.apply(key(.space, .up, modifiers(.shift, .control, .capsLock)))
    let before = ledger
    #expect(before.state == modifiers(.shift, .control, .capsLock))
    // Leaving the screen does not clear the ledger either: the owner calls `clear()`.
    for event in nonKeyEvents {
      #expect(ledger.apply(event).isEmpty)
      #expect(ledger == before)
    }
  }

  @Test func clearForgetsEveryModifierAndTheLockBitAndIsIdempotent() {
    var ledger = ModifierStateLedger()
    var held = ModifierState()
    for modifier in heldModifierKeys {
      #expect(ledger.apply(press(modifier, with: held)).isEmpty)
      held = setting(modifier, to: true, in: held)
    }
    held.capsLock = true
    let lock = modifiers(.capsLock)
    #expect(ledger.apply(key(.space, .down, held)) == ModifierDiscrepancy(implied: lock))
    #expect(ledger.state == modifiers(.shift, .control, .option, .command, .capsLock))
    ledger.clear()
    #expect(ledger.state == ModifierState())
    #expect(ledger == ModifierStateLedger())
    ledger.clear()
    #expect(ledger == ModifierStateLedger())
    // After a disconnect nothing is held: a modifier the server still holds is implied.
    let shift = modifiers(.shift)
    #expect(ledger.apply(key(.letter(0), .down, shift)) == ModifierDiscrepancy(implied: shift))
    #expect(ledger.state == ModifierState())
    // It also forgets a pending toggle: after a Caps Lock event and a disconnect, the next key
    // event's lock bit is compared again.
    var toggled = ModifierStateLedger()
    #expect(toggled.apply(key(.capsLock, .down)).isEmpty)
    toggled.clear()
    #expect(toggled == ModifierStateLedger())
    #expect(toggled.apply(key(.letter(0), .down, lock)) == ModifierDiscrepancy(implied: lock))
  }

  @Test func serverChainRoundTripKeepsTheLedgerOnTheServersState() {
    var ledger = ModifierStateLedger()
    for (index, event) in serverSession.enumerated() {
      guard case .key(let pressed, _, let after) = event else { continue }
      for clientEvent in serverChain(event) {
        #expect(ledger.apply(clientEvent).isEmpty, "server event \(index)")
      }
      // Both toggle patterns end with the lock bit set; the next key's frame shows the lock.
      let lock = pressed == .capsLock ? true : after.capsLock
      #expect(ledger.state == setting(.capsLock, to: lock, in: after), "server event \(index)")
    }
    #expect(ledger.state == ModifierState())
  }

  @Test func serverReleasesBeforeLeavingLeaveNothingHeld() {
    // Before it leaves, the first-party server releases what it holds on the client, newest
    // press first, each with the modifiers recorded at its press (ServerCoordinator,
    // `releaseRemoteInput`).
    let presses = [
      key(.control, .down, modifiers(.control)),
      key(.shift, .down, modifiers(.control, .shift)),
      key(.letter(3), .down, modifiers(.control, .shift)),
    ]
    var ledger = ModifierStateLedger()
    for clientEvent in presses.flatMap(serverChain) {
      #expect(ledger.apply(clientEvent).isEmpty)
    }
    #expect(ledger.state == modifiers(.control, .shift))
    for press in presses.reversed() {
      guard case .key(let pressed, _, let atPress) = press else { continue }
      for clientEvent in serverChain(key(pressed, .up, atPress)) {
        #expect(ledger.apply(clientEvent).isEmpty)
      }
    }
    #expect(ledger.state == ModifierState())

    // A modifier released after a press that recorded it: that press's release still carries
    // it, so it is reported as implied; nothing is adopted and nothing stays held.
    var released = ModifierStateLedger()
    let shiftThenControl = [
      key(.shift, .down, modifiers(.shift)),
      key(.control, .down, modifiers(.shift, .control)),
      key(.shift, .up, modifiers(.control)),
    ]
    for clientEvent in shiftThenControl.flatMap(serverChain) {
      #expect(released.apply(clientEvent).isEmpty)
    }
    #expect(released.state == modifiers(.control))
    let releases = serverChain(key(.control, .up, modifiers(.shift, .control)))
    #expect(releases == [key(.control, .up, modifiers(.shift))])
    for clientEvent in releases {
      #expect(released.apply(clientEvent) == ModifierDiscrepancy(implied: modifiers(.shift)))
    }
    #expect(released.state == ModifierState())
  }

  @Test func randomSequencesFollowTheRulesStatedOverTheWholeHistory() {
    var generator = SplitMix64(state: 46)
    for sequence in 0..<200 {
      var ledger = ModifierStateLedger()
      var history: [KVMEvent] = []
      for step in 0..<64 {
        let event = randomEvent(&generator)
        let before = history
        history.append(event)
        let discrepancy = ledger.apply(event)
        let state = expectedState(after: history)
        let place = "sequence \(sequence) step \(step)"
        guard ledger.state == state else {
          Issue.record("state differs from the rules at \(place)")
          return
        }
        guard discrepancy == expectedDiscrepancy(event, before: before, after: state) else {
          Issue.record("discrepancy differs from the rules at \(place)")
          return
        }
        // A held modifier is never implied, and only a held modifier can be stale. (The lock bit
        // is compared with the previous key event's bit instead.)
        let held = setting(.capsLock, to: false, in: state)
        let implied = setting(.capsLock, to: false, in: discrepancy.implied)
        let stale = setting(.capsLock, to: false, in: discrepancy.stale)
        guard flags(implied, without: held) == implied,
          flags(stale, without: held) == ModifierState()
        else {
          Issue.record("implied overlaps the ledger or stale exceeds it at \(place)")
          return
        }
      }
    }
  }

  @Test func ledgersAreEquatableValuesThatCopyIndependently() {
    var first = ModifierStateLedger()
    var second = ModifierStateLedger()
    for event in serverSession.flatMap(serverChain) {
      #expect(first.apply(event) == second.apply(event))
      #expect(first == second)
    }
    #expect(first.apply(press(.command)).isEmpty)
    var copy = first
    #expect(copy == first)
    #expect(copy.apply(release(.command)).isEmpty)
    #expect(copy != first)
    #expect(first.state == modifiers(.command))
    #expect(copy.state == ModifierState())
  }

  @Test func ownersOnSeparateTasksAndACancelledTaskGetTheSameResults() async {
    let events = serverSession.flatMap(serverChain) + nonKeyEvents
    let expected = run(events)
    #expect(expected.contains { $0.state != ModifierState() })
    let results = await withTaskGroup(of: [Step].self) { group in
      for _ in 0..<8 {
        group.addTask { run(events) }
      }
      var collected: [[Step]] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }
    #expect(results.count == 8)
    #expect(results.allSatisfy { $0 == expected })
    // The ledger never suspends or checks for cancellation, so a cancelled owner gets the same
    // answer and the same final state to clear.
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return (Task.isCancelled, run(events))
    }
    let (wasCancelled, cancelled) = await task.value
    #expect(wasCancelled)
    #expect(cancelled == expected)
    // Compile-time: both types are Sendable values.
    requireSendable(ModifierStateLedger.self)
    requireSendable(ModifierDiscrepancy.self)
  }

  @Test func productionSourceImportsOnlyKVMContractsAndNeverLogs() throws {
    let code = try productionCode()
    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import KVMContracts"])
    // No logging or printing, no trap, no shared mutable state; and no `default` branch, so a
    // new catalog key fails to compile until it is classified as a held modifier or not.
    let forbidden = [
      "print(", "dump(", "Logger", "os_log", "NSLog", "fatalError(", "precondition", "assert",
      "static var", "nonisolated(unsafe)", "@unchecked", "Foundation", "default:",
    ]
    for word in forbidden {
      #expect(!code.contains { $0.contains(word) }, "production code mentions \(word)")
    }
  }
}

import Foundation
import KVMContracts
import KVMCore
import Testing

// The fixtures are the events the client session composes (M1-043 keys, M1-041 pairing): a
// paired repeat arrives as `.repeatKey`, Caps Lock arrives as a press and a release for each
// toggle, and a second press frame for a held button arrives as `.down` with the held identity.

// MARK: - Fixtures

private let none = ModifierState()
private let shifted = ModifierState(shift: true)

private func down(_ key: VirtualKey, _ modifiers: ModifierState = none) -> KVMEvent {
  .key(key: key, phase: .down, modifiers: modifiers)
}

private func up(_ key: VirtualKey, _ modifiers: ModifierState = none) -> KVMEvent {
  .key(key: key, phase: .up, modifiers: modifiers)
}

private func repeated(_ key: VirtualKey, _ modifiers: ModifierState = none) -> KVMEvent {
  .key(key: key, phase: .repeatKey, modifiers: modifiers)
}

private func press(_ button: MouseButton) -> KVMEvent {
  .mouseButton(button: button, phase: .down)
}

private func release(_ button: MouseButton) -> KVMEvent {
  .mouseButton(button: button, phase: .up)
}

private func clipboard(_ id: ClipboardTransactionID) -> KVMEvent {
  .clipboard(
    ClipboardPayload(
      transactionID: id, origin: .remote(DeviceID()), utf8Text: "secret text",
      contentHash: "hash"))
}

private let allButtons: [MouseButton] = [.left, .right, .middle, .auxiliary]

/// More distinct keys than the ledger's bound.
private let manyKeys: [VirtualKey] = {
  var keys: [VirtualKey] = (0..<26).map { VirtualKey.letter(UInt8($0)) }
  keys += (0..<10).map { VirtualKey.digit(UInt8($0)) }
  keys += (1...24).map { VirtualKey.function(UInt8($0)) }
  keys += PunctuationKey.allCases.map { VirtualKey.punctuation($0) }
  return keys
}()

/// A small deterministic generator, so the property test is reproducible.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Every value reachable from `value` through `Mirror`, the value itself included.
private func reachableValues(_ value: Any) -> [Any] {
  var result: [Any] = [value]
  for child in Mirror(reflecting: value).children {
    result += reachableValues(child.value)
  }
  return result
}

// MARK: - Key decisions

@Suite("InputStateLedger")
struct InputStateLedgerTests {
  @Test func aDownOfAnUnheldKeyIsInjectedAndHeld() {
    var ledger = InputStateLedger()
    #expect(ledger.record(down(.letter(0), shifted)) == .inject)
    #expect(ledger.heldKeys == [HeldKey(key: .letter(0), modifiers: shifted)])
  }

  @Test func aDuplicateDownOfAHeldKeyIsDropped() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.letter(0)))
    #expect(ledger.record(down(.letter(0))) == .dropDuplicateDown)
    #expect(ledger.record(down(.letter(0), shifted)) == .dropDuplicateDown)
    #expect(ledger.heldKeys == [HeldKey(key: .letter(0), modifiers: none)])
  }

  @Test func aRepeatOfAHeldKeyIsInjected() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.space))
    #expect(ledger.record(repeated(.space)) == .inject)
    #expect(ledger.heldKeys.map(\.key) == [.space])
  }

  @Test func aRepeatOfAnUnheldKeyIsDropped() {
    var ledger = InputStateLedger()
    #expect(ledger.record(repeated(.space)) == .dropUnheldRepeat)
    _ = ledger.record(down(.space))
    _ = ledger.record(up(.space))
    #expect(ledger.record(repeated(.space)) == .dropUnheldRepeat)
    #expect(ledger.heldKeys.isEmpty)
  }

  @Test func aReleaseOfAHeldKeyIsInjectedAndFreed() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.enter))
    _ = ledger.record(down(.tab))
    #expect(ledger.record(up(.enter)) == .inject)
    #expect(ledger.heldKeys.map(\.key) == [.tab])
    #expect(ledger.snapshot().heldKeyCount == 1)
  }

  @Test func aReleaseOfAnUnheldKeyIsInjectedButNotRecorded() {
    var ledger = InputStateLedger()
    #expect(ledger.record(up(.escape)) == .injectUnheldRelease)
    #expect(ledger.heldKeys.isEmpty)
    #expect(ledger.record(up(.escape)) == .injectUnheldRelease)
    #expect(ledger.record(down(.escape)) == .inject)
    #expect(ledger.heldKeys.map(\.key) == [.escape])
  }

  @Test func heldKeysKeepPressOrderAndTheModifiersAtThePress() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.shift))
    _ = ledger.record(down(.letter(2), shifted))
    _ = ledger.record(down(.digit(1), shifted))
    _ = ledger.record(down(.left, shifted))
    _ = ledger.record(up(.digit(1), shifted))
    _ = ledger.record(down(.digit(1), shifted))
    #expect(
      ledger.heldKeys == [
        HeldKey(key: .shift, modifiers: none),
        HeldKey(key: .letter(2), modifiers: shifted),
        HeldKey(key: .left, modifiers: shifted),
        HeldKey(key: .digit(1), modifiers: shifted),
      ])
  }

  @Test func capsLockIsAnOrdinaryHeldKey() {
    var ledger = InputStateLedger()
    #expect(ledger.record(down(.capsLock)) == .inject)
    #expect(ledger.heldKeys == [HeldKey(key: .capsLock, modifiers: none)])
    #expect(ledger.snapshot().heldKeyCount == 1)
    #expect(ledger.record(down(.capsLock)) == .dropDuplicateDown)
    #expect(ledger.record(up(.capsLock, ModifierState(capsLock: true))) == .inject)
    #expect(ledger.heldKeys.isEmpty)
    #expect(ledger.record(up(.capsLock)) == .injectUnheldRelease)
  }

  @Test func theModifierLedgerFollowsInjectedKeyEvents() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.shift))
    #expect(ledger.modifiers.state.shift)
    #expect(ledger.snapshot().modifiers.shift)
    _ = ledger.record(down(.shift))  // dropped: not applied
    _ = ledger.record(up(.shift, shifted))
    #expect(!ledger.modifiers.state.shift)
    _ = ledger.record(up(.control))  // an unheld release is still injected
    #expect(ledger.modifiers.state == none)
    // A dropped Caps Lock press does not reach the modifier ledger, so its lock bit is not taken.
    _ = ledger.record(down(.capsLock))
    #expect(ledger.record(down(.capsLock, ModifierState(capsLock: true))) == .dropDuplicateDown)
    #expect(!ledger.modifiers.state.capsLock)
  }

  // MARK: - Buttons

  @Test func buttonsFollowTheSameRules() {
    var ledger = InputStateLedger()
    #expect(ledger.record(press(.left)) == .inject)
    #expect(ledger.record(press(.left)) == .dropDuplicateDown)
    #expect(ledger.record(press(.right)) == .inject)
    #expect(ledger.heldButtons == [.left, .right])
    #expect(ledger.record(release(.middle)) == .injectUnheldRelease)
    #expect(ledger.record(release(.left)) == .inject)
    #expect(ledger.heldButtons == [.right])
    #expect(ledger.snapshot().heldButtonCount == 1)
  }

  @Test func aButtonReleaseFreesOnlyItsOwnButton() {
    for released in allButtons {
      var ledger = InputStateLedger()
      for button in allButtons { _ = ledger.record(press(button)) }
      #expect(ledger.record(release(released)) == .inject)
      #expect(ledger.heldButtons == allButtons.filter { $0 != released })
    }
  }

  // MARK: - Other events

  @Test func eventsWithoutHeldStateAreIgnored() {
    var ledger = InputStateLedger()
    let events: [KVMEvent] = [
      .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)), .scroll(deltaX: 0, deltaY: 120),
      .enterScreen(screen: ScreenID(), position: NormalizedPoint(x: 0, y: 0)),
      .leaveScreen(screen: ScreenID()),
    ]
    for event in events { #expect(ledger.record(event) == .ignore) }
    #expect(ledger.snapshot() == InputStateLedger().snapshot())
  }

  @Test func theClipboardTransactionIsTracked() {
    var ledger = InputStateLedger()
    #expect(ledger.snapshot().clipboardTransaction == nil)
    let first = ClipboardTransactionID()
    let second = ClipboardTransactionID()
    #expect(ledger.record(clipboard(first)) == .inject)
    #expect(ledger.snapshot().clipboardTransaction == first)
    #expect(ledger.record(clipboard(second)) == .inject)
    #expect(ledger.snapshot().clipboardTransaction == second)
    #expect(ledger.heldKeys.isEmpty && ledger.heldButtons.isEmpty)
  }

  // MARK: - Bounds

  @Test func keysOverTheBoundAreInjectedCountedAndFlagged() {
    #expect(InputStateLedger.maximumHeldKeys == 64)
    #expect(manyKeys.count > InputStateLedger.maximumHeldKeys)
    var ledger = InputStateLedger()
    for key in manyKeys.prefix(InputStateLedger.maximumHeldKeys) {
      #expect(ledger.record(down(key)) == .inject)
    }
    #expect(!ledger.snapshot().hasOverflowed)
    let extra = manyKeys[InputStateLedger.maximumHeldKeys]
    #expect(ledger.record(down(extra)) == .inject)
    #expect(ledger.heldKeys.count == InputStateLedger.maximumHeldKeys)
    #expect(!ledger.heldKeys.contains { $0.key == extra })
    let snapshot = ledger.snapshot()
    #expect(snapshot.heldKeyCount == InputStateLedger.maximumHeldKeys)
    #expect(snapshot.overflowedKeyCount == 1)
    #expect(snapshot.hasOverflowed)
    // The overflowed key's own release is still injected, as an unheld release.
    #expect(ledger.record(up(extra)) == .injectUnheldRelease)
    #expect(ledger.snapshot().overflowedKeyCount == 1)
  }

  @Test func buttonsOverTheBoundAreInjectedCountedAndFlagged() {
    #expect(InputStateLedger.maximumHeldButtons == 8)
    var ledger = InputStateLedger(maximumHeldKeys: 2, maximumHeldButtons: 2)
    #expect(ledger.record(press(.left)) == .inject)
    #expect(ledger.record(press(.right)) == .inject)
    #expect(ledger.record(press(.middle)) == .inject)
    #expect(ledger.heldButtons == [.left, .right])
    #expect(ledger.snapshot().overflowedButtonCount == 1)
    #expect(ledger.snapshot().hasOverflowed)
    // A freed slot is usable again.
    _ = ledger.record(release(.left))
    #expect(ledger.record(press(.middle)) == .inject)
    #expect(ledger.heldButtons == [.right, .middle])
  }

  @Test func smallBoundsAreEnforcedForKeys() {
    var ledger = InputStateLedger(maximumHeldKeys: 1, maximumHeldButtons: 1)
    #expect(ledger.record(down(.letter(0))) == .inject)
    #expect(ledger.record(down(.letter(1))) == .inject)
    #expect(ledger.heldKeys.map(\.key) == [.letter(0)])
    #expect(ledger.snapshot().overflowedKeyCount == 1)
    #expect(ledger.record(repeated(.letter(1))) == .dropUnheldRepeat)
  }

  // MARK: - Snapshot and reset

  @Test func theSnapshotCarriesNoKeyOrButtonIdentity() {
    var ledger = InputStateLedger()
    _ = ledger.record(down(.letter(7)))
    _ = ledger.record(down(.punctuation(.quote)))
    _ = ledger.record(press(.auxiliary))
    _ = ledger.record(clipboard(ClipboardTransactionID()))
    let snapshot = ledger.snapshot()
    #expect(snapshot.heldKeyCount == 2)
    #expect(snapshot.heldButtonCount == 1)
    for value in reachableValues(snapshot) {
      #expect(!(value is VirtualKey))
      #expect(!(value is MouseButton))
      #expect(!(value is HeldKey))
      #expect(!(value is PunctuationKey))
      #expect(!(value is String))
    }
    let labels = Mirror(reflecting: snapshot).children.compactMap(\.label)
    #expect(
      Set(labels) == [
        "heldKeyCount", "heldButtonCount", "overflowedKeyCount", "overflowedButtonCount",
        "modifiers", "clipboardTransaction",
      ])
  }

  @Test func resetForgetsEverything() {
    var ledger = InputStateLedger(maximumHeldKeys: 1, maximumHeldButtons: 1)
    _ = ledger.record(down(.shift))
    _ = ledger.record(down(.letter(0), shifted))
    _ = ledger.record(press(.left))
    _ = ledger.record(press(.right))
    _ = ledger.record(clipboard(ClipboardTransactionID()))
    ledger.reset()
    #expect(ledger.heldKeys.isEmpty)
    #expect(ledger.heldButtons.isEmpty)
    #expect(ledger.modifiers == ModifierStateLedger())
    #expect(ledger.snapshot() == InputStateLedger().snapshot())
    ledger.reset()
    #expect(ledger.snapshot() == InputStateLedger().snapshot())
    // The bounds survive a reset.
    _ = ledger.record(down(.letter(0)))
    _ = ledger.record(down(.letter(1)))
    #expect(ledger.snapshot().overflowedKeyCount == 1)
  }

  @Test func aNegativeOrZeroBoundHoldsNothing() {
    var ledger = InputStateLedger(maximumHeldKeys: -3, maximumHeldButtons: 0)
    #expect(ledger.record(down(.space)) == .inject)
    #expect(ledger.record(press(.left)) == .inject)
    #expect(ledger.heldKeys.isEmpty && ledger.heldButtons.isEmpty)
    #expect(ledger.snapshot().overflowedKeyCount == 1)
    #expect(ledger.snapshot().overflowedButtonCount == 1)
  }

  // MARK: - Property

  /// `heldKeys` equals, in press order, the keys with an injected down and no injected up since;
  /// no repeat is injected for a key the model does not hold.
  @Test(arguments: [UInt64(1), 2, 3, 42, 2026])
  func heldKeysMatchTheUnmatchedInjectedDowns(seed: UInt64) {
    var generator = SplitMix64(state: seed)
    let keys: [VirtualKey] = [.letter(0), .letter(1), .shift, .capsLock, .space, .digit(3)]
    var ledger = InputStateLedger(maximumHeldKeys: 4, maximumHeldButtons: 2)
    var model: [VirtualKey] = []
    var modelButtons: [MouseButton] = []
    for _ in 0..<2_000 {
      let roll = Int.random(in: 0..<10, using: &generator)
      if roll == 0 {
        ledger.reset()
        model = []
        modelButtons = []
        continue
      }
      if roll < 3 {
        let button = allButtons.randomElement(using: &generator)!
        let isDown = Bool.random(using: &generator)
        let held = modelButtons.contains(button)
        let decision = ledger.record(isDown ? press(button) : release(button))
        if isDown {
          #expect(decision == (held ? .dropDuplicateDown : .inject))
          if !held && modelButtons.count < 2 { modelButtons.append(button) }
        } else {
          #expect(decision == (held ? .inject : .injectUnheldRelease))
          modelButtons.removeAll { $0 == button }
        }
        #expect(ledger.heldButtons == modelButtons)
        continue
      }
      let key = keys.randomElement(using: &generator)!
      let phase = [KeyPhase.down, .up, .repeatKey].randomElement(using: &generator)!
      let held = model.contains(key)
      let decision = ledger.record(.key(key: key, phase: phase, modifiers: none))
      switch phase {
      case .down:
        #expect(decision == (held ? .dropDuplicateDown : .inject))
        if !held && model.count < 4 { model.append(key) }
      case .up:
        #expect(decision == (held ? .inject : .injectUnheldRelease))
        model.removeAll { $0 == key }
      case .repeatKey:
        #expect(decision == (held ? .inject : .dropUnheldRepeat))
      }
      #expect(ledger.heldKeys.map(\.key) == model)
      #expect(ledger.snapshot().heldKeyCount == model.count)
    }
  }
}

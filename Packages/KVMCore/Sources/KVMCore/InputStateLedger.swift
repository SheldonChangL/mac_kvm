// Input state ledger for the client role (M1-062). It decides, for each key, button and
// clipboard event the session hands the client, whether the event is injected, and records what
// those injections hold. The wire rules it relies on come from M1-PROTOCOL-003 as M1-041 and
// M1-043 compose them into KVMEvent; every rule below is first-party policy. It never logs.

import KVMContracts

/// A key the ledger holds, with the modifiers its press carried. A release built from it carries
/// the same modifiers, as the server releases its held keys.
package struct HeldKey: Equatable, Sendable {
  package let key: VirtualKey
  package let modifiers: ModifierState

  package init(key: VirtualKey, modifiers: ModifierState) {
    self.key = key
    self.modifiers = modifiers
  }
}

/// What the owner does with an event the ledger recorded.
package enum LedgerDecision: Equatable, Sendable {
  /// Inject the event.
  case inject
  /// Drop a press of a key or button the ledger already holds.
  case dropDuplicateDown
  /// Drop a repeat of a key the ledger does not hold (Frozen Decision 7: no unpaired repeat).
  case dropUnheldRepeat
  /// Inject a release of a key or button the ledger does not hold; nothing is recorded.
  case injectUnheldRelease
  /// The event holds no input state; the owner routes it as usual.
  case ignore
}

/// Counts and flags of the ledger's state. It never carries a key or button identity, typed
/// text or clipboard content (Frozen Decision 8), so it may be logged or reported.
package struct InputStateSnapshot: Equatable, Sendable {
  package let heldKeyCount: Int
  package let heldButtonCount: Int
  /// Keys pressed while the key bound was full and not released since. They are tracked in a
  /// separate overflow set, so their repeats and releases stay paired, but a release-all built
  /// from `heldKeys` does not include them.
  package let overflowedKeyCount: Int
  /// Buttons pressed while the button bound was full and not released since.
  package let overflowedButtonCount: Int
  /// Key presses injected while the overflow set was full too. Not tracked at all, so this count
  /// is sticky until `reset()`.
  package let untrackedKeyCount: Int
  /// Button presses injected while the button overflow set was full too; sticky until `reset()`.
  package let untrackedButtonCount: Int
  /// The modifier ledger's state.
  package let modifiers: ModifierState
  /// The last clipboard transaction recorded, an opaque identifier.
  package let clipboardTransaction: ClipboardTransactionID?

  /// True when a press was injected that the ledger does not hold, so a release-all built from
  /// the ledger may miss it and cleanup must report itself partial unless another sweep covers it.
  package var hasOverflowed: Bool {
    overflowedKeyCount > 0 || overflowedButtonCount > 0 || untrackedKeyCount > 0
      || untrackedButtonCount > 0
  }
}

/// The keys and buttons the client's injected presses hold, in press order, and the last
/// clipboard transaction.
///
/// First-party rules:
///
/// 1. A press of a key or button the ledger does not hold is injected and held. A press of one it
///    already holds is dropped as a duplicate, whatever its modifiers.
/// 2. A repeat of a held key is injected; a repeat of a key the ledger does not hold is dropped.
///    This is the second line behind the session, which drops unpaired repeats (M1-041).
/// 3. A release of a held key or button is injected and frees it. A release of one the ledger
///    does not hold is injected but not recorded: releasing an unpressed key leaves nothing stuck.
/// 4. Caps Lock is an ordinary key here: it arrives as a press and release per toggle (M1-043),
///    and is held between them. Buttons follow the same rules as keys.
/// 5. The bounds are checked before anything is stored. A press over the bound is still injected,
///    since dropping it would lose input, but it is not held: it goes into a separate overflow set
///    with the same bound, where its duplicate presses, repeats and release follow rules 1-3, and the
///    snapshot flags it. Its later release is an unheld release.
/// 6. A clipboard event is injected and its transaction ID remembered; no content is kept.
/// 7. Key events that are injected are applied to the modifier ledger (M1-046), in order; dropped
///    ones are not. Other events are ignored.
///
/// The ledger records decisions, not what the platform holds. A release it freed may still sit in
/// the injection queue when a terminal path resets that queue, so the release-all built from the
/// ledger is followed by the injector's own sweep (plan amendments h.1 and h.6).
///
/// The type is a `Sendable` value with no lock, clock, task or shared state. Its single owner, the
/// client coordinator behind its lock, serializes access, as for `ClipboardLoopGuard`.
package struct InputStateLedger: Sendable {
  /// The default bound on held keys.
  package static let maximumHeldKeys = 64
  /// The default bound on held buttons.
  package static let maximumHeldButtons = 8

  private let keyBound: Int
  private let buttonBound: Int
  package private(set) var heldKeys: [HeldKey] = []
  package private(set) var heldButtons: [MouseButton] = []
  package private(set) var modifiers = ModifierStateLedger()
  private var overflowedKeys: [VirtualKey] = []
  private var overflowedButtons: [MouseButton] = []
  private var untrackedKeys = 0
  private var untrackedButtons = 0
  private var clipboardTransaction: ClipboardTransactionID?

  /// Creates a ledger that holds nothing. A bound below zero is taken as zero.
  package init(
    maximumHeldKeys: Int = InputStateLedger.maximumHeldKeys,
    maximumHeldButtons: Int = InputStateLedger.maximumHeldButtons
  ) {
    keyBound = max(0, maximumHeldKeys)
    buttonBound = max(0, maximumHeldButtons)
  }

  /// Records one event and returns what to do with it.
  package mutating func record(_ event: KVMEvent) -> LedgerDecision {
    switch event {
    case .key(let key, let phase, let modifierState):
      let decision = recordKey(key, phase: phase, modifiers: modifierState)
      if decision == .inject || decision == .injectUnheldRelease {
        _ = modifiers.apply(event)
      }
      return decision
    case .mouseButton(let button, let phase):
      return recordButton(button, phase: phase)
    case .clipboard(let payload):
      clipboardTransaction = payload.transactionID
      return .inject
    case .mouseMove, .scroll, .enterScreen, .leaveScreen:
      return .ignore
    }
  }

  /// Counts and flags, without identities.
  package func snapshot() -> InputStateSnapshot {
    InputStateSnapshot(
      heldKeyCount: heldKeys.count,
      heldButtonCount: heldButtons.count,
      overflowedKeyCount: overflowedKeys.count,
      overflowedButtonCount: overflowedButtons.count,
      untrackedKeyCount: untrackedKeys,
      untrackedButtonCount: untrackedButtons,
      modifiers: modifiers.state,
      clipboardTransaction: clipboardTransaction)
  }

  /// Forgets every held key and button, the modifiers, the overflow counts and the clipboard
  /// transaction, after a release-all. The bounds stay. Calling it again does nothing.
  package mutating func reset() {
    heldKeys = []
    heldButtons = []
    modifiers.clear()
    overflowedKeys = []
    overflowedButtons = []
    untrackedKeys = 0
    untrackedButtons = 0
    clipboardTransaction = nil
  }

  private mutating func recordKey(
    _ key: VirtualKey, phase: KeyPhase, modifiers modifierState: ModifierState
  ) -> LedgerDecision {
    let index = heldKeys.firstIndex { $0.key == key }
    let overflowIndex = overflowedKeys.firstIndex(of: key)
    switch phase {
    case .down:
      guard index == nil, overflowIndex == nil else { return .dropDuplicateDown }
      if heldKeys.count < keyBound {
        heldKeys.append(HeldKey(key: key, modifiers: modifierState))
      } else if overflowedKeys.count < keyBound {
        overflowedKeys.append(key)
      } else {
        untrackedKeys += 1
      }
      return .inject
    case .repeatKey:
      return index == nil && overflowIndex == nil ? .dropUnheldRepeat : .inject
    case .up:
      if let index {
        heldKeys.remove(at: index)
        return .inject
      }
      guard let overflowIndex else { return .injectUnheldRelease }
      overflowedKeys.remove(at: overflowIndex)
      return .inject
    }
  }

  private mutating func recordButton(_ button: MouseButton, phase: ButtonPhase) -> LedgerDecision {
    let index = heldButtons.firstIndex(of: button)
    let overflowIndex = overflowedButtons.firstIndex(of: button)
    switch phase {
    case .down:
      guard index == nil, overflowIndex == nil else { return .dropDuplicateDown }
      if heldButtons.count < buttonBound {
        heldButtons.append(button)
      } else if overflowedButtons.count < buttonBound {
        overflowedButtons.append(button)
      } else {
        untrackedButtons += 1
      }
      return .inject
    case .up:
      if let index {
        heldButtons.remove(at: index)
        return .inject
      }
      guard let overflowIndex else { return .injectUnheldRelease }
      overflowedButtons.remove(at: overflowIndex)
      return .inject
    }
  }
}

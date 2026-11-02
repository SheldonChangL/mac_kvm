// Modifier state ledger for the client role (M1-046, contract C-006). It follows the key events
// the client injects and reports where a server's modifier mask disagrees with them. The wire
// rules it relies on come from M1-PROTOCOL-003 ("Keys") as M1-043 composes them into
// KVMEvent.key; every rule below that goes beyond them is first-party policy. It never logs.

import KVMContracts

/// The difference between the modifier state a key event reports and the ledger's state.
///
/// - `implied`: what the event reports held, or the lock it reports on, that the ledger does not
///   hold: a modifier already held on the server when the pointer entered this screen, a
///   modifier the ledger released at the first of two side releases, or a lock that was turned
///   on unseen.
/// - `stale`: what the ledger holds, or the lock it has on, that the event reports released or
///   off: a release that never arrived, or a lock that was turned off unseen.
///
/// A discrepancy is a report only: nothing is synthesized from it, and it never changes the
/// ledger (first-party policy; the Product Owner's V1 decision of 2026-11-02 for modifiers held
/// at enter).
package struct ModifierDiscrepancy: Equatable, Sendable {
  /// Reported held or on, not held by the ledger.
  package let implied: ModifierState
  /// Held or on in the ledger, reported released or off.
  package let stale: ModifierState

  package init(implied: ModifierState = ModifierState(), stale: ModifierState = ModifierState()) {
    self.implied = implied
    self.stale = stale
  }

  /// True when the report and the ledger agree on every field.
  package var isEmpty: Bool {
    implied == ModifierState() && stale == ModifierState()
  }
}

/// Which of Shift, Control, Option and Command the injected modifier keys hold, plus the lock
/// bit of the last key event (C-006: explicit state, never one event's flags alone).
///
/// First-party rules over the wire contract:
///
/// 1. A held modifier follows its key, not the mask: a press of Shift, Control, Option or
///    Command sets its flag, a release clears it and a repeat changes nothing. On the key's own
///    press the wire carries the mask before the key took effect, and on its own release the
///    mask including the key, so the key's own bit there is the opposite of the state after the
///    event.
/// 2. Left and right collapse. The catalog's modifier keys are side-agnostic (M1-042), so one
///    flag stands for both sides: any press sets it and any release clears it. The first release
///    on either side releases, which favours release over stuck input (M1-042 costs).
/// 3. The lock bit is taken from the key events, never derived from Caps Lock presses, and Caps
///    Lock is never a held modifier. A Caps Lock event's own frames, and the first other key
///    event after them, may carry a bit that its toggle changed, so their bit is taken as it is.
///    Any other change of the bit was not seen being made, such as a lock already on when the
///    pointer entered, and is reported once before it is taken.
/// 4. Every key event is reconciled with the ledger. On a modifier key's own press or release,
///    its own bit is replaced by the state the key gives before the comparison, because with the
///    sides collapsed the key cannot tell whether the other side is still held. The other bits
///    are compared as reported. The report changes nothing: an implied modifier is not adopted,
///    and a stale one stays held until its own release or `clear()`, so a release-all still
///    releases it.
/// 5. Events other than key events change nothing and report nothing. Leaving the screen and
///    disconnecting are the owner's `clear()`.
///
/// The ledger is consulted, not authoritative, for injection: it never injects, synthesizes,
/// drops or changes an event, and `state` must not drive releases, since its lock bit is a
/// report, not a held key. It is only as accurate as the events applied: its owner applies
/// exactly the key events the injector performs, in order, so a key the injector rejects is
/// never applied (M1-042 unknown-key policy). A release applied but then dropped before
/// injection would leave a modifier held on the client that the ledger no longer lists.
///
/// The type is a `Sendable` value with no lock, clock, task or shared state. Its single owner
/// serializes access, as for `ClipboardLoopGuard`.
package struct ModifierStateLedger: Equatable, Sendable {
  /// What the injected modifier keys hold, plus the lock bit of the last key event.
  package private(set) var state = ModifierState()

  /// Whether the last key event was a Caps Lock event, whose toggle may change the lock bit of
  /// the next key event.
  private var lockMayHaveToggled = false

  /// Creates a ledger that holds nothing.
  package init() {}

  /// Applies one event and returns the discrepancy between its modifiers and the ledger.
  package mutating func apply(_ event: KVMEvent) -> ModifierDiscrepancy {
    guard case .key(let key, let phase, let modifiers) = event else {
      return ModifierDiscrepancy()
    }
    var reported = modifiers
    if let modifier = HeldModifier(key) {
      switch phase {
      case .down:
        state[modifier] = true
        reported[modifier] = true
      case .up:
        state[modifier] = false
        reported[modifier] = false
      case .repeatKey:
        break
      }
    }
    let toggled = key == .capsLock || lockMayHaveToggled
    if toggled {
      state.capsLock = modifiers.capsLock
    }
    let discrepancy = reconcile(with: reported)
    state.capsLock = modifiers.capsLock
    lockMayHaveToggled = key == .capsLock
    return discrepancy
  }

  /// Compares a reported modifier state with the ledger, field by field, the lock bit with the
  /// bit of the last key event. The ledger is not changed.
  package func reconcile(with reported: ModifierState) -> ModifierDiscrepancy {
    ModifierDiscrepancy(
      implied: Self.flags(reported, without: state),
      stale: Self.flags(state, without: reported))
  }

  /// Forgets every modifier, the lock bit and a pending toggle, as on a disconnect. Calling it
  /// again does nothing.
  package mutating func clear() {
    state = ModifierState()
    lockMayHaveToggled = false
  }

  /// The flags set in `state` and clear in `other`.
  private static func flags(_ state: ModifierState, without other: ModifierState) -> ModifierState {
    ModifierState(
      shift: state.shift && !other.shift,
      control: state.control && !other.control,
      option: state.option && !other.option,
      command: state.command && !other.command,
      capsLock: state.capsLock && !other.capsLock)
  }
}

/// The four modifiers a key holds while it is pressed. Caps Lock is a lock, not one of them.
private enum HeldModifier {
  case shift
  case control
  case option
  case command

  /// The modifier `key` holds, or `nil`. The switch has no default branch, so a new catalog key
  /// fails to compile here until it is classified.
  init?(_ key: VirtualKey) {
    switch key {
    case .shift: self = .shift
    case .control: self = .control
    case .option: self = .option
    case .command: self = .command
    case .capsLock, .letter, .digit, .enter, .escape, .tab, .space, .backspace, .delete, .left,
      .right, .up, .down, .home, .end, .pageUp, .pageDown, .function, .volumeUp, .volumeDown,
      .mute, .punctuation, .unknown:
      return nil
    }
  }
}

extension ModifierState {
  /// The flag of a held modifier.
  fileprivate subscript(modifier: HeldModifier) -> Bool {
    get {
      switch modifier {
      case .shift: shift
      case .control: control
      case .option: option
      case .command: command
      }
    }
    set {
      switch modifier {
      case .shift: shift = newValue
      case .control: control = newValue
      case .option: option = newValue
      case .command: command = newValue
      }
    }
  }
}

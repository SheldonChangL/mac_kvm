// Barrier key identifier → C-005 VirtualKey mapper for the Barrier client role (M1-043). The
// identifiers come only from
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md, "Keys": the frozen set
// (BARRIER-EVID-0006-CLAIM-005, BARRIER-EVID-0008-CLAIM-001), whose capture-driver order fixes
// which identifier belongs to which key, and the 34 identifiers of the ADR's first-party
// shifted-identifier convention. The keys are C-005 catalog v2 members
// (docs/adr/M1-042-virtual-key-catalog.md). The mapper consumes BarrierKeyEvent from
// BarrierKeyboardDecoder (M1-041) and never logs.

import KVMContracts

/// Maps a Barrier key identifier to a C-005 `VirtualKey` (catalog v2) on the US ANSI layout of
/// the M2-022 capture, and composes the client session's `KVMEvent.key`.
///
/// - A letter, digit or punctuation identifier maps to its key position, plain or shifted:
///   0x0061 and 0x0041 are both the A key, 0x0031 and 0x0021 the 1 key, 0x002D and 0x005F the
///   minus key. Shift and Caps Lock travel in the event's modifiers.
/// - Left- and right-hand modifiers map to the side-agnostic member: Alt is `option`, Super is
///   `command`.
/// - Insert and keypad Enter are frozen identifiers without a catalog member. They, and every
///   identifier outside the contract, become `unknown` with the raw value zero-extended, which
///   a platform mapper rejects (M1-042 unknown-key policy).
///
/// The mapping is a total function over a fixed table: it never throws, holds no state and
/// owns no task or resource, so there is nothing to cancel or clean up.
enum BarrierVirtualKeyMapper {
  /// The C-005 `VirtualKey` catalog version the table covers.
  static let catalogVersion = 2

  /// The 100 frozen identifiers and the 34 convention identifiers.
  static let contractIdentifierCount = 134

  /// The catalog member for `identifier`, or `unknown` with its raw value zero-extended.
  static func virtualKey(for identifier: BarrierKeyIdentifier) -> VirtualKey {
    table[identifier.rawValue] ?? .unknown(UInt32(identifier.rawValue))
  }

  /// Whether `identifier` is one of the contract's 134 identifiers. Insert and keypad Enter
  /// are, although they map to `unknown`.
  static func isInContract(_ identifier: BarrierKeyIdentifier) -> Bool {
    table[identifier.rawValue] != nil
  }

  /// The client session's `KVMEvent.key`: the event's key, with its phase and modifiers
  /// unchanged. The button and the pairing stay in the protocol adapter.
  static func kvmEvent(for event: BarrierKeyEvent) -> KVMEvent {
    .key(key: virtualKey(for: event.identifier), phase: event.phase, modifiers: event.modifiers)
  }

  // MARK: - Table

  /// a–z (CLAIM-005).
  private static let lowercaseLetters: ClosedRange<UInt16> = 0x0061...0x007A
  /// A–Z, the letter with Shift or Caps Lock: 0x0041 is captured (CLAIM-005), 0x0042–0x005A
  /// are the ADR's first-party convention.
  private static let uppercaseLetters: ClosedRange<UInt16> = 0x0041...0x005A
  /// The main-row digits 0–9 (CLAIM-005).
  private static let digits: ClosedRange<UInt16> = 0x0030...0x0039
  /// The character Shift produces on each digit key 0–9 on the US ANSI layout: 0x0021 for 1 is
  /// captured (CLAIM-005), the other nine are the ADR's first-party convention.
  private static let shiftedDigits: [UInt16] = [
    0x0029, 0x0021, 0x0040, 0x0023, 0x0024, 0x0025, 0x005E, 0x0026, 0x002A, 0x0028,
  ]
  /// F1–F12 (CLAIM-005).
  private static let functionKeys: ClosedRange<UInt16> = 0xEFBE...0xEFC9
  /// The eleven punctuation keys, plain and with Shift (BARRIER-EVID-0008-CLAIM-001).
  private static let punctuation: [(plain: UInt16, shifted: UInt16, key: PunctuationKey)] = [
    (0x002D, 0x005F, .minus), (0x003D, 0x002B, .equal),
    (0x005B, 0x007B, .leftBracket), (0x005D, 0x007D, .rightBracket),
    (0x005C, 0x007C, .backslash), (0x003B, 0x003A, .semicolon),
    (0x0027, 0x0022, .quote), (0x0060, 0x007E, .grave),
    (0x002C, 0x003C, .comma), (0x002E, 0x003E, .period),
    (0x002F, 0x003F, .slash),
  ]
  /// The other frozen keys that have a catalog member (CLAIM-005). Left- and right-hand
  /// modifiers share the side-agnostic member.
  private static let namedKeys: [(identifier: UInt16, key: VirtualKey)] = [
    (0x0020, .space), (0xEF0D, .enter), (0xEF1B, .escape), (0xEF09, .tab),
    (0xEF08, .backspace), (0xEFFF, .delete), (0xEF51, .left), (0xEF52, .up),
    (0xEF53, .right), (0xEF54, .down), (0xEF50, .home), (0xEF57, .end),
    (0xEF55, .pageUp), (0xEF56, .pageDown), (0xE0AF, .volumeUp), (0xE0AE, .volumeDown),
    (0xE0AD, .mute), (0xEFE1, .shift), (0xEFE2, .shift), (0xEFE3, .control),
    (0xEFE4, .control), (0xEFE9, .option), (0xEFEA, .option), (0xEFEB, .command),
    (0xEFEC, .command), (0xEFE5, .capsLock),
  ]
  /// Frozen identifiers without a catalog v2 member: Insert and keypad Enter (CLAIM-005).
  private static let frozenNonMembers: [UInt16] = [0xEF63, 0xEF8D]

  /// Every contract identifier and its key, built once from the lists above.
  private static let table: [UInt16: VirtualKey] = {
    var table: [UInt16: VirtualKey] = [:]
    for (index, identifier) in lowercaseLetters.enumerated() {
      table[identifier] = .letter(UInt8(index))
    }
    for (index, identifier) in uppercaseLetters.enumerated() {
      table[identifier] = .letter(UInt8(index))
    }
    for (index, identifier) in digits.enumerated() {
      table[identifier] = .digit(UInt8(index))
    }
    for (index, identifier) in shiftedDigits.enumerated() {
      table[identifier] = .digit(UInt8(index))
    }
    for (index, identifier) in functionKeys.enumerated() {
      table[identifier] = .function(UInt8(index + 1))
    }
    for entry in punctuation {
      table[entry.plain] = .punctuation(entry.key)
      table[entry.shifted] = .punctuation(entry.key)
    }
    for entry in namedKeys {
      table[entry.identifier] = entry.key
    }
    for identifier in frozenNonMembers {
      table[identifier] = .unknown(UInt32(identifier))
    }
    return table
  }()
}

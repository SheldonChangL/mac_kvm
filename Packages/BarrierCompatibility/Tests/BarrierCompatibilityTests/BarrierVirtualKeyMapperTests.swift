// M1-043: Barrier key identifier → C-005 VirtualKey (catalog v2) mapper.
// Sources: BARRIER-EVID-0006-CLAIM-005 and BARRIER-EVID-0008-CLAIM-001 (the frozen identifiers,
// paired with keys by the capture drivers' order), the first-party shifted-identifier convention
// of docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md, and the C-005 catalog
// of docs/adr/M1-042-virtual-key-catalog.md. Expected keys are named catalog members taken from
// the capture drivers, the US ANSI characters and BarrierServerInputEncoder, never computed from
// an identifier's value (except `unknown`, which is the value zero-extended by definition): the
// table is checked against the wire in both directions, not against itself.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private typealias Mapper = BarrierVirtualKeyMapper

private let serverInputFixture = "m2-022-linux-server-input/server-input-capture.json"
private let punctuationFixture =
  "m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json"

private let dkdnToken: [UInt8] = [0x44, 0x4B, 0x44, 0x4E]
private let dkupToken: [UInt8] = [0x44, 0x4B, 0x55, 0x50]
private let dkrpToken: [UInt8] = [0x44, 0x4B, 0x52, 0x50]

/// The client screen of the capture: 1600 x 900 at the origin.
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

// MARK: - The capture drivers (evidence/e2e/M2-022/tools/)

private typealias Press = (identifier: UInt16, key: VirtualKey)

/// The contract test's `DRIVER_ORDER`
/// (Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py): the 78
/// single-key steps of `capture_server_input.py` in order, each with the identifier
/// BARRIER-EVID-0006-CLAIM-005 pairs with it and the catalog key the driver pressed. Insert and
/// keypad Enter have no catalog v2 member.
private let driverOrder: [(name: String, identifier: UInt16, key: VirtualKey)] = {
  var order: [(name: String, identifier: UInt16, key: VirtualKey)] = []
  for (index, letter) in "abcdefghijklmnopqrstuvwxyz".unicodeScalars.enumerated() {
    order.append((String(letter), UInt16(letter.value), .letter(UInt8(index))))
  }
  for digit in 0...9 {
    order.append((String(digit), 0x0030 + UInt16(digit), .digit(UInt8(digit))))
  }
  let editing: [(name: String, identifier: UInt16, key: VirtualKey)] = [
    ("Return", 0xEF0D, .enter), ("Escape", 0xEF1B, .escape), ("Tab", 0xEF09, .tab),
    ("space", 0x0020, .space), ("BackSpace", 0xEF08, .backspace), ("Delete", 0xEFFF, .delete),
    ("Left", 0xEF51, .left), ("Right", 0xEF53, .right), ("Up", 0xEF52, .up),
    ("Down", 0xEF54, .down), ("Home", 0xEF50, .home), ("End", 0xEF57, .end),
    ("Prior", 0xEF55, .pageUp), ("Next", 0xEF56, .pageDown), ("Insert", 0xEF63, .unknown(0xEF63)),
  ]
  order += editing
  for number in 1...12 {
    order.append(("F\(number)", 0xEFBD + UInt16(number), .function(UInt8(number))))
  }
  let punctuation: [(name: String, identifier: UInt16, key: VirtualKey)] = [
    ("minus", 0x002D, .punctuation(.minus)), ("equal", 0x003D, .punctuation(.equal)),
    ("bracketleft", 0x005B, .punctuation(.leftBracket)),
    ("bracketright", 0x005D, .punctuation(.rightBracket)),
    ("backslash", 0x005C, .punctuation(.backslash)),
    ("semicolon", 0x003B, .punctuation(.semicolon)),
    ("apostrophe", 0x0027, .punctuation(.quote)), ("grave", 0x0060, .punctuation(.grave)),
    ("comma", 0x002C, .punctuation(.comma)), ("period", 0x002E, .punctuation(.period)),
    ("slash", 0x002F, .punctuation(.slash)),
  ]
  order += punctuation
  let media: [(name: String, identifier: UInt16, key: VirtualKey)] = [
    ("KP_Enter", 0xEF8D, .unknown(0xEF8D)), ("XF86AudioRaiseVolume", 0xE0AF, .volumeUp),
    ("XF86AudioLowerVolume", 0xE0AE, .volumeDown), ("XF86AudioMute", 0xE0AD, .mute),
  ]
  order += media
  return order
}()

/// The steps of `capture_server_input.py` after `DRIVER_ORDER`, in order, with the identifier
/// and key of each press they make. xdotool presses Shift before the shifted key, and a
/// right-hand modifier with the left one already down (an input-tool artifact, ADR "Observed but
/// not frozen"). With Shift held and with Caps Lock on, `a` is 0x0041 (CLAIM-005).
private let serverInputDriverSteps: [(step: String, presses: [Press])] = [
  ("shift+a", [(0xEFE1, .shift), (0x0041, .letter(0))]),
  ("shift+1", [(0xEFE1, .shift), (0x0021, .digit(1))]),
  ("shift+minus", [(0xEFE1, .shift), (0x005F, .punctuation(.minus))]),
  ("ctrl+c", [(0xEFE3, .control), (0x0063, .letter(2))]),
  ("alt+a", [(0xEFE9, .option), (0x0061, .letter(0))]),
  ("super+a", [(0xEFEB, .command), (0x0061, .letter(0))]),
  ("ctrl+shift+Escape", [(0xEFE3, .control), (0xEFE1, .shift), (0xEF1B, .escape)]),
  ("Shift_L", [(0xEFE1, .shift)]), ("Control_L", [(0xEFE3, .control)]),
  ("Alt_L", [(0xEFE9, .option)]), ("Super_L", [(0xEFEB, .command)]),
  ("Shift_R", [(0xEFE1, .shift), (0xEFE2, .shift)]),
  ("Control_R", [(0xEFE3, .control), (0xEFE4, .control)]),
  ("Alt_R", [(0xEFE9, .option), (0xEFEA, .option)]),
  ("Super_R", [(0xEFEB, .command), (0xEFEC, .command)]),
  ("Caps_Lock", [(0xEFE5, .capsLock)]), ("caps-on a", [(0x0041, .letter(0))]),
  ("caps-off", [(0xEFE5, .capsLock)]), ("hold a", [(0x0061, .letter(0))]),
]

/// `capture_punctuation_clipboard.py`: for each key, `key <name>` and then `key shift+<name>`,
/// with the plain and shifted identifiers of BARRIER-EVID-0008-CLAIM-001.
private let punctuationDriverOrder:
  [(name: String, plain: UInt16, shifted: UInt16, key: PunctuationKey)] = [
    ("minus", 0x002D, 0x005F, .minus), ("equal", 0x003D, 0x002B, .equal),
    ("bracketleft", 0x005B, 0x007B, .leftBracket), ("bracketright", 0x005D, 0x007D, .rightBracket),
    ("backslash", 0x005C, 0x007C, .backslash), ("semicolon", 0x003B, 0x003A, .semicolon),
    ("apostrophe", 0x0027, 0x0022, .quote), ("grave", 0x0060, 0x007E, .grave),
    ("comma", 0x002C, 0x003C, .comma), ("period", 0x002E, 0x003E, .period),
    ("slash", 0x002F, 0x003F, .slash),
  ]

// MARK: - The contract's identifier sets

/// BARRIER-EVID-0006-CLAIM-005 and BARRIER-EVID-0008-CLAIM-001: the 100 frozen identifiers,
/// rebuilt exactly as `BarrierServerInputEncoderTests.identifiersStayInContract` does.
private let frozenIdentifiers: Set<UInt16> = {
  var frozen = Set<UInt16>(0x61...0x7A)
  frozen.formUnion(0x30...0x39)
  frozen.formUnion(0xEF51...0xEF54)
  frozen.formUnion(0xEFBE...0xEFC9)
  let listed: [UInt16] = [
    0x20, 0x41, 0x21, 0x2D, 0x3D, 0x5B, 0x5D, 0x5C, 0x3B, 0x27, 0x60, 0x2C, 0x2E, 0x2F, 0x5F,
    0x2B, 0x7B, 0x7D, 0x7C, 0x3A, 0x22, 0x7E, 0x3C, 0x3E, 0x3F, 0xEF0D, 0xEF1B, 0xEF09, 0xEF08,
    0xEFFF, 0xEF63, 0xEF50, 0xEF57, 0xEF55, 0xEF56, 0xEF8D, 0xE0AF, 0xE0AE, 0xE0AD, 0xEFE1,
    0xEFE2, 0xEFE3, 0xEFE4, 0xEFE9, 0xEFEA, 0xEFEB, 0xEFEC, 0xEFE5,
  ]
  frozen.formUnion(listed)
  return frozen
}()

/// The ADR's first-party convention: 0x0042–0x005A (B–Z) and the nine US shifted digits.
private let conventionIdentifiers: Set<UInt16> = {
  var convention = Set<UInt16>(0x42...0x5A)
  convention.formUnion([0x29, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28] as [UInt16])
  return convention
}()

// MARK: - Helpers

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// The server's `DKDN`, `DKUP` and `DKRP` payloads (length prefix removed) of an M2-022 capture
/// fixture, in observation order.
private func keyPayloads(_ fixture: String) throws -> [(sequence: Int, payload: [UInt8])] {
  let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var payloads: [(sequence: Int, payload: [UInt8])] = []
  var previous = 0
  for observation in observations {
    let sequence = try #require(observation["sequence"] as? Int)
    #expect(sequence > previous, "observations are in capture order")
    previous = sequence
    guard observation["direction"] as? String == "server-to-client" else { continue }
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    let bytes = payload([UInt8](try #require(Data(base64Encoded: base64))))
    if isKeyPayload(bytes) { payloads.append((sequence, bytes)) }
  }
  return payloads
}

/// The payload of a complete frame; the 4-byte big-endian length prefix is checked and removed.
private func payload(_ frame: [UInt8]) -> [UInt8] {
  let declared = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
  #expect(frame.count >= 4 && declared == frame.count - 4)
  return Array(frame.dropFirst(4))
}

/// The big-endian u16 at `offset` of a payload or frame.
private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
  UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func isKeyPayload(_ payload: [UInt8]) -> Bool {
  let token = Array(payload.prefix(4))
  return token == dkdnToken || token == dkupToken || token == dkrpToken
}

private func identifier(_ raw: UInt16) -> BarrierKeyIdentifier {
  BarrierKeyIdentifier(rawValue: raw)
}

private func mapped(_ raw: UInt16) -> VirtualKey {
  Mapper.virtualKey(for: BarrierKeyIdentifier(rawValue: raw))
}

/// The five frozen mask bits, read independently of the decoder.
private func frozenModifiers(_ mask: UInt16) -> ModifierState {
  ModifierState(
    shift: mask & 0x0001 != 0, control: mask & 0x0002 != 0, option: mask & 0x0004 != 0,
    command: mask & 0x0010 != 0, capsLock: mask & 0x1000 != 0)
}

/// The 32 combinations of the five modifier flags; bit `n` of the index sets flag `n` in the
/// order shift, control, option, command, Caps Lock.
private let allModifierStates: [ModifierState] = (0..<32).map { index in
  ModifierState(
    shift: index & 1 != 0, control: index & 2 != 0, option: index & 4 != 0,
    command: index & 8 != 0, capsLock: index & 16 != 0)
}

/// The states that choose which identifier the encoder sends for a key: none, Shift, Caps Lock,
/// and Shift with Caps Lock. The sweeps run all 32 states, which include these four.
private let identifierStates: [ModifierState] = [
  ModifierState(), ModifierState(shift: true), ModifierState(capsLock: true),
  ModifierState(shift: true, capsLock: true),
]

/// Exhaustive over `VirtualKey`: a new case stops this file compiling until it is given a branch
/// here. `VirtualKey` cannot be enumerated at run time, so a new payload-free case must also be
/// added by hand to `named` in `encodableKeys()` for the sweeps below to reach it.
private func keyCaseName(_ key: VirtualKey) -> String {
  switch key {
  case .letter: "letter"
  case .digit: "digit"
  case .function: "function"
  case .punctuation: "punctuation"
  case .unknown: "unknown"
  case .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home,
    .end, .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp,
    .volumeDown, .mute:
    "named"
  }
}

/// Every `VirtualKey` the first-party server encoder accepts: the whole payload domain of the
/// payload-carrying cases and every payload-free case, filtered by `canEncode`.
private func encodableKeys() -> [VirtualKey] {
  var candidates: [VirtualKey] = (0...255).map { VirtualKey.letter(UInt8($0)) }
  candidates += (0...255).map { VirtualKey.digit(UInt8($0)) }
  candidates += (0...255).map { VirtualKey.function(UInt8($0)) }
  candidates += PunctuationKey.allCases.map { VirtualKey.punctuation($0) }
  candidates += [.unknown(0), .unknown(0x61), .unknown(0xEF63), .unknown(UInt32.max)]
  let named: [VirtualKey] = [
    .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
    .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp, .volumeDown,
    .mute,
  ]
  candidates += named
  #expect(Set(candidates.map(keyCaseName)).count == 6)
  return candidates.filter(BarrierServerInputEncoder.canEncode)
}

/// `state` with `key`'s own bit inverted, for the four modifier keys; unchanged otherwise.
private func flippingOwnBit(of key: VirtualKey, in state: ModifierState) -> ModifierState {
  var flipped = state
  switch key {
  case .shift: flipped.shift.toggle()
  case .control: flipped.control.toggle()
  case .option: flipped.option.toggle()
  case .command: flipped.command.toggle()
  default: break
  }
  return flipped
}

private func withCapsLock(_ state: ModifierState, _ on: Bool) -> ModifierState {
  var changed = state
  changed.capsLock = on
  return changed
}

/// What one key event, as macOS capture reports it (`modifiers` is the state after the event),
/// becomes after `BarrierServerInputEncoder`, `BarrierKeyboardDecoder` and `kvmEvent(for:)`. It
/// is the event itself, except in two cases that cannot round-trip:
/// - A modifier key's own press and release carry the wire mask: the mask before the modifier
///   took effect on `DKDN`, the mask including it on `DKUP` (BARRIER-EVID-0006-CLAIM-006). The
///   encoder takes the state after the event, so the key's own bit comes back inverted. Its
///   repeat carries the mask unchanged.
/// - macOS reports Caps Lock once per toggle (`down` turns it on, `up` turns it off), so the
///   encoder sends each toggle as a whole press with its toggle masks, and nothing for a repeat.
private func documentedRoundTrip(
  _ key: VirtualKey, _ phase: KeyPhase, _ modifiers: ModifierState
) -> [KVMEvent] {
  if key == .capsLock {
    switch phase {
    case .down:
      return [
        .key(key: key, phase: .down, modifiers: withCapsLock(modifiers, false)),
        .key(key: key, phase: .up, modifiers: withCapsLock(modifiers, true)),
      ]
    case .up:
      return [
        .key(key: key, phase: .down, modifiers: withCapsLock(modifiers, true)),
        .key(key: key, phase: .up, modifiers: withCapsLock(modifiers, true)),
      ]
    case .repeatKey:
      return []
    }
  }
  let carried = phase == .repeatKey ? modifiers : flippingOwnBit(of: key, in: modifiers)
  return [.key(key: key, phase: phase, modifiers: carried)]
}

/// The key the capture driver pressed for each key payload, in order. Every `DKDN` must carry
/// the next press's identifier; every `DKUP` and `DKRP` takes the key of the press that holds
/// its button (the contract's pairing rule, applied here independently of the decoder).
private func driverKeys(
  for payloads: [(sequence: Int, payload: [UInt8])], presses: [Press]
) throws -> [VirtualKey] {
  var remaining = presses[...]
  var held: [UInt16: VirtualKey] = [:]
  var keys: [VirtualKey] = []
  for (sequence, payload) in payloads {
    let isRepeat = payload.starts(with: dkrpToken)
    let button = u16(payload, isRepeat ? 10 : 8)
    if payload.starts(with: dkdnToken) {
      let next = remaining.popFirst()
      let press = try #require(next, "seq \(sequence): an unexpected press")
      #expect(u16(payload, 4) == press.identifier, "seq \(sequence)")
      held[button] = press.key
      keys.append(press.key)
    } else {
      let key = try #require(held[button], "seq \(sequence): no press holds button \(button)")
      if !isRepeat { held[button] = nil }
      keys.append(key)
    }
  }
  #expect(remaining.isEmpty, "every driver press is on the wire")
  #expect(held.isEmpty, "every press is released")
  return keys
}

/// Each frame's own identifier maps to the driver's key, and so does the decoder's event, which
/// `kvmEvent(for:)` composes with the frame's phase and its five mask bits.
private func expectFixture(
  _ payloads: [(sequence: Int, payload: [UInt8])], mapsTo keys: [VirtualKey]
) throws {
  #expect(payloads.count == keys.count)
  var decoder = BarrierKeyboardDecoder()
  for ((sequence, payload), key) in zip(payloads, keys) {
    #expect(mapped(u16(payload, 4)) == key, "seq \(sequence)")
    let phase: KeyPhase =
      payload.starts(with: dkdnToken) ? .down : payload.starts(with: dkupToken) ? .up : .repeatKey
    let event = try decoder.decode(payload: payload, direction: .serverToClient)
    #expect(
      Mapper.kvmEvent(for: event)
        == .key(key: key, phase: phase, modifiers: frozenModifiers(u16(payload, 6))),
      "seq \(sequence)")
  }
  #expect(decoder.heldKeys.isEmpty)
  #expect(decoder.failure == nil)
}

// MARK: - Tests

@Suite("M1-043 Barrier virtual key mapper")
struct BarrierVirtualKeyMapperTests {
  @Test func catalogVersionIsTwoAndTheTableHas134Identifiers() {
    #expect(Mapper.catalogVersion == 2)
    #expect(Mapper.contractIdentifierCount == 134)
    let inContract = (UInt16.min...UInt16.max).filter { Mapper.isInContract(identifier($0)) }
    #expect(inContract.count == Mapper.contractIdentifierCount)
    // 132 identifiers map to a catalog member; Insert and keypad Enter map to unknown.
    let members = inContract.filter { raw in
      if case .unknown = mapped(raw) { return false }
      return true
    }
    #expect(members.count == 132)
  }

  @Test func contractIdentifiersEqualTheFrozenSetUnionTheConventionList() throws {
    #expect(frozenIdentifiers.count == 100)
    #expect(conventionIdentifiers.count == 34)
    #expect(frozenIdentifiers.isDisjoint(with: conventionIdentifiers))
    let inContract = Set((UInt16.min...UInt16.max).filter { Mapper.isInContract(identifier($0)) })
    #expect(inContract == frozenIdentifiers.union(conventionIdentifiers))
    for raw: UInt16 in [0x0000, 0x007F, 0xEF00, 0xFFFF] {
      #expect(!Mapper.isInContract(identifier(raw)), "identifier \(raw)")
    }
    // The frozen set is exactly what the two captures carry (the contract test's assertion).
    let captured = try keyPayloads(serverInputFixture) + keyPayloads(punctuationFixture)
    #expect(Set(captured.map { u16($0.payload, 4) }) == frozenIdentifiers)
  }

  @Test func serverInputCaptureKeysMapToTheKeysTheDriverPressedInOrder() throws {
    #expect(driverOrder.count == 78)
    let payloads = try keyPayloads(serverInputFixture)
    #expect(payloads.count == 232)
    // `DRIVER_ORDER` covers the first 78 presses; the combinations, the modifiers, Caps Lock and
    // the held `a` (14 repeats) follow.
    var presses: [Press] = driverOrder.map { (identifier: $0.identifier, key: $0.key) }
    presses += serverInputDriverSteps.flatMap(\.presses)
    #expect(presses.count == 109)
    let keys = try driverKeys(for: payloads, presses: presses)
    try expectFixture(payloads, mapsTo: keys)
  }

  @Test func punctuationCaptureKeysMapToTheKeysTheDriverPressedInOrder() throws {
    #expect(punctuationDriverOrder.count == 11)
    let payloads = try keyPayloads(punctuationFixture)
    #expect(payloads.count == 66)
    // `key <name>`, then `key shift+<name>`: Shift, then the shifted identifier.
    var presses: [Press] = []
    for entry in punctuationDriverOrder {
      presses.append((identifier: entry.plain, key: .punctuation(entry.key)))
      presses.append((identifier: 0xEFE1, key: .shift))
      presses.append((identifier: entry.shifted, key: .punctuation(entry.key)))
    }
    #expect(presses.count == 33)
    let keys = try driverKeys(for: payloads, presses: presses)
    try expectFixture(payloads, mapsTo: keys)
  }

  @Test func conventionIdentifiersMapToTheirLettersAndDigits() {
    // B–Z with Shift or Caps Lock: the produced character, 0x0042–0x005A, is the letter's key.
    for (offset, letter) in "BCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars.enumerated() {
      let raw = UInt16(letter.value)
      #expect(conventionIdentifiers.contains(raw))
      #expect(mapped(raw) == .letter(UInt8(offset + 1)), "\(letter)")
    }
    // The nine US shifted digits are the digit's key; 0x0021 for 1 is captured, not convention.
    let shiftedDigits: [(character: Character, raw: UInt16, key: VirtualKey)] = [
      (")", 0x0029, .digit(0)), ("@", 0x0040, .digit(2)), ("#", 0x0023, .digit(3)),
      ("$", 0x0024, .digit(4)), ("%", 0x0025, .digit(5)), ("^", 0x005E, .digit(6)),
      ("&", 0x0026, .digit(7)), ("*", 0x002A, .digit(8)), ("(", 0x0028, .digit(9)),
    ]
    for (character, raw, key) in shiftedDigits {
      #expect(character.asciiValue.map { UInt16($0) } == raw)
      #expect(conventionIdentifiers.contains(raw))
      #expect(mapped(raw) == key, "\(character)")
    }
    #expect(frozenIdentifiers.isSuperset(of: [0x0041, 0x0021]))
    #expect(mapped(0x0041) == .letter(0))
    #expect(mapped(0x0021) == .digit(1))
    #expect(conventionIdentifiers.allSatisfy { Mapper.isInContract(identifier($0)) })
  }

  @Test func shiftedIdentifiersMapToThePhysicalKeyOfTheirPlainPair() {
    // The US ANSI plain and shifted characters of every key whose character changes with Shift,
    // with the key each pair sits on, named independently of the mapper.
    let letters: [VirtualKey] = (0..<26).map { VirtualKey.letter(UInt8($0)) }
    let digits: [VirtualKey] = (0..<10).map { VirtualKey.digit(UInt8($0)) }
    let punctuation: [VirtualKey] = [
      .punctuation(.minus), .punctuation(.equal), .punctuation(.leftBracket),
      .punctuation(.rightBracket), .punctuation(.backslash), .punctuation(.semicolon),
      .punctuation(.quote), .punctuation(.grave), .punctuation(.comma), .punctuation(.period),
      .punctuation(.slash),
    ]
    let rows: [(plain: String, shifted: String, keys: [VirtualKey])] = [
      ("abcdefghijklmnopqrstuvwxyz", "ABCDEFGHIJKLMNOPQRSTUVWXYZ", letters),
      ("0123456789", ")!@#$%^&*(", digits), ("-=[]\\;'`,./", "_+{}|:\"~<>?", punctuation),
    ]
    var pairs: [(plain: UInt16, shifted: UInt16, key: VirtualKey)] = []
    for (plain, shifted, keys) in rows {
      let plainScalars = Array(plain.unicodeScalars)
      let shiftedScalars = Array(shifted.unicodeScalars)
      #expect(plainScalars.count == keys.count && shiftedScalars.count == keys.count)
      for (index, key) in keys.enumerated() {
        pairs.append(
          (UInt16(plainScalars[index].value), UInt16(shiftedScalars[index].value), key))
      }
    }
    #expect(pairs.count == 47)
    for (plain, shifted, key) in pairs {
      #expect(mapped(plain) == key, "identifier \(plain)")
      #expect(mapped(shifted) == key, "identifier \(shifted)")
    }
    // The captured shifted presses and their releases (CLAIM-004/005): A with Shift or Caps Lock
    // then a, ! then 1, _ then -. Each pair is one key position.
    let captured: [(shifted: UInt16, plain: UInt16, key: VirtualKey)] = [
      (0x0041, 0x0061, .letter(0)), (0x0021, 0x0031, .digit(1)),
      (0x005F, 0x002D, .punctuation(.minus)),
    ]
    for (shifted, plain, key) in captured {
      #expect(mapped(shifted) == key)
      #expect(mapped(plain) == key)
    }
    // Shift and Caps Lock travel in the modifiers: the composed event keeps them.
    for modifiers in [ModifierState(shift: true), ModifierState(capsLock: true)] {
      let event = BarrierKeyEvent(
        phase: .down, identifier: identifier(0x0041), modifiers: modifiers,
        button: BarrierKeyButton(rawValue: 38), pairing: .press)
      #expect(
        Mapper.kvmEvent(for: event) == .key(key: .letter(0), phase: .down, modifiers: modifiers))
    }
  }

  @Test func mapperIsTheInverseOfTheServerEncoderForEveryEncodableKey() throws {
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    var emitted = Set<UInt16>()
    var mismatches: [String] = []
    for key in encodableKeys() {
      for modifiers in allModifierStates {
        for phase in [KeyPhase.down, .up, .repeatKey] {
          // Frame layout: length 0...3, token 4...7, identifier 8...9.
          for frame in try encoder.key(key, phase: phase, modifiers: modifiers) {
            let raw = u16(frame, 8)
            emitted.insert(raw)
            if mapped(raw) != key { mismatches.append("\(key) \(phase) \(modifiers): \(raw)") }
          }
        }
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first \(mismatches.prefix(3))")
    // The encoder sends all 34 convention identifiers, and only contract identifiers.
    #expect(conventionIdentifiers.isSubset(of: emitted))
    #expect(emitted.allSatisfy { Mapper.isInContract(identifier($0)) })
    // It never sends Insert, keypad Enter or the right-hand modifiers.
    #expect(
      frozenIdentifiers.subtracting(emitted) == [0xEF63, 0xEF8D, 0xEFE2, 0xEFE4, 0xEFEA, 0xEFEC])
    #expect(emitted.count == 128)
  }

  @Test func encodeDecodeAndMapReturnTheKeyPhaseAndModifiersOfEveryEncodableKey() throws {
    let keys = encodableKeys()
    #expect(keys.count == 81)
    #expect(identifierStates.allSatisfy { allModifierStates.contains($0) })
    let encoder = BarrierServerInputEncoder(screen: captureScreen)
    // The four states send different identifiers for one key: b, B, B, b.
    let sent = try identifierStates.map {
      u16(try encoder.key(.letter(1), phase: .down, modifiers: $0)[0], 8)
    }
    #expect(sent == [0x0062, 0x0042, 0x0042, 0x0062])

    // One decoder for the whole sweep, as one client session uses.
    var decoder = BarrierKeyboardDecoder()
    func roundTrip(
      _ key: VirtualKey, _ phase: KeyPhase, _ modifiers: ModifierState
    ) throws -> [KVMEvent] {
      try encoder.key(key, phase: phase, modifiers: modifiers).map {
        Mapper.kvmEvent(for: try decoder.decode(payload: payload($0), direction: .serverToClient))
      }
    }
    var inexactKeys = Set<String>()
    var mismatches: [String] = []
    var leftHeld = 0
    for key in keys {
      for modifiers in allModifierStates {
        for phase in [KeyPhase.down, .repeatKey, .up] {
          let events = try roundTrip(key, phase, modifiers)
          if events == [.key(key: key, phase: phase, modifiers: modifiers)] { continue }
          inexactKeys.insert("\(key)")
          if events != documentedRoundTrip(key, phase, modifiers) {
            mismatches.append("\(key) \(phase) \(modifiers): \(events)")
          }
        }
        // Released under the other Shift state, the encoder may send another identifier
        // (A down, a up): the release still maps to the key.
        var released = modifiers
        released.shift.toggle()
        let pair = try roundTrip(key, .down, modifiers) + roundTrip(key, .up, released)
        let expected =
          documentedRoundTrip(key, .down, modifiers) + documentedRoundTrip(key, .up, released)
        if pair != expected { mismatches.append("\(key) \(modifiers) released \(released)") }
        if !decoder.heldKeys.isEmpty { leftHeld += 1 }
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first \(mismatches.prefix(3))")
    // Only the four modifier keys and Caps Lock differ from the original event, as documented;
    // the other 76 keys return their key, phase and modifiers exactly in all 32 states.
    #expect(inexactKeys == ["shift", "control", "option", "command", "capsLock"])
    #expect(leftHeld == 0)
    #expect(decoder.failure == nil)
  }

  @Test func kvmEventKeepsThePhaseAndModifiersAndIgnoresTheButtonAndPairing() {
    let cases: [Press] = [
      (0x0061, .letter(0)), (0x0041, .letter(0)), (0x005F, .punctuation(.minus)),
      (0xEFE2, .shift), (0xEFE5, .capsLock), (0xEF8D, .unknown(0xEF8D)),
      (0x1234, .unknown(0x1234)),
    ]
    var mismatches: [String] = []
    for (raw, key) in cases {
      for phase in [KeyPhase.down, .up, .repeatKey] {
        for modifiers in allModifierStates {
          for pairing in [BarrierKeyPairing.press, .paired, .unpaired] {
            // The button is the server's key code, an opaque pairing token: never a key.
            for button: UInt16 in [0, 38, raw, 0xFFFF] {
              let event = BarrierKeyEvent(
                phase: phase, identifier: identifier(raw), modifiers: modifiers,
                button: BarrierKeyButton(rawValue: button), pairing: pairing)
              if Mapper.kvmEvent(for: event) != .key(key: key, phase: phase, modifiers: modifiers) {
                mismatches.append("\(raw) \(phase) \(modifiers) \(pairing) \(button)")
              }
            }
          }
        }
      }
    }
    #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first \(mismatches.prefix(3))")
    let repeated = BarrierKeyEvent(
      phase: .repeatKey, identifier: identifier(0x0061),
      modifiers: ModifierState(control: true, capsLock: true),
      button: BarrierKeyButton(rawValue: 38), pairing: .paired)
    #expect(
      Mapper.kvmEvent(for: repeated)
        == .key(
          key: .letter(0), phase: .repeatKey,
          modifiers: ModifierState(control: true, capsLock: true)))
  }

  @Test func frozenNonMembersAndUnknownIdentifiersBecomeUnknownWithTheZeroExtendedRawValue() {
    // Insert and keypad Enter are frozen (CLAIM-005) but have no catalog v2 member.
    #expect(Mapper.isInContract(identifier(0xEF63)))
    #expect(Mapper.isInContract(identifier(0xEF8D)))
    #expect(mapped(0xEF63) == .unknown(0x0000_EF63))
    #expect(mapped(0xEF8D) == .unknown(0x0000_EF8D))
    // Outside the contract: the raw value zero-extended, never the nearest member.
    let outside: [UInt16] = [
      0x0000, 0x0001, 0x001F, 0x007F, 0x0080, 0x00FF, 0x0100, 0xE0AC, 0xE0B0, 0xEF00, 0xEF0A,
      0xEF62, 0xEF64, 0xEF8C, 0xEF8E, 0xEFBD, 0xEFCA, 0xEFE0, 0xEFE6, 0xEFED, 0xEFFE, 0xFFFF,
    ]
    for raw in outside {
      #expect(!Mapper.isInContract(identifier(raw)), "identifier \(raw)")
      #expect(mapped(raw) == .unknown(UInt32(raw)), "identifier \(raw)")
    }
    #expect(mapped(0xFFFF) == .unknown(0x0000_FFFF))
    // Every identifier outside the contract, all 65,402 of them.
    let contract = frozenIdentifiers.union(conventionIdentifiers)
    var outsideCount = 0
    var wrong: [UInt16] = []
    for raw in UInt16.min...UInt16.max where !contract.contains(raw) {
      outsideCount += 1
      if mapped(raw) != .unknown(UInt32(raw)) || Mapper.isInContract(identifier(raw)) {
        wrong.append(raw)
      }
    }
    #expect(outsideCount == 65_402)
    #expect(wrong.isEmpty, "\(wrong.count) wrong, first \(wrong.prefix(5))")
    // The composition keeps an unknown key: the session routes it and the platform mapper
    // rejects it (M1-042 unknown-key policy).
    let keypadEnter = BarrierKeyEvent(
      phase: .down, identifier: identifier(0xEF8D), modifiers: ModifierState(shift: true),
      button: BarrierKeyButton(rawValue: 104), pairing: .press)
    #expect(
      Mapper.kvmEvent(for: keypadEnter)
        == .key(key: .unknown(0xEF8D), phase: .down, modifiers: ModifierState(shift: true)))
  }

  /// The outputs where a raw-value shortcut would differ from the table. The structural half of
  /// "no raw-value shortcuts" is in `productionSourceImportsOnlyKVMContracts`.
  @Test func identifiersAtRawValueShortcutEdgesMapToTheirOwnKeys() {
    // Identifiers equal to a catalog payload (letter 0...25, digit 0...9, function 1...12,
    // PunctuationKey raw values 0...10) or to an ASCII control key are not keys.
    for raw in UInt16(0x0000)...0x001F {
      #expect(mapped(raw) == .unknown(UInt32(raw)), "identifier \(raw)")
    }
    // The ASCII neighbours of the digit and letter ranges are punctuation and shifted digits,
    // never digit 10... or letter 26...
    let neighbours: [Press] = [
      (0x002F, .punctuation(.slash)), (0x003A, .punctuation(.semicolon)),
      (0x003B, .punctuation(.semicolon)), (0x003C, .punctuation(.comma)),
      (0x003D, .punctuation(.equal)), (0x003E, .punctuation(.period)),
      (0x003F, .punctuation(.slash)), (0x0040, .digit(2)), (0x005B, .punctuation(.leftBracket)),
      (0x005C, .punctuation(.backslash)), (0x005D, .punctuation(.rightBracket)),
      (0x005E, .digit(6)), (0x005F, .punctuation(.minus)), (0x0060, .punctuation(.grave)),
      (0x007B, .punctuation(.leftBracket)), (0x007C, .punctuation(.backslash)),
      (0x007D, .punctuation(.rightBracket)), (0x007E, .punctuation(.grave)),
      (0x007F, .unknown(0x007F)),
    ]
    // F1 is 0xEFBE and F12 0xEFC9; no other value of the 0xEFxx page is a function key.
    let functionPage: [Press] = [
      (0xEF01, .unknown(0xEF01)), (0xEF0C, .unknown(0xEF0C)), (0xEFBD, .unknown(0xEFBD)),
      (0xEFBE, .function(1)), (0xEFC9, .function(12)), (0xEFCA, .unknown(0xEFCA)),
    ]
    for (raw, key) in neighbours + functionPage {
      #expect(mapped(raw) == key, "identifier \(raw)")
    }
    // Each punctuation key is reached only from its own plain and shifted identifiers
    // (BARRIER-EVID-0008-CLAIM-001), by name, not by PunctuationKey position.
    let named: [(key: PunctuationKey, identifiers: Set<UInt16>)] = [
      (.minus, [0x2D, 0x5F]), (.equal, [0x3D, 0x2B]), (.leftBracket, [0x5B, 0x7B]),
      (.rightBracket, [0x5D, 0x7D]), (.backslash, [0x5C, 0x7C]), (.semicolon, [0x3B, 0x3A]),
      (.quote, [0x27, 0x22]), (.grave, [0x60, 0x7E]), (.comma, [0x2C, 0x3C]),
      (.period, [0x2E, 0x3E]), (.slash, [0x2F, 0x3F]),
    ]
    #expect(named.count == PunctuationKey.allCases.count)
    for (key, identifiers) in named {
      let preimage = Set((UInt16.min...UInt16.max).filter { mapped($0) == .punctuation(key) })
      #expect(preimage == identifiers, "\(key)")
    }
  }

  @Test func everyTableValueStaysInsideItsCatalogDomain() {
    var image: [String: Int] = [:]
    var outOfDomain: [UInt16] = []
    var unknownContractRows: [UInt16] = []
    for raw in UInt16.min...UInt16.max {
      let key = mapped(raw)
      switch key {
      case .letter(let index) where index >= 26: outOfDomain.append(raw)
      case .digit(let value) where value >= 10: outOfDomain.append(raw)
      case .function(let number) where !(1...12).contains(number): outOfDomain.append(raw)
      case .unknown(let code):
        if code != UInt32(raw) { outOfDomain.append(raw) }
        if Mapper.isInContract(identifier(raw)) { unknownContractRows.append(raw) }
        continue
      default: break
      }
      image["\(key)", default: 0] += 1
    }
    #expect(outOfDomain.isEmpty, "first \(outOfDomain.prefix(5))")
    #expect(unknownContractRows == [0xEF63, 0xEF8D])
    // The 132 mapped identifiers reach exactly the 81 keys the first-party encoder accepts: two
    // identifiers per letter, digit and punctuation key (plain and shifted) and per modifier
    // (left and right), one for every other key.
    #expect(Set(image.keys) == Set(encodableKeys().map { "\($0)" }))
    #expect(image.values.reduce(0, +) == 132)
    let twice = Set(image.filter { $0.value == 2 }.keys)
    #expect(twice.count == 26 + 10 + 11 + 4)
    #expect(twice.isSuperset(of: ["shift", "control", "option", "command"]))
    #expect(image.values.allSatisfy { $0 == 1 || $0 == 2 })
  }

  @Test func mappingIsPureDeterministicAndConcurrencySafe() async {
    // A caseless enum: no instance, no stored state, no task or resource, so there is nothing
    // to cancel and nothing to clean up.
    #expect(MemoryLayout<BarrierVirtualKeyMapper>.size == 0)
    let identifiers = (UInt16.min...UInt16.max).map { BarrierKeyIdentifier(rawValue: $0) }
    let first = identifiers.map { Mapper.virtualKey(for: $0) }
    // An unknown identifier does not latch or poison a later call.
    _ = Mapper.virtualKey(for: BarrierKeyIdentifier(rawValue: 0xFFFF))
    #expect(identifiers.map { Mapper.virtualKey(for: $0) } == first)
    let results = await withTaskGroup(of: [VirtualKey].self) { group in
      for _ in 0..<8 {
        group.addTask { identifiers.map { Mapper.virtualKey(for: $0) } }
      }
      var collected: [[VirtualKey]] = []
      for await result in group { collected.append(result) }
      return collected
    }
    #expect(results.count == 8)
    #expect(results.allSatisfy { $0 == first })
    // A cancelled caller gets the same answer: the call has nothing to interrupt.
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return (Task.isCancelled, identifiers.map { Mapper.virtualKey(for: $0) })
    }
    let (wasCancelled, cancelled) = await task.value
    #expect(wasCancelled)
    #expect(cancelled == first)
  }

  @Test func productionSourceImportsOnlyKVMContracts() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierVirtualKeyMapper.swift"),
      encoding: .utf8)
    // Comments may name types across the boundary to document it; code lines may not.
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import KVMContracts"])
    #expect(!code.contains { $0.contains(" import ") })
    // No logging or printing, no trap that could carry an identifier into a crash report, and
    // no mutable or unchecked shared state: the mapper is a pure function over constants.
    let forbidden = [
      "KVMCore", "NativeProtocol", "Foundation", "print(", "Print(", "dump(", "Logger", "os_log",
      "NSLog", "fatalError(", "precondition", "assert", "static var", "nonisolated(unsafe)",
      "@unchecked",
    ]
    for word in forbidden {
      #expect(!code.contains { $0.contains(word) }, "production code mentions \(word)")
    }
    // Table-driven (the issue's scope): no switch, and no value built from a raw value by an
    // initializer.
    #expect(!code.contains { $0.hasPrefix("switch ") || $0.contains("case 0x") })
    #expect(!code.contains { $0.contains("(rawValue:") })
    // Every hexadecimal literal sits inside one of the named lists, so no key is decided by a
    // literal anywhere else (an if-chain or arithmetic over raw values).
    let lists = [
      "lowercaseLetters", "uppercaseLetters", "digits", "shiftedDigits", "functionKeys",
      "punctuation", "namedKeys", "frozenNonMembers",
    ]
    var declared = Set<String>()
    var insideList = false
    var strayLiterals: [String] = []
    for line in code {
      if let name = lists.first(where: { line.hasPrefix("private static let \($0):") }) {
        declared.insert(name)
        // A one-line declaration, such as a range, holds its literals on this line.
        insideList = line.hasSuffix("[")
        continue
      }
      if insideList {
        if line == "]" { insideList = false }
        continue
      }
      if line.contains("0x") { strayLiterals.append(line) }
    }
    #expect(declared == Set(lists))
    #expect(!insideList)
    #expect(strayLiterals.isEmpty, "literals outside the named lists: \(strayLiterals)")
  }
}

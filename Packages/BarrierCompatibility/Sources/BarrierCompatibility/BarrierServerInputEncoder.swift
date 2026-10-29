// Server-role pointer (M2-026) and keyboard (M2-027) encoder for the Barrier
// protocol adapter. Every layout, identifier and mask below was observed in the
// M2-022 black-box capture (evidence/e2e/M2-022/README.md,
// Tests/Fixtures/Barrier/m2-022-linux-server-input/); nothing is derived from
// upstream source. A key without an observed identifier is rejected, never
// guessed.

import KVMContracts

/// Typed encoder failure. Carries no key, coordinate or payload bytes.
enum BarrierServerInputEncoderError: Error, Equatable, Sendable {
  /// The key has no evidence-backed Barrier identifier: `unknown` keys,
  /// out-of-domain payloads and function keys above F12.
  case unsupportedKey
}

/// Encodes server-to-client input frames for one client screen.
///
/// Pointer positions become absolute client pixels inside the client's `DINF`
/// rectangle. Keys carry the character they produce on the US ANSI reference
/// layout with the current Shift and Caps Lock state, the Barrier modifier
/// mask, and a stable per-key `button` value used by the client to pair a
/// release with its press. The encoder is a pure value: no I/O, no state, no
/// logging.
struct BarrierServerInputEncoder: Sendable {
  let screen: BarrierScreenInfo

  // MARK: - Pointer

  /// `DMMV` at the client pixel nearest `position`, clamped to the client
  /// rectangle and to `0...0x7fff`, where signedness is unambiguous.
  func pointer(to position: NormalizedPoint) -> [UInt8] {
    let x = Self.pixel(position.x, origin: Int(screen.originX), extent: Int(screen.width))
    let y = Self.pixel(position.y, origin: Int(screen.originY), extent: Int(screen.height))
    return Self.frame("DMMV", Self.bigEndian(x) + Self.bigEndian(y))
  }

  /// `DMDN` or `DMUP` with the Barrier button identifier: left 1, middle 2,
  /// right 3, first auxiliary 4.
  func button(_ button: MouseButton, phase: ButtonPhase) -> [UInt8] {
    let identifier: UInt8 =
      switch button {
      case .left: 1
      case .middle: 2
      case .right: 3
      case .auxiliary: 4
      }
    return Self.frame(phase == .down ? "DMDN" : "DMUP", [identifier])
  }

  /// `DMWM` with 120 units per line, saturated to 16 bits, or `nil` when both
  /// deltas are zero. Positive `deltaY` scrolls up; positive `deltaX` scrolls
  /// left, so it is sent as a negative horizontal delta.
  func scroll(deltaX: Int32, deltaY: Int32) -> [UInt8]? {
    guard deltaX != 0 || deltaY != 0 else { return nil }
    let horizontal = Self.saturated(-Int64(deltaX) * Self.unitsPerLine)
    let vertical = Self.saturated(Int64(deltaY) * Self.unitsPerLine)
    return Self.frame("DMWM", Self.bigEndian(horizontal) + Self.bigEndian(vertical))
  }

  // MARK: - Keyboard

  /// Whether `key` has an evidence-backed Barrier identifier.
  static func canEncode(_ key: VirtualKey) -> Bool {
    entry(for: key) != nil
  }

  /// The frames for one key event, in order.
  ///
  /// `modifiers` is the state after the event, as capture reports it. A
  /// modifier key's own press carries the mask before it and its release the
  /// mask including it. macOS reports Caps Lock once per toggle, so each
  /// toggle sends a whole press (`DKDN` then `DKUP`); a Caps Lock repeat sends
  /// nothing.
  func key(_ key: VirtualKey, phase: KeyPhase, modifiers: ModifierState)
    throws(BarrierServerInputEncoderError) -> [[UInt8]]
  {
    guard let entry = Self.entry(for: key) else { throw .unsupportedKey }
    let mask = Self.mask(modifiers)
    if key == .capsLock {
      guard phase != .repeatKey else { return [] }
      let bit = Self.capsLockBit
      let downMask = phase == .down ? mask & ~bit : mask | bit
      return [
        Self.keyFrame("DKDN", entry.identifier, downMask, entry.button),
        Self.keyFrame("DKUP", entry.identifier, mask | bit, entry.button),
      ]
    }
    let identifier = Self.identifier(entry, key: key, modifiers: modifiers)
    switch phase {
    case .down:
      return [Self.keyFrame("DKDN", identifier, mask ^ entry.modifierBit, entry.button)]
    case .up:
      return [Self.keyFrame("DKUP", identifier, mask ^ entry.modifierBit, entry.button)]
    case .repeatKey:
      let body =
        Self.bigEndian(identifier) + Self.bigEndian(mask) + Self.bigEndian(UInt16(1))
        + Self.bigEndian(entry.button)
      return [Self.frame("DKRP", body)]
    }
  }

  // MARK: - Key table (M2-022 capture)

  private struct KeyEntry {
    let identifier: UInt16
    /// The identifier with Shift on the US ANSI reference layout, for keys
    /// whose produced character changes.
    let shifted: UInt16?
    let button: UInt16
    /// Set only for modifier keys: the mask bit the key itself controls.
    let modifierBit: UInt16
  }

  private static let capsLockBit: UInt16 = 0x1000
  private static let letterButtons: [UInt16] = [
    38, 56, 54, 40, 26, 41, 42, 43, 31, 44, 45, 46, 58, 57, 32, 33, 24, 27, 39, 28, 30, 55, 25, 53,
    29, 52,
  ]
  private static let digitButtons: [UInt16] = [19, 10, 11, 12, 13, 14, 15, 16, 17, 18]
  /// The character Shift produces on each digit key `0...9` (US ANSI).
  private static let shiftedDigits: [UInt16] = [
    0x29, 0x21, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28,
  ]
  private static let functionButtons: [UInt16] = [67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 95, 96]
  /// Punctuation in `PunctuationKey` order (catalog v2): the produced character
  /// without and with Shift on the US ANSI layout, and the captured button
  /// (M2-022 punctuation and clipboard addendum).
  private static let punctuation: [(plain: UInt16, shifted: UInt16, button: UInt16)] = [
    (0x2D, 0x5F, 20), (0x3D, 0x2B, 21), (0x5B, 0x7B, 34), (0x5D, 0x7D, 35), (0x5C, 0x7C, 51),
    (0x3B, 0x3A, 47), (0x27, 0x22, 48), (0x60, 0x7E, 49), (0x2C, 0x3C, 59), (0x2E, 0x3E, 60),
    (0x2F, 0x3F, 61),
  ]

  private static func entry(for key: VirtualKey) -> KeyEntry? {
    switch key {
    case .letter(let index):
      guard index < 26 else { return nil }
      let offset = UInt16(index)
      return KeyEntry(
        identifier: 0x61 + offset, shifted: 0x41 + offset, button: letterButtons[Int(index)],
        modifierBit: 0)
    case .digit(let value):
      guard value < 10 else { return nil }
      return KeyEntry(
        identifier: 0x30 + UInt16(value), shifted: shiftedDigits[Int(value)],
        button: digitButtons[Int(value)], modifierBit: 0)
    case .function(let number):
      guard (1...12).contains(number) else { return nil }
      return plain(0xEFBD + UInt16(number), functionButtons[Int(number) - 1])
    case .enter: return plain(0xEF0D, 36)
    case .escape: return plain(0xEF1B, 9)
    case .tab: return plain(0xEF09, 23)
    case .space: return plain(0x0020, 65)
    case .backspace: return plain(0xEF08, 22)
    case .delete: return plain(0xEFFF, 119)
    case .left: return plain(0xEF51, 113)
    case .right: return plain(0xEF53, 114)
    case .up: return plain(0xEF52, 111)
    case .down: return plain(0xEF54, 116)
    case .home: return plain(0xEF50, 110)
    case .end: return plain(0xEF57, 115)
    case .pageUp: return plain(0xEF55, 112)
    case .pageDown: return plain(0xEF56, 117)
    case .volumeUp: return plain(0xE0AF, 123)
    case .volumeDown: return plain(0xE0AE, 122)
    case .mute: return plain(0xE0AD, 121)
    case .shift: return modifier(0xEFE1, 50, bit: 0x0001)
    case .control: return modifier(0xEFE3, 37, bit: 0x0002)
    case .option: return modifier(0xEFE9, 64, bit: 0x0004)
    case .command: return modifier(0xEFEB, 133, bit: 0x0010)
    case .capsLock: return plain(0xEFE5, 66)
    case .punctuation(let key):
      let entry = punctuation[Int(key.rawValue)]
      return KeyEntry(
        identifier: entry.plain, shifted: entry.shifted, button: entry.button, modifierBit: 0)
    case .unknown: return nil
    }
  }

  private static func plain(_ identifier: UInt16, _ button: UInt16) -> KeyEntry {
    KeyEntry(identifier: identifier, shifted: nil, button: button, modifierBit: 0)
  }

  private static func modifier(_ identifier: UInt16, _ button: UInt16, bit: UInt16) -> KeyEntry {
    KeyEntry(identifier: identifier, shifted: nil, button: button, modifierBit: bit)
  }

  private static func identifier(
    _ entry: KeyEntry, key: VirtualKey, modifiers: ModifierState
  ) -> UInt16 {
    guard let shifted = entry.shifted else { return entry.identifier }
    let shift: Bool
    if case .letter = key {
      shift = modifiers.shift != modifiers.capsLock
    } else {
      shift = modifiers.shift
    }
    return shift ? shifted : entry.identifier
  }

  private static func mask(_ modifiers: ModifierState) -> UInt16 {
    var mask: UInt16 = 0
    if modifiers.shift { mask |= 0x0001 }
    if modifiers.control { mask |= 0x0002 }
    if modifiers.option { mask |= 0x0004 }
    if modifiers.command { mask |= 0x0010 }
    if modifiers.capsLock { mask |= capsLockBit }
    return mask
  }

  // MARK: - Framing

  private static let unitsPerLine: Int64 = 120

  private static func pixel(_ normalized: Double, origin: Int, extent: Int) -> UInt16 {
    let lowest = max(origin, 0)
    let highest = min(origin + max(extent, 1) - 1, 0x7FFF)
    let value = origin + Int((normalized * Double(max(extent - 1, 0))).rounded())
    return UInt16(min(max(value, lowest), max(highest, lowest)))
  }

  private static func saturated(_ value: Int64) -> UInt16 {
    UInt16(bitPattern: Int16(clamping: value))
  }

  private static func keyFrame(
    _ code: String, _ identifier: UInt16, _ mask: UInt16, _ button: UInt16
  ) -> [UInt8] {
    frame(code, bigEndian(identifier) + bigEndian(mask) + bigEndian(button))
  }

  private static func bigEndian(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
  }

  private static func frame(_ code: String, _ body: [UInt8]) -> [UInt8] {
    let payload = Array(code.utf8) + body
    let count = UInt32(payload.count)
    return [
      UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF),
      UInt8(count & 0xFF),
    ] + payload
  }
}

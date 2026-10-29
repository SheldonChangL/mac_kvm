// DKDN/DKUP/DKRP keyboard decoder for the Barrier client role (M1-041). Layouts, directions,
// the pairing rule and the modifier bits come only from
// docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md, "Keys"
// (BARRIER-EVID-0006-CLAIM-004/005/006, BARRIER-EVID-0008-CLAIM-001); the handling of counts,
// unknown identifiers and unknown mask bits is that ADR's first-party decoder policy. A
// release or repeat is paired with its press by the opaque button field and carries the
// press's identifier, and no release is ever dropped (Frozen Decision 7). Identifiers stay
// opaque: mapping them to keys is M1-043's. The decoder consumes complete payloads from
// BarrierFrameReassembler (M1-022) and never logs.

import KVMContracts

/// The key tokens M1-041 decodes. Names are the frozen ASCII tokens.
enum BarrierKeyboardToken: CaseIterable, Hashable, Sendable {
  case dkdn, dkup, dkrp

  static let byteCount = 4

  var bytes: [UInt8] {
    switch self {
    case .dkdn: Array("DKDN".utf8)
    case .dkup: Array("DKUP".utf8)
    case .dkrp: Array("DKRP".utf8)
    }
  }

  /// Frozen body length: identifier, mask and button; `DKRP` adds a count before the button.
  var bodyByteCount: Int {
    switch self {
    case .dkdn, .dkup: 6
    case .dkrp: 8
    }
  }

  var phase: KeyPhase {
    switch self {
    case .dkdn: .down
    case .dkup: .up
    case .dkrp: .repeatKey
    }
  }

  init?(payloadPrefix payload: [UInt8]) {
    guard
      let token = Self.allCases.first(where: {
        payload.prefix(Self.byteCount).elementsEqual($0.bytes)
      })
    else { return nil }
    self = token
  }
}

/// Typed fail-closed keyboard failure. Carries only allowlisted metadata (token, direction,
/// byte counts); never an identifier, mask, count, button or body byte.
enum BarrierKeyboardDecoderError: Error, Equatable, Sendable {
  /// The payload is shorter than a token or does not start with `DKDN`, `DKUP` or `DKRP`.
  case unknownToken(payloadByteCount: Int)
  /// The token arrived client-to-server; all three are server-to-client only.
  case unexpectedDirection(token: BarrierKeyboardToken, direction: BarrierControlDirection)
  /// The body is not exactly the frozen length (truncated or trailing bytes).
  case invalidBodyLength(token: BarrierKeyboardToken, bodyByteCount: Int)
}

/// Opaque Barrier key identifier (the wire u16). Its meaning is assigned only by M1-043.
struct BarrierKeyIdentifier: Hashable, Sendable {
  let rawValue: UInt16
}

/// Opaque pairing token (the server's key code). Never interpreted, never mapped.
struct BarrierKeyButton: Hashable, Comparable, Sendable {
  let rawValue: UInt16

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where an event's identifier came from.
enum BarrierKeyPairing: Equatable, Sendable {
  /// `DKDN`: this frame's identifier; the button is now held.
  case press
  /// `DKUP` or `DKRP` of a held button: the press's identifier.
  case paired
  /// `DKUP` or `DKRP` of a button that is not held: this frame's own identifier.
  case unpaired
}

/// One decoded key frame. An output, not a diagnostic: it carries wire values and is never
/// logged.
struct BarrierKeyEvent: Equatable, Sendable {
  let phase: KeyPhase
  let identifier: BarrierKeyIdentifier
  /// The five frozen mask bits; every other bit is ignored.
  let modifiers: ModifierState
  let button: BarrierKeyButton
  let pairing: BarrierKeyPairing
}

/// A held press. An output, not a diagnostic, like `BarrierKeyEvent`.
struct BarrierHeldKey: Equatable, Sendable {
  let button: BarrierKeyButton
  /// Identity of the press, used by its release.
  let identifier: BarrierKeyIdentifier
}

/// Decodes the key frames of one Barrier client session and pairs each release and repeat
/// with its press by button.
///
/// - `DKDN` holds the button with this frame's identifier. A press of a button that is
///   already held replaces the identity: the latest press wins.
/// - `DKUP` of a held button frees it and carries the press's identifier, which may differ
///   from the frame's own (0x0041 down, 0x0061 up). `DKUP` of a button that is not held is
///   still emitted, with its own identifier: a release is never dropped.
/// - `DKRP` carries the press's identifier when its button is held, else its own, and never
///   changes the held set. Its count is not read: any count is one repeat.
/// - The modifier state is the frame's five frozen mask bits. No lock state is kept and no
///   modifier event is synthesized from a mask.
/// - Identifiers pass through unchanged, known or not.
///
/// Exactly one event per frame. Failures are terminal and sticky: the first error is kept in
/// `failure` and every later payload rethrows it without changing anything, while `heldKeys`
/// stays readable so the session's cleanup can see what was held. A new session needs a new
/// decoder. There is no I/O, timer, task or resource, so there is nothing to cancel.
struct BarrierKeyboardDecoder: Sendable {
  static let shiftBit: UInt16 = 0x0001
  static let controlBit: UInt16 = 0x0002
  static let altBit: UInt16 = 0x0004
  static let superBit: UInt16 = 0x0010
  static let capsLockBit: UInt16 = 0x1000

  /// The identity of each held press, by button.
  private var held: [BarrierKeyButton: BarrierKeyIdentifier] = [:]

  /// The first fail-closed error; every later `decode` rethrows it.
  private(set) var failure: BarrierKeyboardDecoderError?

  /// Held presses in ascending button order. Readable after a failure.
  var heldKeys: [BarrierHeldKey] {
    held.map { BarrierHeldKey(button: $0.key, identifier: $0.value) }
      .sorted { $0.button < $1.button }
  }

  /// Checks, in order: a latched failure, the token, the direction and the body length; then
  /// pairs the frame by button.
  mutating func decode(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierKeyboardDecoderError) -> BarrierKeyEvent {
    if let failure { throw failure }
    do throws(BarrierKeyboardDecoderError) {
      return try decodeLive(payload: payload, direction: direction)
    } catch {
      failure = error
      throw error
    }
  }

  /// The five frozen bits as a `ModifierState`; every other bit is ignored. Alt is `option`
  /// and Super is `command`, as in the M1-042 catalog.
  static func modifiers(mask: UInt16) -> ModifierState {
    ModifierState(
      shift: mask & shiftBit != 0, control: mask & controlBit != 0, option: mask & altBit != 0,
      command: mask & superBit != 0, capsLock: mask & capsLockBit != 0)
  }

  private mutating func decodeLive(
    payload: [UInt8], direction: BarrierControlDirection
  ) throws(BarrierKeyboardDecoderError) -> BarrierKeyEvent {
    guard let token = BarrierKeyboardToken(payloadPrefix: payload) else {
      throw .unknownToken(payloadByteCount: payload.count)
    }
    guard direction == .serverToClient else {
      throw .unexpectedDirection(token: token, direction: direction)
    }
    let body = payload.dropFirst(BarrierKeyboardToken.byteCount)
    guard body.count == token.bodyByteCount else {
      throw .invalidBodyLength(token: token, bodyByteCount: body.count)
    }
    let identifier = BarrierKeyIdentifier(rawValue: Self.uint16(body, at: 0))
    let modifiers = Self.modifiers(mask: Self.uint16(body, at: 2))
    // The button is the last field. The DKRP count before it is never read.
    let button = BarrierKeyButton(rawValue: Self.uint16(body, at: token.bodyByteCount - 2))

    let press: BarrierKeyIdentifier?
    switch token {
    case .dkdn:
      held[button] = identifier
      return BarrierKeyEvent(
        phase: .down, identifier: identifier, modifiers: modifiers, button: button,
        pairing: .press)
    case .dkup:
      press = held.removeValue(forKey: button)
    case .dkrp:
      press = held[button]
    }
    return BarrierKeyEvent(
      phase: token.phase, identifier: press ?? identifier, modifiers: modifiers, button: button,
      pairing: press == nil ? .unpaired : .paired)
  }

  /// Big-endian 16-bit read; the caller has already checked the exact body length.
  private static func uint16(_ body: ArraySlice<UInt8>, at offset: Int) -> UInt16 {
    let index = body.startIndex + offset
    return UInt16(body[index]) << 8 | UInt16(body[index + 1])
  }
}

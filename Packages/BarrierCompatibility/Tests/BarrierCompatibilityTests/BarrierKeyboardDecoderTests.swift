// M1-041: Barrier DKDN/DKUP/DKRP keyboard decoder.
// Contract: docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md, "Keys"
// (BARRIER-EVID-0006-CLAIM-004/005/006, BARRIER-EVID-0008-CLAIM-001). Expected frames are read
// in observation order from the M2-022 capture fixtures, or produced by
// BarrierServerInputEncoder, whose key frames those fixtures pin byte for byte. The golden
// frames below are copied by hand and checked against the fixture bytes.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private typealias KeyboardError = BarrierKeyboardDecoderError

private let serverInputFixture = "m2-022-linux-server-input/server-input-capture.json"
private let punctuationFixture =
  "m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json"

/// Reassembler bound for the fixture stream; the largest server payload there is 18 bytes.
private let limit = 64

private let dkdnToken: [UInt8] = [0x44, 0x4B, 0x44, 0x4E]
private let dkupToken: [UInt8] = [0x44, 0x4B, 0x55, 0x50]
private let dkrpToken: [UInt8] = [0x44, 0x4B, 0x52, 0x50]

private let noModifiers = ModifierState()
private let shiftOnly = ModifierState(shift: true)
private let capsOnly = ModifierState(capsLock: true)

// MARK: - Golden frames (BARRIER-EVID-0006, server-input capture; observation sequence)

/// seq 80: `DKDN` a, mask 0, button 38.
private let aDownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0x00, 0x61, 0x00, 0x00, 0x00, 0x26,
]
/// seq 82: `DKUP` a, mask 0, button 38.
private let aUpFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x55, 0x50, 0x00, 0x61, 0x00, 0x00, 0x00, 0x26,
]
/// seq 404: `DKDN` Shift (0xEFE1), mask 0, button 50.
private let shiftDownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0xEF, 0xE1, 0x00, 0x00, 0x00, 0x32,
]
/// seq 406: `DKDN` A (0x0041), mask Shift, button 38.
private let shiftedADownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0x00, 0x41, 0x00, 0x01, 0x00, 0x26,
]
/// seq 408: `DKUP` Shift, mask Shift, button 50.
private let shiftUpFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x55, 0x50, 0xEF, 0xE1, 0x00, 0x01, 0x00, 0x32,
]
/// seq 410: `DKUP` a (0x0061), mask 0, button 38: the release of seq 406's A.
private let aUpAfterShiftFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x55, 0x50, 0x00, 0x61, 0x00, 0x00, 0x00, 0x26,
]
/// seq 425: `DKDN` _ (0x005F), mask Shift, button 20.
private let underscoreDownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0x00, 0x5F, 0x00, 0x01, 0x00, 0x14,
]
/// seq 515: `DKDN` Caps Lock (0xEFE5), mask 0, button 66: toggle-on press.
private let capsLockOnDownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0xEF, 0xE5, 0x00, 0x00, 0x00, 0x42,
]
/// seq 517: `DKUP` Caps Lock, mask Caps Lock, button 66: toggle-on release.
private let capsLockOnUpFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x55, 0x50, 0xEF, 0xE5, 0x10, 0x00, 0x00, 0x42,
]
/// seq 523: `DKDN` Caps Lock, mask Caps Lock, button 66: toggle-off press.
private let capsLockOffDownFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x44, 0x4E, 0xEF, 0xE5, 0x10, 0x00, 0x00, 0x42,
]
/// seq 525: `DKUP` Caps Lock, mask Caps Lock, button 66: toggle-off release.
private let capsLockOffUpFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0A, 0x44, 0x4B, 0x55, 0x50, 0xEF, 0xE5, 0x10, 0x00, 0x00, 0x42,
]
/// seq 532: `DKRP` a, mask 0, count 1, button 38.
private let aRepeatFrame: [UInt8] = [
  0x00, 0x00, 0x00, 0x0C, 0x44, 0x4B, 0x52, 0x50, 0x00, 0x61, 0x00, 0x00, 0x00, 0x01, 0x00,
  0x26,
]

// MARK: - Helpers

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// One M2-022 capture fixture, in observation order.
private struct Capture {
  let observations: [(sequence: Int, serverToClient: Bool, frame: [UInt8])]

  init(_ fixture: String) throws {
    let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
    let json = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let list = try #require(json["observations"] as? [[String: Any]])
    observations = try list.map { observation in
      let sequence = try #require(observation["sequence"] as? Int)
      let direction = try #require(observation["direction"] as? String)
      #expect(["server-to-client", "client-to-server"].contains(direction))
      let base64 = try #require(observation["applicationPayloadBase64"] as? String)
      let frame = [UInt8](try #require(Data(base64Encoded: base64)))
      return (sequence, direction == "server-to-client", frame)
    }
  }

  /// Complete frames in one direction, in observation order.
  func frames(direction: BarrierControlDirection) -> [[UInt8]] {
    observations.filter { $0.serverToClient == (direction == .serverToClient) }.map(\.frame)
  }

  /// The server's `DKDN`, `DKUP` and `DKRP` payloads (length prefix removed), in order.
  var serverKeyPayloads: [[UInt8]] {
    frames(direction: .serverToClient).map(payload).filter(isKeyPayload)
  }

  func frame(sequence: Int) throws -> [UInt8] {
    try #require(observations.first { $0.sequence == sequence }?.frame)
  }
}

/// The payload of a complete frame; the 4-byte big-endian length prefix is checked and removed.
private func payload(_ frame: [UInt8]) -> [UInt8] {
  let declared = frame.prefix(4).reduce(0) { $0 << 8 | Int($1) }
  #expect(frame.count >= 4 && declared == frame.count - 4)
  return Array(frame.dropFirst(4))
}

private func be16(_ value: UInt16) -> [UInt8] {
  [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

/// The big-endian u16 at `offset` of a payload or frame.
private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
  UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func isKeyPayload(_ payload: [UInt8]) -> Bool {
  let token = Array(payload.prefix(4))
  return token == dkdnToken || token == dkupToken || token == dkrpToken
}

private func dkdn(_ identifier: UInt16, mask: UInt16 = 0, button: UInt16) -> [UInt8] {
  dkdnToken + be16(identifier) + be16(mask) + be16(button)
}

private func dkup(_ identifier: UInt16, mask: UInt16 = 0, button: UInt16) -> [UInt8] {
  dkupToken + be16(identifier) + be16(mask) + be16(button)
}

private func dkrp(
  _ identifier: UInt16, mask: UInt16 = 0, count: UInt16 = 1, button: UInt16
) -> [UInt8] {
  dkrpToken + be16(identifier) + be16(mask) + be16(count) + be16(button)
}

private func event(
  _ phase: KeyPhase, _ identifier: UInt16, _ modifiers: ModifierState = noModifiers,
  button: UInt16, _ pairing: BarrierKeyPairing
) -> BarrierKeyEvent {
  BarrierKeyEvent(
    phase: phase, identifier: BarrierKeyIdentifier(rawValue: identifier), modifiers: modifiers,
    button: BarrierKeyButton(rawValue: button), pairing: pairing)
}

private func held(_ keys: [(button: UInt16, identifier: UInt16)]) -> [BarrierHeldKey] {
  keys.map {
    BarrierHeldKey(
      button: BarrierKeyButton(rawValue: $0.button),
      identifier: BarrierKeyIdentifier(rawValue: $0.identifier))
  }
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

/// The Swift twin of the contract test's pairing walk
/// (`test_key_frames_layout_identifiers_masks_and_pairing`): the event the contract and the
/// decoder policy require for each key payload in order, and the held keys before the first
/// payload and after each one. It reads the frozen offsets itself and keeps its own held map.
private func contractEvents(
  _ payloads: [[UInt8]]
) -> (events: [BarrierKeyEvent], heldAfter: [[BarrierHeldKey]]) {
  var pressed: [UInt16: UInt16] = [:]
  var events: [BarrierKeyEvent] = []
  var heldAfter: [[BarrierHeldKey]] = [[]]
  for payload in payloads {
    let token = Array(payload.prefix(4))
    let identifier = u16(payload, 4)
    let modifiers = frozenModifiers(u16(payload, 6))
    let button = u16(payload, token == dkrpToken ? 10 : 8)
    let press = pressed[button]
    let pairing: BarrierKeyPairing = press == nil ? .unpaired : .paired
    if token == dkdnToken {
      // A press of a held button keeps the first identity for the whole press.
      pressed[button] = press ?? identifier
      let pressPairing: BarrierKeyPairing = press == nil ? .press : .paired
      events.append(event(.down, press ?? identifier, modifiers, button: button, pressPairing))
    } else if token == dkupToken {
      pressed[button] = nil
      events.append(event(.up, press ?? identifier, modifiers, button: button, pairing))
    } else {
      events.append(event(.repeatKey, press ?? identifier, modifiers, button: button, pairing))
    }
    let sorted = pressed.sorted { $0.key < $1.key }
    heldAfter.append(held(sorted.map { (button: $0.key, identifier: $0.value) }))
  }
  return (events, heldAfter)
}

private func expectFailure(
  _ expected: KeyboardError, payload: [UInt8],
  direction: BarrierControlDirection = .serverToClient, decoder: inout BarrierKeyboardDecoder,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let heldBefore = decoder.heldKeys
  let latchedBefore = decoder.failure
  #expect(throws: expected, sourceLocation: sourceLocation) {
    _ = try decoder.decode(payload: payload, direction: direction)
  }
  #expect(decoder.failure == (latchedBefore ?? expected), sourceLocation: sourceLocation)
  #expect(decoder.heldKeys == heldBefore, sourceLocation: sourceLocation)
}

/// True when `value`, or any node reachable from it, is a string, a byte array, a key event
/// or held key, a key identifier, button or modifier state, a fixed-width integer (the shape of
/// a wire field) or a class instance. Only `Int` counts and payload-free enums pass.
private func reflectedGraphContainsSensitiveShape(_ value: Any) -> Bool {
  if value is String || value is [UInt8] || value is ArraySlice<UInt8> { return true }
  if value is BarrierKeyEvent || value is BarrierHeldKey || value is ModifierState { return true }
  if value is BarrierKeyIdentifier || value is BarrierKeyButton { return true }
  if value is UInt8 || value is Int8 || value is UInt16 || value is Int16 || value is UInt32
    || value is Int32 || value is UInt64 || value is Int64 || value is UInt
  {
    return true
  }
  let mirror = Mirror(reflecting: value)
  if mirror.displayStyle == .class { return true }
  return mirror.children.contains { reflectedGraphContainsSensitiveShape($0.value) }
}

private enum ErrorKind: CaseIterable {
  case unknownToken, unexpectedDirection, invalidBodyLength
}

/// Exhaustive over `BarrierKeyboardDecoderError`: a new case stops this file compiling until
/// `ErrorKind` lists it, and the privacy test then fails until it checks an instance of it.
private func errorKind(_ error: KeyboardError) -> ErrorKind {
  switch error {
  case .unknownToken: .unknownToken
  case .unexpectedDirection: .unexpectedDirection
  case .invalidBodyLength: .invalidBodyLength
  }
}

/// Exhaustive over `VirtualKey`: a new case stops this file compiling until the encoder round
/// trip below enumerates it.
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

/// The encoder's modifier state with `key`'s own bit flipped: a modifier key's press carries
/// the mask before it and its release the mask including it (encoder XOR rule).
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

/// Feeds `chunks` through a reassembler, routes key payloads to the decoder and ignores every
/// other token, as the client session will.
private func decodeKeyStream(
  _ chunks: [[UInt8]], decoder: inout BarrierKeyboardDecoder,
  reassembler: inout BarrierFrameReassembler
) throws -> [BarrierKeyEvent] {
  var events: [BarrierKeyEvent] = []
  for chunk in chunks {
    try reassembler.append(chunk)
    while let next = try reassembler.nextPayload() {
      if isKeyPayload(next) {
        events.append(try decoder.decode(payload: next, direction: .serverToClient))
      }
    }
  }
  return events
}

// MARK: - Tests

@Suite("M1-041 Barrier keyboard decoder")
struct BarrierKeyboardDecoderTests {
  @Test func tokenBytesBodyLengthsAndPhasesAreFrozen() {
    #expect(BarrierKeyboardToken.allCases == [.dkdn, .dkup, .dkrp])
    #expect(BarrierKeyboardToken.byteCount == 4)
    let frozen: [(BarrierKeyboardToken, [UInt8], Int, KeyPhase)] = [
      (.dkdn, dkdnToken, 6, .down), (.dkup, dkupToken, 6, .up), (.dkrp, dkrpToken, 8, .repeatKey),
    ]
    for (token, bytes, bodyByteCount, phase) in frozen {
      #expect(token.bytes == bytes)
      #expect(token.bodyByteCount == bodyByteCount)
      #expect(token.phase == phase)
      #expect(BarrierKeyboardToken(payloadPrefix: bytes) == token)
      #expect(BarrierKeyboardToken(payloadPrefix: bytes + [0x00, 0x61]) == token)
    }
    #expect(Array("DKDN".utf8) == dkdnToken)
    #expect(Array("DKUP".utf8) == dkupToken)
    #expect(Array("DKRP".utf8) == dkrpToken)
  }

  @Test func capturedKeyFramesDecodeInOrderAndLeaveNothingHeld() throws {
    let fixtures: [(String, downs: Int, ups: Int, repeats: Int)] = [
      (serverInputFixture, 109, 109, 14), (punctuationFixture, 33, 33, 0),
    ]
    for (fixture, downs, ups, repeats) in fixtures {
      let payloads = try Capture(fixture).serverKeyPayloads
      #expect(payloads.count == downs + ups + repeats, "\(fixture)")
      var decoder = BarrierKeyboardDecoder()
      var events: [BarrierKeyEvent] = []
      for payload in payloads {
        events.append(try decoder.decode(payload: payload, direction: .serverToClient))
      }
      #expect(events == contractEvents(payloads).events, "\(fixture)")
      #expect(events.filter { $0.phase == .down }.count == downs, "\(fixture)")
      #expect(events.filter { $0.phase == .up }.count == ups, "\(fixture)")
      #expect(events.filter { $0.phase == .repeatKey }.count == repeats, "\(fixture)")
      // Every release and repeat in both captures pairs with a press by button.
      #expect(events.allSatisfy { $0.pairing == ($0.phase == .down ? .press : .paired) })
      #expect(decoder.heldKeys.isEmpty, "\(fixture)")
      #expect(decoder.failure == nil, "\(fixture)")
    }
  }

  @Test func releaseUsesThePressIdentityByButton() throws {
    // Shift down, shifted key down, Shift up, then the key's up with the plain identifier.
    let capture = try Capture(serverInputFixture)
    let observed: [(sequences: [Int], shifted: UInt16, plain: UInt16, button: UInt16)] = [
      ([404, 406, 408, 410], 0x0041, 0x0061, 38), ([412, 414, 416, 418], 0x0021, 0x0031, 10),
      ([423, 425, 427, 429], 0x005F, 0x002D, 20),
    ]
    for (sequences, shifted, plain, button) in observed {
      let frames = try sequences.map { try capture.frame(sequence: $0) }
      // The release frame really carries the plain identifier, so the check below is not vacuous.
      #expect(u16(frames[3], 8) == plain)
      var decoder = BarrierKeyboardDecoder()
      let events = try frames.map {
        try decoder.decode(payload: payload($0), direction: .serverToClient)
      }
      #expect(
        events == [
          event(.down, 0xEFE1, button: 50, .press),
          event(.down, shifted, shiftOnly, button: button, .press),
          event(.up, 0xEFE1, shiftOnly, button: 50, .paired),
          event(.up, shifted, button: button, .paired),
        ], "seq \(sequences)")
      #expect(decoder.heldKeys.isEmpty)
    }

    // The eleven punctuation keys of BARRIER-EVID-0008, in the same four-frame order.
    let punctuation: [(plain: UInt16, shifted: UInt16, button: UInt16)] = [
      (0x2D, 0x5F, 20), (0x3D, 0x2B, 21), (0x5B, 0x7B, 34), (0x5D, 0x7D, 35), (0x5C, 0x7C, 51),
      (0x3B, 0x3A, 47), (0x27, 0x22, 48), (0x60, 0x7E, 49), (0x2C, 0x3C, 59), (0x2E, 0x3E, 60),
      (0x2F, 0x3F, 61),
    ]
    let keyPayloads = try Capture(punctuationFixture).serverKeyPayloads
    for (plain, shifted, button) in punctuation {
      let start = try #require(
        keyPayloads.firstIndex(of: dkdn(shifted, mask: 0x0001, button: button)))
      let sequence = Array(keyPayloads[(start - 1)...(start + 2)])
      #expect(
        sequence == [
          dkdn(0xEFE1, button: 50), dkdn(shifted, mask: 0x0001, button: button),
          dkup(0xEFE1, mask: 0x0001, button: 50), dkup(plain, button: button),
        ])
      var decoder = BarrierKeyboardDecoder()
      let events = try sequence.map { try decoder.decode(payload: $0, direction: .serverToClient) }
      #expect(
        events == [
          event(.down, 0xEFE1, button: 50, .press),
          event(.down, shifted, shiftOnly, button: button, .press),
          event(.up, 0xEFE1, shiftOnly, button: 50, .paired),
          event(.up, shifted, button: button, .paired),
        ], "punctuation \(plain)")
      #expect(decoder.heldKeys.isEmpty)
    }
  }

  @Test func repeatsUseThePressIdentityAndKeepTheHeldSet() throws {
    let capture = try Capture(serverInputFixture)
    var decoder = BarrierKeyboardDecoder()
    let press = try decoder.decode(
      payload: payload(try capture.frame(sequence: 530)), direction: .serverToClient)
    #expect(press == event(.down, 0x61, button: 38, .press))
    let repeats = Array(stride(from: 532, through: 558, by: 2))
    #expect(repeats.count == 14)
    for sequence in repeats {
      let repeated = try decoder.decode(
        payload: payload(try capture.frame(sequence: sequence)), direction: .serverToClient)
      #expect(repeated == event(.repeatKey, 0x61, button: 38, .paired), "seq \(sequence)")
      #expect(decoder.heldKeys == held([(38, 0x61)]))
    }
    let release = try decoder.decode(
      payload: payload(try capture.frame(sequence: 560)), direction: .serverToClient)
    #expect(release == event(.up, 0x61, button: 38, .paired))
    #expect(decoder.heldKeys.isEmpty)

    // Any count is one repeat: it carries the press identity and its own mask, the held set
    // is unchanged, and the next frame decodes as itself.
    for count: UInt16 in [0, 1, 2, 3, 0x7FFF, 0x8000, 0xFFFF] {
      var decoder = BarrierKeyboardDecoder()
      _ = try decoder.decode(
        payload: dkdn(0x41, mask: 0x0001, button: 38), direction: .serverToClient)
      let repeated = try decoder.decode(
        payload: dkrp(0x61, count: count, button: 38), direction: .serverToClient)
      #expect(repeated == event(.repeatKey, 0x41, button: 38, .paired), "count \(count)")
      #expect(decoder.heldKeys == held([(38, 0x41)]), "count \(count)")
      let release = try decoder.decode(
        payload: dkup(0x61, button: 38), direction: .serverToClient)
      #expect(release == event(.up, 0x41, button: 38, .paired), "count \(count)")
      #expect(decoder.heldKeys.isEmpty, "count \(count)")
    }
  }

  @Test func modifierMaskDecodesExactlyTheFiveFrozenBits() throws {
    #expect(BarrierKeyboardDecoder.shiftBit == 0x0001)
    #expect(BarrierKeyboardDecoder.controlBit == 0x0002)
    #expect(BarrierKeyboardDecoder.altBit == 0x0004)
    #expect(BarrierKeyboardDecoder.superBit == 0x0010)
    #expect(BarrierKeyboardDecoder.capsLockBit == 0x1000)

    let capture = try Capture(serverInputFixture)
    let observed: [(sequence: Int, modifiers: ModifierState)] = [
      (406, shiftOnly), (433, ModifierState(control: true)), (441, ModifierState(option: true)),
      (449, ModifierState(command: true)), (459, ModifierState(shift: true, control: true)),
      (519, capsOnly),
    ]
    for (sequence, modifiers) in observed {
      var decoder = BarrierKeyboardDecoder()
      let decoded = try decoder.decode(
        payload: payload(try capture.frame(sequence: sequence)), direction: .serverToClient)
      #expect(decoded.modifiers == modifiers, "seq \(sequence)")
    }

    let frozenBits: [UInt16] = [0x0001, 0x0002, 0x0004, 0x0010, 0x1000]
    let frozenMask = frozenBits.reduce(0, |)
    let unknownBits = (0..<16).map { UInt16(1) << $0 }.filter { $0 & frozenMask == 0 }
    #expect(unknownBits.count == 11)
    for (index, state) in allModifierStates.enumerated() {
      var mask: UInt16 = 0
      for (position, bit) in frozenBits.enumerated() where index & (1 << position) != 0 {
        mask |= bit
      }
      #expect(BarrierKeyboardDecoder.modifiers(mask: mask) == state, "mask \(mask)")
      for unknown in unknownBits {
        #expect(BarrierKeyboardDecoder.modifiers(mask: mask | unknown) == state, "bit \(unknown)")
      }
      #expect(BarrierKeyboardDecoder.modifiers(mask: mask | ~frozenMask) == state)
    }

    // A frame with unknown bits decodes to the event without them, in every phase.
    for extra: UInt16 in [0x0008, 0x0020, 0x2000, 0x8000, ~frozenMask] {
      var decoder = BarrierKeyboardDecoder()
      let down = try decoder.decode(
        payload: dkdn(0x61, mask: 0x0001 | extra, button: 38), direction: .serverToClient)
      let repeated = try decoder.decode(
        payload: dkrp(0x61, mask: extra, button: 38), direction: .serverToClient)
      let up = try decoder.decode(
        payload: dkup(0x61, mask: 0x1000 | extra, button: 38), direction: .serverToClient)
      #expect(down == event(.down, 0x61, shiftOnly, button: 38, .press), "extra \(extra)")
      #expect(repeated == event(.repeatKey, 0x61, button: 38, .paired), "extra \(extra)")
      #expect(up == event(.up, 0x61, capsOnly, button: 38, .paired), "extra \(extra)")
      #expect(decoder.heldKeys.isEmpty)
    }
  }

  @Test func modifierKeysCarryTheMaskBeforeOnDownAndIncludingOnUpAndNothingIsSynthesized()
    throws
  {
    let capture = try Capture(serverInputFixture)
    func decodeSequences(_ sequences: [Int]) throws -> ([BarrierKeyEvent], [BarrierHeldKey]) {
      var decoder = BarrierKeyboardDecoder()
      let events = try sequences.map {
        try decoder.decode(
          payload: payload(try capture.frame(sequence: $0)), direction: .serverToClient)
      }
      return (events, decoder.heldKeys)
    }

    // Left-hand modifiers alone: the press carries the mask before it, the release the mask
    // including it. One event per frame; the held set holds only the pressed button.
    let left: [(down: Int, up: Int, identifier: UInt16, button: UInt16, own: ModifierState)] = [
      (404, 408, 0xEFE1, 50, shiftOnly), (431, 435, 0xEFE3, 37, ModifierState(control: true)),
      (439, 443, 0xEFE9, 64, ModifierState(option: true)),
      (447, 451, 0xEFEB, 133, ModifierState(command: true)),
    ]
    for (down, up, identifier, button, own) in left {
      let (pressed, heldWhilePressed) = try decodeSequences([down])
      #expect(pressed == [event(.down, identifier, button: button, .press)], "seq \(down)")
      #expect(heldWhilePressed == held([(button, identifier)]))
      let (events, heldAfter) = try decodeSequences([down, up])
      #expect(
        events == [
          event(.down, identifier, button: button, .press),
          event(.up, identifier, own, button: button, .paired),
        ], "seq \(down)/\(up)")
      #expect(heldAfter.isEmpty)
    }

    // Right-hand modifiers were observed with the left one held (an input-tool artifact).
    let right:
      [(
        sequences: [Int], left: UInt16, leftButton: UInt16, right: UInt16,
        rightButton: UInt16, own: ModifierState
      )] = [
        ([483, 484, 487, 488], 0xEFE1, 50, 0xEFE2, 62, shiftOnly),
        ([491, 492, 495, 496], 0xEFE3, 37, 0xEFE4, 105, ModifierState(control: true)),
        ([499, 500, 503, 504], 0xEFE9, 64, 0xEFEA, 108, ModifierState(option: true)),
        ([507, 508, 511, 512], 0xEFEB, 133, 0xEFEC, 134, ModifierState(command: true)),
      ]
    for (sequences, leftKey, leftButton, rightKey, rightButton, own) in right {
      let (events, heldAfter) = try decodeSequences(sequences)
      #expect(
        events == [
          event(.down, leftKey, button: leftButton, .press),
          event(.down, rightKey, own, button: rightButton, .press),
          event(.up, leftKey, own, button: leftButton, .paired),
          event(.up, rightKey, own, button: rightButton, .paired),
        ], "seq \(sequences)")
      #expect(heldAfter.isEmpty)
    }

    // Caps Lock toggle-on (0x0000 then 0x1000), A under Caps Lock, toggle-off (0x1000 twice):
    // each frame decodes on its own mask; no lock state is kept.
    let (capsEvents, capsHeld) = try decodeSequences([515, 517, 519, 521, 523, 525])
    #expect(
      capsEvents == [
        event(.down, 0xEFE5, button: 66, .press), event(.up, 0xEFE5, capsOnly, button: 66, .paired),
        event(.down, 0x41, capsOnly, button: 38, .press),
        event(.up, 0x41, capsOnly, button: 38, .paired),
        event(.down, 0xEFE5, capsOnly, button: 66, .press),
        event(.up, 0xEFE5, capsOnly, button: 66, .paired),
      ])
    #expect(capsHeld.isEmpty)
    var lockless = BarrierKeyboardDecoder()
    for sequence in [515, 517] {
      _ = try lockless.decode(
        payload: payload(try capture.frame(sequence: sequence)), direction: .serverToClient)
    }
    #expect(
      try lockless.decode(payload: dkdn(0x61, button: 38), direction: .serverToClient)
        == event(.down, 0x61, button: 38, .press))

    // Nothing is synthesized from a mask: a shifted press seen without its Shift press holds
    // only its own button, and its release frees it.
    let (shifted, heldShifted) = try decodeSequences([406])
    #expect(shifted == [event(.down, 0x41, shiftOnly, button: 38, .press)])
    #expect(heldShifted == held([(38, 0x41)]))
    let (all, heldAll) = try decodeSequences([406, 410])
    #expect(all.count == 2)
    #expect(heldAll.isEmpty)
  }

  @Test func unpairedReleasesAndRepeatsAreEmittedWithTheirOwnIdentifier() throws {
    var decoder = BarrierKeyboardDecoder()
    // Nothing held: the release and the repeat are emitted with the frame's own identity.
    #expect(
      try decoder.decode(payload: dkup(0x61, button: 38), direction: .serverToClient)
        == event(.up, 0x61, button: 38, .unpaired))
    #expect(decoder.heldKeys.isEmpty)
    #expect(
      try decoder.decode(
        payload: dkrp(0x62, mask: 0x0001, count: 3, button: 56), direction: .serverToClient)
        == event(.repeatKey, 0x62, shiftOnly, button: 56, .unpaired))
    #expect(decoder.heldKeys.isEmpty)

    // Another button held: the unpaired release leaves it held.
    _ = try decoder.decode(payload: dkdn(0xEFE1, button: 50), direction: .serverToClient)
    #expect(
      try decoder.decode(payload: dkup(0x41, mask: 0x0001, button: 38), direction: .serverToClient)
        == event(.up, 0x41, shiftOnly, button: 38, .unpaired))
    #expect(decoder.heldKeys == held([(50, 0xEFE1)]))

    // The first release of button 50 pairs; a second one is unpaired and keeps its own
    // identifier.
    #expect(
      try decoder.decode(
        payload: dkup(0xEFE1, mask: 0x0001, button: 50), direction: .serverToClient)
        == event(.up, 0xEFE1, shiftOnly, button: 50, .paired))
    #expect(
      try decoder.decode(payload: dkup(0xEFE2, button: 50), direction: .serverToClient)
        == event(.up, 0xEFE2, button: 50, .unpaired))
    #expect(decoder.heldKeys.isEmpty)
    #expect(decoder.failure == nil)
  }

  @Test func releasePairsByButtonOnlyNeverByIdentifier() throws {
    // A repeat or release of a button that is not held is unpaired, even when another held
    // button carries the same identifier; that press stays held.
    var decoder = BarrierKeyboardDecoder()
    _ = try decoder.decode(payload: dkdn(0x61, button: 38), direction: .serverToClient)
    #expect(
      try decoder.decode(payload: dkrp(0x61, button: 56), direction: .serverToClient)
        == event(.repeatKey, 0x61, button: 56, .unpaired))
    #expect(
      try decoder.decode(payload: dkup(0x61, button: 56), direction: .serverToClient)
        == event(.up, 0x61, button: 56, .unpaired))
    #expect(decoder.heldKeys == held([(38, 0x61)]))

    // Two held buttons with the same identifier: a release frees its own button only.
    var twice = BarrierKeyboardDecoder()
    _ = try twice.decode(payload: dkdn(0x61, button: 38), direction: .serverToClient)
    _ = try twice.decode(payload: dkdn(0x61, button: 56), direction: .serverToClient)
    #expect(
      try twice.decode(payload: dkup(0x61, button: 56), direction: .serverToClient)
        == event(.up, 0x61, button: 56, .paired))
    #expect(twice.heldKeys == held([(38, 0x61)]))
  }

  @Test func secondPressOnAHeldButtonKeepsTheFirstIdentity() throws {
    var decoder = BarrierKeyboardDecoder()
    #expect(
      try decoder.decode(payload: dkdn(0x61, button: 38), direction: .serverToClient)
        == event(.down, 0x61, button: 38, .press))
    // While the button is held, another press keeps the first identity for the whole press: it
    // is emitted with the held identity, its own mask and the same button, and the held entry
    // is unchanged.
    #expect(
      try decoder.decode(payload: dkdn(0x41, mask: 0x0001, button: 38), direction: .serverToClient)
        == event(.down, 0x61, shiftOnly, button: 38, .paired))
    #expect(decoder.heldKeys == held([(38, 0x61)]))
    #expect(
      try decoder.decode(payload: dkdn(0xEFE1, button: 38), direction: .serverToClient)
        == event(.down, 0x61, button: 38, .paired))
    #expect(decoder.heldKeys == held([(38, 0x61)]))
    #expect(
      try decoder.decode(payload: dkrp(0x41, mask: 0x0001, button: 38), direction: .serverToClient)
        == event(.repeatKey, 0x61, shiftOnly, button: 38, .paired))
    // Every emitted press is matched by a release of the same identity.
    #expect(
      try decoder.decode(payload: dkup(0x41, button: 38), direction: .serverToClient)
        == event(.up, 0x61, button: 38, .paired))
    #expect(decoder.heldKeys.isEmpty)
    // Once released, the button takes a fresh press with that frame's own identity.
    #expect(
      try decoder.decode(payload: dkdn(0x41, mask: 0x0001, button: 38), direction: .serverToClient)
        == event(.down, 0x41, shiftOnly, button: 38, .press))
    #expect(decoder.heldKeys == held([(38, 0x41)]))
    #expect(
      try decoder.decode(payload: dkup(0x61, button: 38), direction: .serverToClient)
        == event(.up, 0x41, button: 38, .paired))
    #expect(
      try decoder.decode(payload: dkup(0x61, button: 38), direction: .serverToClient)
        == event(.up, 0x61, button: 38, .unpaired))
    #expect(decoder.heldKeys.isEmpty)
  }

  @Test func unknownIdentifiersAreRecordedAndReleasedCleanly() throws {
    // Identifiers outside the frozen set, with extreme buttons, masks and counts: no value
    // may make the decoder drop a release. The release carries yet another identifier.
    let cases: [(identifier: UInt16, button: UInt16)] = [
      (0x0000, 38), (0x1234, 0), (0xFFFF, 0xFFFF),
    ]
    for (identifier, button) in cases {
      var decoder = BarrierKeyboardDecoder()
      #expect(
        try decoder.decode(payload: dkdn(identifier, button: button), direction: .serverToClient)
          == event(.down, identifier, button: button, .press))
      #expect(decoder.heldKeys == held([(button, identifier)]))
      #expect(
        try decoder.decode(
          payload: dkrp(identifier, mask: 0xFFFF, count: 0xFFFF, button: button),
          direction: .serverToClient)
          == event(.repeatKey, identifier, frozenModifiers(0xFFFF), button: button, .paired))
      #expect(
        try decoder.decode(
          payload: dkup(identifier ^ 0x00FF, mask: 0xEFE8, button: button),
          direction: .serverToClient)
          == event(.up, identifier, button: button, .paired))
      #expect(decoder.heldKeys.isEmpty)
      #expect(decoder.failure == nil)
    }
  }

  @Test func roundTripThroughTheServerEncoderForEveryEncodableKey() throws {
    let keys = encodableKeys()
    #expect(keys.count == 81)
    let encoder = BarrierServerInputEncoder(
      screen: BarrierScreenInfo(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450))
    // One decoder for the whole sweep: every sequence must leave nothing held.
    var decoder = BarrierKeyboardDecoder()
    func decodeAll(_ frames: [[UInt8]]) throws -> [BarrierKeyEvent] {
      try frames.map { try decoder.decode(payload: payload($0), direction: .serverToClient) }
    }
    var buttons: [BarrierKeyButton] = []
    for key in keys {
      var keyButtons = Set<BarrierKeyButton>()
      for modifiers in allModifierStates {
        if key == .capsLock {
          // Each toggle is a whole press; a Caps Lock repeat sends nothing.
          #expect(try encoder.key(key, phase: .repeatKey, modifiers: modifiers).isEmpty)
          let on = try encoder.key(key, phase: .down, modifiers: modifiers)
          let off = try encoder.key(key, phase: .up, modifiers: modifiers)
          #expect(on.count == 2 && off.count == 2)
          let onEvents = try decodeAll(on)
          let offEvents = try decodeAll(off)
          let identifier = u16(on[0], 8)
          let button = u16(on[0], 12)
          #expect(
            onEvents == [
              event(.down, identifier, withCapsLock(modifiers, false), button: button, .press),
              event(.up, identifier, withCapsLock(modifiers, true), button: button, .paired),
            ], "\(key) \(modifiers)")
          #expect(
            offEvents == [
              event(.down, identifier, withCapsLock(modifiers, true), button: button, .press),
              event(.up, identifier, withCapsLock(modifiers, true), button: button, .paired),
            ], "\(key) \(modifiers)")
          keyButtons.formUnion((onEvents + offEvents).map(\.button))
          #expect(decoder.heldKeys.isEmpty)
          continue
        }
        let down = try encoder.key(key, phase: .down, modifiers: modifiers)
        let repeated = try encoder.key(key, phase: .repeatKey, modifiers: modifiers)
        let up = try encoder.key(key, phase: .up, modifiers: modifiers)
        #expect(down.count == 1 && repeated.count == 1 && up.count == 1)
        let events = try decodeAll(down + repeated + up)
        let pressed = try #require(events.first)
        // The decoder reads the identifier and button at their frozen offsets.
        #expect(pressed.identifier.rawValue == u16(down[0], 8))
        #expect(pressed.button.rawValue == u16(down[0], 12))
        #expect(u16(repeated[0], 14) == pressed.button.rawValue)
        let identifier = pressed.identifier.rawValue
        let button = pressed.button.rawValue
        let own = flippingOwnBit(of: key, in: modifiers)
        #expect(
          events == [
            event(.down, identifier, own, button: button, .press),
            event(.repeatKey, identifier, modifiers, button: button, .paired),
            event(.up, identifier, own, button: button, .paired),
          ], "\(key) \(modifiers)")
        #expect(decoder.heldKeys.isEmpty)

        // Released under another modifier state, the encoder may send another identifier
        // (A down, a up); the release still carries the press identity.
        var released = modifiers
        released.shift.toggle()
        let otherUp = try encoder.key(key, phase: .up, modifiers: released)
        let pair = try decodeAll(down + otherUp)
        #expect(
          pair[1]
            == event(
              .up, identifier, flippingOwnBit(of: key, in: released), button: button, .paired),
          "\(key) \(modifiers)")
        #expect(decoder.heldKeys.isEmpty)
        keyButtons.formUnion((events + pair).map(\.button))
      }
      // A key keeps one button in every state and phase, so pairing by button holds for it.
      #expect(keyButtons.count == 1, "\(key)")
      buttons += keyButtons
    }
    // No two encodable keys share a button.
    #expect(Set(buttons).count == keys.count)
    #expect(decoder.failure == nil)
  }

  @Test func goldenKeyFramesReEncodeByteForByte() throws {
    let capture = try Capture(serverInputFixture)
    let golden: [(sequence: Int, frame: [UInt8])] = [
      (80, aDownFrame), (82, aUpFrame), (404, shiftDownFrame), (406, shiftedADownFrame),
      (408, shiftUpFrame), (410, aUpAfterShiftFrame), (425, underscoreDownFrame),
      (515, capsLockOnDownFrame), (517, capsLockOnUpFrame), (523, capsLockOffDownFrame),
      (525, capsLockOffUpFrame), (532, aRepeatFrame),
    ]
    for (sequence, frame) in golden {
      #expect(try capture.frame(sequence: sequence) == frame, "seq \(sequence)")
    }

    // Decode each captured sequence, re-encode the key with the decoded phase and modifiers,
    // and compare whole frames. The encoder takes the state after the event, so a modifier
    // key's own bit is flipped back and a Caps Lock toggle takes its release's mask.
    let encoder = BarrierServerInputEncoder(
      screen: BarrierScreenInfo(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450))
    let sequences: [(key: VirtualKey, frames: [[UInt8]])] = [
      (.letter(0), [aDownFrame]), (.letter(0), [aUpFrame]), (.letter(0), [shiftedADownFrame]),
      (.letter(0), [aUpAfterShiftFrame]), (.letter(0), [aRepeatFrame]),
      (.punctuation(.minus), [underscoreDownFrame]), (.shift, [shiftDownFrame]),
      (.shift, [shiftUpFrame]), (.capsLock, [capsLockOnDownFrame, capsLockOnUpFrame]),
      (.capsLock, [capsLockOffDownFrame, capsLockOffUpFrame]),
    ]
    for (key, frames) in sequences {
      var decoder = BarrierKeyboardDecoder()
      let events = try frames.map {
        try decoder.decode(payload: payload($0), direction: .serverToClient)
      }
      // Each event's identifier is the frame's bytes at offset 8 and its button the frame's
      // last field: offset 12, or 14 in a DKRP frame.
      for (frame, decoded) in zip(frames, events) {
        #expect(decoded.identifier.rawValue == u16(frame, 8), "\(key)")
        #expect(decoded.button.rawValue == u16(frame, frame.count == 16 ? 14 : 12), "\(key)")
      }
      let first = try #require(events.first)
      let last = try #require(events.last)
      let reEncoded: [[UInt8]]
      if key == .capsLock {
        // A toggle-on press lacks the bit. The encoder takes the state after the toggle:
        // Caps Lock on after a toggle-on, off after a toggle-off.
        let turnedOn = !first.modifiers.capsLock
        reEncoded = try encoder.key(
          key, phase: turnedOn ? .down : .up, modifiers: withCapsLock(last.modifiers, turnedOn))
      } else {
        reEncoded = try encoder.key(
          key, phase: first.phase, modifiers: flippingOwnBit(of: key, in: first.modifiers))
      }
      #expect(reEncoded == frames, "\(key) \(events)")
    }
  }

  @Test func bodyLengthsAreExact() throws {
    let lengths: [(BarrierKeyboardToken, valid: Int, invalid: [Int])] = [
      (.dkdn, 6, [0, 1, 5, 7, 8, 9]), (.dkup, 6, [0, 1, 5, 7, 8, 9]),
      (.dkrp, 8, [0, 1, 6, 7, 9, 10]),
    ]
    for (token, valid, invalid) in lengths {
      for count in invalid {
        var decoder = BarrierKeyboardDecoder()
        expectFailure(
          .invalidBodyLength(token: token, bodyByteCount: count),
          payload: token.bytes + [UInt8](repeating: 0x26, count: count), decoder: &decoder)
      }
      var decoder = BarrierKeyboardDecoder()
      let decoded = try decoder.decode(
        payload: token.bytes + [UInt8](repeating: 0x00, count: valid), direction: .serverToClient)
      #expect(decoded.phase == token.phase)
      #expect(decoded.identifier == BarrierKeyIdentifier(rawValue: 0))
      #expect(decoded.button == BarrierKeyButton(rawValue: 0))
    }
  }

  @Test func clientToServerDirectionFailsClosed() {
    let valid: [(BarrierKeyboardToken, [UInt8])] = [
      (.dkdn, dkdn(0x61, button: 38)), (.dkup, dkup(0x61, button: 38)),
      (.dkrp, dkrp(0x61, button: 38)),
    ]
    for (token, payload) in valid {
      var decoder = BarrierKeyboardDecoder()
      expectFailure(
        .unexpectedDirection(token: token, direction: .clientToServer), payload: payload,
        direction: .clientToServer, decoder: &decoder)
      // The direction is checked before the body, so a malformed body cannot mask it.
      var bare = BarrierKeyboardDecoder()
      expectFailure(
        .unexpectedDirection(token: token, direction: .clientToServer), payload: token.bytes,
        direction: .clientToServer, decoder: &bare)
    }
  }

  @Test func unknownAndShortTokensFailClosed() {
    let unknown: [[UInt8]] = [
      Array("DKXX".utf8) + [0x00, 0x61, 0x00, 0x00, 0x00, 0x26],
      Array("dkdn".utf8) + [0x00, 0x61, 0x00, 0x00, 0x00, 0x26],  // tokens are case-sensitive
      Array("DMMV".utf8) + [0x00, 0x0A, 0x01, 0xC2],  // another decoder's token
      Array("CINN".utf8) + [UInt8](repeating: 0, count: 10),
      Array("DK".utf8), Array("DKD".utf8), [],
    ]
    for payload in unknown {
      for direction in [BarrierControlDirection.serverToClient, .clientToServer] {
        var decoder = BarrierKeyboardDecoder()
        expectFailure(
          .unknownToken(payloadByteCount: payload.count), payload: payload, direction: direction,
          decoder: &decoder)
      }
    }
  }

  @Test func failureIsStickyAndHeldKeysSurviveIt() throws {
    let failures: [(payload: [UInt8], direction: BarrierControlDirection, error: KeyboardError)] =
      [
        (
          dkdnToken + [0x00, 0x62, 0x00, 0x00, 0x00], .serverToClient,
          .invalidBodyLength(token: .dkdn, bodyByteCount: 5)
        ),
        (
          dkup(0x61, button: 38), .clientToServer,
          .unexpectedDirection(token: .dkup, direction: .clientToServer)
        ),
        (Array("DKXX".utf8), .serverToClient, .unknownToken(payloadByteCount: 4)),
      ]
    for (badPayload, badDirection, error) in failures {
      var decoder = BarrierKeyboardDecoder()
      _ = try decoder.decode(payload: dkdn(0x61, button: 38), direction: .serverToClient)
      _ = try decoder.decode(payload: dkdn(0xEFE1, button: 50), direction: .serverToClient)
      let heldBeforeFailure = held([(38, 0x61), (50, 0xEFE1)])
      #expect(decoder.heldKeys == heldBeforeFailure)
      #expect(decoder.failure == nil)

      expectFailure(error, payload: badPayload, direction: badDirection, decoder: &decoder)
      #expect(decoder.failure == error)
      #expect(decoder.heldKeys == heldBeforeFailure)

      // Every later frame, valid or not and including the held keys' releases, rethrows the
      // latched error and changes nothing: the cleanup path can still read what was held. The
      // latch is checked before the token, so even an unknown or empty payload rethrows it.
      let later: [([UInt8], BarrierControlDirection)] = [
        (dkup(0x61, button: 38), .serverToClient),
        (dkup(0xEFE1, mask: 0x0001, button: 50), .serverToClient),
        (dkdn(0x62, button: 56), .serverToClient), (dkrp(0x61, button: 38), .serverToClient),
        (dkdnToken, .serverToClient), (dkdn(0x63, button: 54), .clientToServer),
        (Array("DKXX".utf8), .serverToClient), ([], .clientToServer),
      ]
      for (payload, direction) in later {
        expectFailure(error, payload: payload, direction: direction, decoder: &decoder)
      }
      #expect(decoder.failure == error)
      #expect(decoder.heldKeys == heldBeforeFailure)
    }
  }

  @Test func heldKeysAreSortedByButtonAndFreshDecodersAreIndependent() throws {
    let fresh = BarrierKeyboardDecoder()
    #expect(fresh.heldKeys.isEmpty)
    #expect(fresh.failure == nil)
    #expect(BarrierKeyButton(rawValue: 9) < BarrierKeyButton(rawValue: 38))
    #expect(!(BarrierKeyButton(rawValue: 38) < BarrierKeyButton(rawValue: 38)))

    let presses: [(button: UInt16, identifier: UInt16)] = [
      (133, 0xEFEB), (9, 0xEF1B), (0xFFFF, 0x1234), (50, 0xEFE1), (0, 0x0000), (38, 0x61),
    ]
    func pressAll() throws -> BarrierKeyboardDecoder {
      var decoder = BarrierKeyboardDecoder()
      for (button, identifier) in presses {
        _ = try decoder.decode(
          payload: dkdn(identifier, button: button), direction: .serverToClient)
      }
      return decoder
    }
    var decoder = try pressAll()
    let sorted = held([
      (0, 0x0000), (9, 0xEF1B), (38, 0x61), (50, 0xEFE1), (133, 0xEFEB), (0xFFFF, 0x1234),
    ])
    #expect(decoder.heldKeys == sorted)

    // A copy is an independent value: releasing on the copy leaves the original held set.
    var copy = decoder
    _ = try copy.decode(payload: dkup(0x61, button: 38), direction: .serverToClient)
    #expect(copy.heldKeys.count == 5)
    #expect(decoder.heldKeys.count == 6)

    // A failed decoder does not affect another; the reset path is a new decoder.
    expectFailure(.unknownToken(payloadByteCount: 0), payload: [], decoder: &decoder)
    #expect(decoder.heldKeys == sorted)
    var other = try pressAll()
    #expect(other.failure == nil)
    #expect(
      try other.decode(payload: dkup(0x61, button: 38), direction: .serverToClient)
        == event(.up, 0x61, button: 38, .paired))

    // Runs are deterministic.
    let script = [
      dkdn(0x41, mask: 0x0001, button: 38), dkrp(0x61, button: 38), dkup(0x61, button: 38),
    ]
    func run() throws -> [BarrierKeyEvent] {
      var decoder = BarrierKeyboardDecoder()
      return try script.map { try decoder.decode(payload: $0, direction: .serverToClient) }
    }
    #expect(try run() == run())
  }

  @Test func everyButtonValueIsHeldAndReleasedWithItsPressIdentity() throws {
    // No capacity limit below the 65,536 button values: every press stays held until its own
    // release, which carries the press identity although the frame carries another one.
    var decoder = BarrierKeyboardDecoder()
    var mismatches = 0
    for button in UInt16.min...UInt16.max {
      let pressed = try decoder.decode(
        payload: dkdn(~button, button: button), direction: .serverToClient)
      if pressed != event(.down, ~button, button: button, .press) { mismatches += 1 }
    }
    let heldKeys = decoder.heldKeys
    #expect(heldKeys.count == 65_536)
    #expect(heldKeys.first?.button.rawValue == 0)
    #expect(heldKeys.last?.button.rawValue == 0xFFFF)
    #expect(zip(heldKeys, heldKeys.dropFirst()).allSatisfy { $0.button < $1.button })
    #expect(heldKeys.allSatisfy { $0.identifier.rawValue == ~$0.button.rawValue })
    for button in (UInt16.min...UInt16.max).reversed() {
      let released = try decoder.decode(
        payload: dkup(button, button: button), direction: .serverToClient)
      if released != event(.up, ~button, button: button, .paired) { mismatches += 1 }
    }
    #expect(mismatches == 0)
    #expect(decoder.heldKeys.isEmpty)
    #expect(decoder.failure == nil)
  }

  @Test func errorsCarryOnlyAllowlistedMetadata() throws {
    let errors: [KeyboardError] = [
      .unknownToken(payloadByteCount: 2),
      .unexpectedDirection(token: .dkrp, direction: .clientToServer),
      .invalidBodyLength(token: .dkup, bodyByteCount: 5),
    ]
    // Every error kind is checked: errorKind is exhaustive and ErrorKind is CaseIterable.
    #expect(Set(errors.map(errorKind)) == Set(ErrorKind.allCases))
    for error in errors {
      #expect(!reflectedGraphContainsSensitiveShape(error))
    }
    // A failure triggered by a real key frame latches only the error: no identifier, button,
    // mask or body byte.
    var decoder = BarrierKeyboardDecoder()
    expectFailure(
      .invalidBodyLength(token: .dkdn, bodyByteCount: 7), payload: dkdn(0x61, button: 38) + [0],
      decoder: &decoder)
    let failure = try #require(decoder.failure)
    #expect(!reflectedGraphContainsSensitiveShape(failure))
    // Events and held keys are outputs, not diagnostics: they carry wire-shaped values, which
    // is why the session must never log them.
    #expect(reflectedGraphContainsSensitiveShape(event(.down, 0x61, button: 38, .press)))
    #expect(reflectedGraphContainsSensitiveShape(held([(38, 0x61)])))
  }

  @Test func fixtureServerStreamThroughTheReassemblerCoalescedFragmentedAndTruncated() throws {
    let capture = try Capture(serverInputFixture)
    let frames = capture.frames(direction: .serverToClient)
    let bytes = frames.flatMap { $0 }
    let expected = contractEvents(capture.serverKeyPayloads)
    #expect(expected.events.count == 232)
    var frameEnds = Set<Int>()
    var keyFrameEnds: [Int] = []
    var end = 0
    for frame in frames {
      end += frame.count
      frameEnds.insert(end)
      if isKeyPayload(payload(frame)) { keyFrameEnds.append(end) }
    }

    /// Decodes `chunks`; `finish()` succeeds exactly when the stream ends on a frame boundary.
    func decode(
      _ chunks: [[UInt8]], comment: Comment
    ) throws -> (events: [BarrierKeyEvent], held: [BarrierHeldKey]) {
      var reassembler = try BarrierFrameReassembler(maximumPayloadLength: limit)
      var decoder = BarrierKeyboardDecoder()
      let events = try decodeKeyStream(chunks, decoder: &decoder, reassembler: &reassembler)
      #expect(decoder.failure == nil, comment)
      let length = chunks.reduce(0) { $0 + $1.count }
      if length == 0 || frameEnds.contains(length) {
        try reassembler.finish()
      } else {
        #expect(throws: BarrierFrameReassemblerError.self, comment) { try reassembler.finish() }
      }
      return (events, decoder.heldKeys)
    }

    // Coalesced, one byte at a time, and split at every byte boundary.
    for chunks in [[bytes], bytes.map { [$0] }] {
      let decoded = try decode(chunks, comment: "\(chunks.count) chunks")
      #expect(decoded.events == expected.events)
      #expect(decoded.held.isEmpty)
    }
    for cut in 1..<bytes.count {
      let decoded = try decode(
        [Array(bytes[..<cut]), Array(bytes[cut...])], comment: "split \(cut)")
      #expect(decoded.events == expected.events, "split \(cut)")
      #expect(decoded.held.isEmpty, "split \(cut)")
    }

    // Truncated at every length: only complete frames are decoded, and the held set is what
    // those frames left pressed, which is what cleanup must release.
    for cut in 0...bytes.count {
      let decoded = try decode([Array(bytes[..<cut])], comment: "cut \(cut)")
      let complete = keyFrameEnds.filter { $0 <= cut }.count
      #expect(decoded.events == Array(expected.events.prefix(complete)), "cut \(cut)")
      #expect(decoded.held == expected.heldAfter[complete], "cut \(cut)")
    }
  }

  @Test func productionSourceImportsOnlyKVMContracts() throws {
    let source = try String(
      contentsOf: repositoryRoot().appendingPathComponent(
        "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardDecoder.swift"),
      encoding: .utf8)
    // Comments may name types across the boundary to document it; code lines may not.
    let code = source.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.hasPrefix("//") }
    #expect(!code.isEmpty)
    #expect(code.filter { $0.hasPrefix("import ") } == ["import KVMContracts"])
    #expect(!code.contains { $0.contains(" import ") })
    let forbidden = [
      "KVMEvent", "VirtualKey", "KVMCore", "NativeProtocol", "Foundation", "print(", "dump(",
      "Logger", "os_log", "NSLog",
    ]
    for word in forbidden {
      #expect(!code.contains { $0.contains(word) }, "production code mentions \(word)")
    }
  }
}

// Golden tests for the M2-026 pointer and M2-027 keyboard encoders. Every
// expected frame must appear byte for byte among the server-to-client frames of
// Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json
// (M2-022 black-box capture), so no expected value is hand-derived.

import Foundation
import KVMContracts
import Testing

@testable import BarrierCompatibility

private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // BarrierCompatibilityTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // BarrierCompatibility
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()
}

/// Every complete server-to-client frame of an M2-022 capture fixture.
private func capturedServerFrames(
  _ fixture: String = "m2-022-linux-server-input/server-input-capture.json"
) throws -> Set<[UInt8]> {
  let url = repositoryRoot().appendingPathComponent("Tests/Fixtures/Barrier/\(fixture)")
  let json = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  let observations = try #require(json["observations"] as? [[String: Any]])
  var frames: Set<[UInt8]> = []
  for observation in observations
  where observation["direction"] as? String == "server-to-client" {
    let base64 = try #require(observation["applicationPayloadBase64"] as? String)
    frames.insert([UInt8](try #require(Data(base64Encoded: base64))))
  }
  return frames
}

/// The client screen of the capture: 1600 x 900 at the origin.
private let captureScreen = BarrierScreenInfo(
  originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)

private let none = ModifierState()
private let shift = ModifierState(shift: true)
private let caps = ModifierState(capsLock: true)

private func encoder() -> BarrierServerInputEncoder {
  BarrierServerInputEncoder(screen: captureScreen)
}

private func expectCaptured(
  _ frames: [[UInt8]], in captured: Set<[UInt8]>, _ comment: Comment? = nil
) {
  #expect(!frames.isEmpty, comment)
  for frame in frames {
    #expect(captured.contains(frame), comment)
  }
}

@Suite("M2-026 Barrier pointer encoder")
struct BarrierServerPointerEncoderTests {
  @Test("pointer moves are absolute client pixels equal to the captured DMMV frames")
  func pointerMoves() throws {
    let captured = try capturedServerFrames()
    for (x, y) in [(10, 450), (10, 460), (0, 460), (0, 450), (100, 500), (101, 501), (116, 506)] {
      let position = NormalizedPoint(x: Double(x) / 1599, y: Double(y) / 899)
      expectCaptured([encoder().pointer(to: position)], in: captured, "DMMV \(x),\(y)")
    }
  }

  @Test("pointer positions clamp to the client screen")
  func pointerClamps() {
    let corner = encoder().pointer(to: NormalizedPoint(x: 1, y: 1))
    #expect(corner == [0, 0, 0, 8] + Array("DMMV".utf8) + [0x06, 0x3F, 0x03, 0x83])
    let origin = encoder().pointer(to: NormalizedPoint(x: -3, y: .nan))
    #expect(origin == [0, 0, 0, 8] + Array("DMMV".utf8) + [0, 0, 0, 0])
  }

  @Test("buttons use the captured Barrier identifiers")
  func buttons() throws {
    let captured = try capturedServerFrames()
    for button in [MouseButton.left, .right, .middle, .auxiliary] {
      for phase in [ButtonPhase.down, .up] {
        expectCaptured(
          [encoder().button(button, phase: phase)], in: captured, "\(button) \(phase)")
      }
    }
    #expect(encoder().button(.left, phase: .down).suffix(5) == Array("DMDN".utf8) + [1])
    #expect(encoder().button(.right, phase: .up).suffix(5) == Array("DMUP".utf8) + [3])
    #expect(encoder().button(.middle, phase: .down).suffix(1) == [2])
    #expect(encoder().button(.auxiliary, phase: .down).suffix(1) == [4])
  }

  @Test("scroll uses 120 units per line, matching the captured DMWM frames")
  func scroll() throws {
    let captured = try capturedServerFrames()
    let up = try #require(encoder().scroll(deltaX: 0, deltaY: 1))
    let down = try #require(encoder().scroll(deltaX: 0, deltaY: -1))
    let left = try #require(encoder().scroll(deltaX: 1, deltaY: 0))
    let right = try #require(encoder().scroll(deltaX: -1, deltaY: 0))
    expectCaptured([up, down, left, right], in: captured)
    #expect(up.suffix(4) == [0x00, 0x00, 0x00, 0x78])
    #expect(left.suffix(4) == [0xFF, 0x88, 0x00, 0x00])
    #expect(encoder().scroll(deltaX: 0, deltaY: 0) == nil)
    let huge = try #require(encoder().scroll(deltaX: 0, deltaY: Int32.max))
    #expect(huge.suffix(2) == [0x7F, 0xFF])
  }
}

@Suite("M2-027 Barrier keyboard encoder")
struct BarrierServerKeyboardEncoderTests {
  @Test("every supported key, down and up, equals a captured frame")
  func keySweep() throws {
    let captured = try capturedServerFrames()
    var keys: [VirtualKey] = (0...25).map { .letter(UInt8($0)) } + (0...9).map { .digit(UInt8($0)) }
    keys += [
      .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
      .pageUp, .pageDown, .volumeUp, .volumeDown, .mute,
    ]
    keys += (1...12).map { .function(UInt8($0)) }
    for key in keys {
      #expect(BarrierServerInputEncoder.canEncode(key), "\(key)")
      let down = try encoder().key(key, phase: .down, modifiers: none)
      let up = try encoder().key(key, phase: .up, modifiers: none)
      expectCaptured(down + up, in: captured, "\(key)")
    }
  }

  @Test("letters and digits with Shift or Caps Lock send the produced character")
  func shiftedCharacters() throws {
    let captured = try capturedServerFrames()
    expectCaptured(try encoder().key(.letter(0), phase: .down, modifiers: shift), in: captured)
    expectCaptured(try encoder().key(.digit(1), phase: .down, modifiers: shift), in: captured)
    expectCaptured(try encoder().key(.letter(0), phase: .down, modifiers: caps), in: captured)
    expectCaptured(try encoder().key(.letter(0), phase: .up, modifiers: caps), in: captured)
    let shiftedA = try encoder().key(.letter(0), phase: .down, modifiers: shift)
    #expect(shiftedA == [[0, 0, 0, 10] + Array("DKDN".utf8) + [0x00, 0x41, 0x00, 0x01, 0x00, 38]])
    // Shift and Caps Lock together give lowercase on the reference layout.
    let both = try encoder().key(
      .letter(0), phase: .down, modifiers: ModifierState(shift: true, capsLock: true))
    #expect(both.first?[8...9] == [0x00, 0x61])
  }

  @Test("modifier keys send the mask before the press on down and including it on up")
  func modifiers() throws {
    let captured = try capturedServerFrames()
    let cases: [(VirtualKey, ModifierState)] = [
      (.shift, ModifierState(shift: true)), (.control, ModifierState(control: true)),
      (.option, ModifierState(option: true)), (.command, ModifierState(command: true)),
    ]
    for (key, pressed) in cases {
      // Capture reports the state after the event: set after a press, clear after a release.
      let down = try encoder().key(key, phase: .down, modifiers: pressed)
      expectCaptured(down, in: captured, "\(key)")
      expectCaptured(try encoder().key(key, phase: .up, modifiers: none), in: captured, "\(key)")
    }
    let controlState = ModifierState(control: true)
    let control = try encoder().key(.letter(2), phase: .down, modifiers: controlState)
    expectCaptured(control, in: captured, "ctrl+c")
  }

  @Test("each Caps Lock toggle sends a whole press, as captured")
  func capsLockToggles() throws {
    let captured = try capturedServerFrames()
    let on = try encoder().key(.capsLock, phase: .down, modifiers: caps)
    let off = try encoder().key(.capsLock, phase: .up, modifiers: none)
    #expect(on.count == 2)
    #expect(off.count == 2)
    expectCaptured(on + off, in: captured)
    // Frame layout: length 0...3, code 4...7, key 8...9, mask 10...11, button 12...13.
    #expect(on[0][10...11] == [0x00, 0x00] && on[1][10...11] == [0x10, 0x00])
    #expect(off[0][10...11] == [0x10, 0x00] && off[1][10...11] == [0x10, 0x00])
  }

  @Test("auto-repeat sends DKRP with count 1, as captured")
  func repeatKey() throws {
    let captured = try capturedServerFrames()
    let repeated = try encoder().key(.letter(0), phase: .repeatKey, modifiers: none)
    expectCaptured(repeated, in: captured)
    #expect(repeated.first?[4...7] == Array("DKRP".utf8)[...])
  }

  @Test("punctuation keys, plain and shifted, equal the captured frames (catalog v2)")
  func punctuation() throws {
    let captured = try capturedServerFrames(
      "m2-022-linux-punctuation-clipboard/punctuation-clipboard-capture.json")
    for key in PunctuationKey.allCases {
      let virtualKey = VirtualKey.punctuation(key)
      #expect(BarrierServerInputEncoder.canEncode(virtualKey), "\(key)")
      let down = try encoder().key(virtualKey, phase: .down, modifiers: none)
      let up = try encoder().key(virtualKey, phase: .up, modifiers: none)
      let shiftedDown = try encoder().key(virtualKey, phase: .down, modifiers: shift)
      expectCaptured(down + up + shiftedDown, in: captured, "\(key)")
    }
    let underscore = try encoder().key(.punctuation(.minus), phase: .down, modifiers: shift)
    #expect(
      underscore == [[0, 0, 0, 10] + Array("DKDN".utf8) + [0x00, 0x5F, 0x00, 0x01, 0x00, 20]])
    // Caps Lock does not shift punctuation; the mask still reports it.
    let capsMinus = try encoder().key(.punctuation(.minus), phase: .down, modifiers: caps)
    #expect(capsMinus.first?[8...11] == [0x00, 0x2D, 0x10, 0x00])
  }

  /// M1-PROTOCOL-003: what the first-party server can emit stays inside the contract.
  @Test("every emitted key identifier is frozen by M1-PROTOCOL-003 or one of its conventions")
  func identifiersStayInContract() throws {
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
    #expect(frozen.count == 100)
    var convention = Set<UInt16>(0x42...0x5A)
    convention.formUnion([0x29, 0x40, 0x23, 0x24, 0x25, 0x5E, 0x26, 0x2A, 0x28] as [UInt16])
    #expect(convention.count == 34)
    #expect(convention.isDisjoint(with: frozen))
    var keys: [VirtualKey] = (0..<26).map { VirtualKey.letter(UInt8($0)) }
    keys += (0..<10).map { VirtualKey.digit(UInt8($0)) }
    keys += (1...12).map { VirtualKey.function(UInt8($0)) }
    keys += PunctuationKey.allCases.map { VirtualKey.punctuation($0) }
    keys += [
      .enter, .escape, .tab, .space, .backspace, .delete, .left, .right, .up, .down, .home, .end,
      .pageUp, .pageDown, .shift, .control, .option, .command, .capsLock, .volumeUp, .volumeDown,
      .mute,
    ]
    var emitted = Set<UInt16>()
    for key in keys where BarrierServerInputEncoder.canEncode(key) {
      for modifiers in [none, shift, caps, ModifierState(shift: true, capsLock: true)] {
        for phase in [KeyPhase.down, .up, .repeatKey] {
          for frame in try encoder().key(key, phase: phase, modifiers: modifiers) {
            emitted.insert(UInt16(frame[8]) << 8 | UInt16(frame[9]))
          }
        }
      }
    }
    #expect(emitted.subtracting(frozen.union(convention)).isEmpty)
    #expect(convention.isSubset(of: emitted))
  }

  @Test("keys without an evidence-backed identifier are rejected and never encoded")
  func unsupportedKeys() {
    let unsupported: [VirtualKey] = [
      .unknown(5), .unknown(0), .function(13), .function(0), .letter(26), .digit(10),
    ]
    for key in unsupported {
      #expect(!BarrierServerInputEncoder.canEncode(key), "\(key)")
      #expect(throws: BarrierServerInputEncoderError.unsupportedKey) {
        try encoder().key(key, phase: .down, modifiers: none)
      }
    }
  }
}

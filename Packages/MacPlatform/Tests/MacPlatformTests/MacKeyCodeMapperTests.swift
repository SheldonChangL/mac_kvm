import Carbon.HIToolbox
import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

// MARK: - Independent SDK reference

/// The expected US ANSI baseline, written against the SDK's own `kVK_`
/// constants from `HIToolbox/Events.h`.
///
/// Production transcribes the same values as hexadecimal literals so that
/// `MacPlatform` does not import Carbon. Comparing the two here is a
/// double-entry check: a transcription slip in either place fails the suite.
private func sdkCode(_ constant: Int) -> CGKeyCode {
  CGKeyCode(constant)
}

/// Letters in catalog index order, `0` = A through `25` = Z.
private let sdkLetters: [CGKeyCode] = [
  kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F,
  kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L,
  kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
  kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
  kVK_ANSI_Y, kVK_ANSI_Z,
].map(sdkCode)

/// Main-row digits in catalog index order, `0` through `9`.
private let sdkDigits: [CGKeyCode] = [
  kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
  kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
].map(sdkCode)

/// F1 through F20. The SDK declares no `kVK_F21` through `kVK_F24`.
private let sdkFunctionKeys: [CGKeyCode] = [
  kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
  kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
  kVK_F18, kVK_F19, kVK_F20,
].map(sdkCode)

/// Every payload-free catalog v1 member and its SDK baseline.
private let sdkFixedMembers: [(VirtualKey, CGKeyCode)] = [
  (.enter, sdkCode(kVK_Return)),
  (.escape, sdkCode(kVK_Escape)),
  (.tab, sdkCode(kVK_Tab)),
  (.space, sdkCode(kVK_Space)),
  (.backspace, sdkCode(kVK_Delete)),
  (.delete, sdkCode(kVK_ForwardDelete)),
  (.left, sdkCode(kVK_LeftArrow)),
  (.right, sdkCode(kVK_RightArrow)),
  (.up, sdkCode(kVK_UpArrow)),
  (.down, sdkCode(kVK_DownArrow)),
  (.home, sdkCode(kVK_Home)),
  (.end, sdkCode(kVK_End)),
  (.pageUp, sdkCode(kVK_PageUp)),
  (.pageDown, sdkCode(kVK_PageDown)),
  (.shift, sdkCode(kVK_Shift)),
  (.control, sdkCode(kVK_Control)),
  (.option, sdkCode(kVK_Option)),
  (.command, sdkCode(kVK_Command)),
  (.capsLock, sdkCode(kVK_CapsLock)),
  (.volumeUp, sdkCode(kVK_VolumeUp)),
  (.volumeDown, sdkCode(kVK_VolumeDown)),
  (.mute, sdkCode(kVK_Mute)),
]

/// Every C-005 catalog v1 member, built from the ADR's domains rather than
/// from the mapper: 26 letters, 10 digits, F1...F24 and 22 payload-free keys.
private let catalogV1Members: [VirtualKey] =
  (0...25).map { VirtualKey.letter($0) }
  + (0...9).map { VirtualKey.digit($0) }
  + (1...24).map { VirtualKey.function($0) }
  + sdkFixedMembers.map(\.0)

private func mapped(_ key: VirtualKey) -> CGKeyCode? {
  try? MacKeyCodeMapper.keyCode(for: key).get()
}

private func failure(_ key: VirtualKey) -> MacKeyCodeMappingFailure? {
  guard case .failure(let reason) = MacKeyCodeMapper.keyCode(for: key) else { return nil }
  return reason
}

// MARK: - Happy path

@Test func coversCatalogVersionOne() {
  #expect(MacKeyCodeMapper.catalogVersion == 1)
}

@Test func mapsRepresentativeKeysToTheirUSANSIBaseline() {
  // Literal values transcribed from MacOSX26.2.sdk HIToolbox/Events.h.
  #expect(mapped(.letter(0)) == 0x00)  // A
  #expect(mapped(.letter(25)) == 0x06)  // Z
  #expect(mapped(.digit(0)) == 0x1D)
  #expect(mapped(.digit(1)) == 0x12)
  #expect(mapped(.function(1)) == 0x7A)
  #expect(mapped(.enter) == 0x24)
  #expect(mapped(.backspace) == 0x33)
  #expect(mapped(.delete) == 0x75)
  #expect(mapped(.command) == 0x37)
  #expect(mapped(.mute) == 0x4A)
}

@Test func everyLetterMatchesTheSDKANSIConstant() {
  for index in 0...25 {
    #expect(mapped(.letter(UInt8(index))) == sdkLetters[index], "letter index \(index)")
  }
}

@Test func everyDigitMatchesTheSDKANSIConstant() {
  for index in 0...9 {
    #expect(mapped(.digit(UInt8(index))) == sdkDigits[index], "digit index \(index)")
  }
}

@Test func functionKeysOneThroughTwentyMatchTheSDKConstants() {
  for number in 1...20 {
    #expect(mapped(.function(UInt8(number))) == sdkFunctionKeys[number - 1], "F\(number)")
  }
}

@Test func everyPayloadFreeMemberMatchesTheSDKConstant() {
  for (key, expected) in sdkFixedMembers {
    #expect(mapped(key) == expected, "\(key)")
  }
}

@Test func sideAgnosticModifiersMapToTheLeftSideKey() {
  // The SDK names the left-side keys without a side prefix.
  #expect(mapped(.shift) != sdkCode(kVK_RightShift))
  #expect(mapped(.control) != sdkCode(kVK_RightControl))
  #expect(mapped(.option) != sdkCode(kVK_RightOption))
  #expect(mapped(.command) != sdkCode(kVK_RightCommand))
}

// MARK: - Boundaries and catalog gaps

@Test func payloadDomainEdgesAreAcceptedAndTheirNeighboursRejected() {
  #expect(mapped(.letter(25)) != nil)
  #expect(failure(.letter(26)) == .payloadOutOfDomain)
  #expect(mapped(.digit(9)) != nil)
  #expect(failure(.digit(10)) == .payloadOutOfDomain)
  #expect(failure(.function(0)) == .payloadOutOfDomain)
  #expect(mapped(.function(1)) != nil)
  #expect(mapped(.function(20)) != nil)
  #expect(failure(.function(25)) == .payloadOutOfDomain)
}

@Test func functionKeysTwentyOneThroughTwentyFourAreCatalogGapsOnMacOS() {
  for number in 21...24 {
    #expect(failure(.function(UInt8(number))) == .noMacOSBaseline, "F\(number)")
  }
}

@Test func everyPayloadValueOutsideItsDomainIsRejected() {
  for value in UInt8.min...UInt8.max {
    if value > 25 {
      #expect(failure(.letter(value)) == .payloadOutOfDomain, "letter \(value)")
    }
    if value > 9 {
      #expect(failure(.digit(value)) == .payloadOutOfDomain, "digit \(value)")
    }
    if value == 0 || value > 24 {
      #expect(failure(.function(value)) == .payloadOutOfDomain, "function \(value)")
    }
  }
}

// MARK: - Invalid and unsupported input

@Test(arguments: [
  UInt32.min,
  0x24,  // equals the Return key code; must not pass through
  0x7A,  // equals the F1 key code; must not pass through
  UInt32(UInt16.max),
  UInt32(UInt16.max) + 1,
  UInt32.max,
])
func unknownKeysAreRejectedWhateverTheirRawValue(rawCode: UInt32) {
  #expect(failure(.unknown(rawCode)) == .unknownKey)
}

// MARK: - Exhaustive catalog expectations

@Test func everyCatalogMemberIsMappedOrRejectedAsAGap() {
  #expect(catalogV1Members.count == 82)
  let gaps = catalogV1Members.filter { mapped($0) == nil }
  #expect(gaps == (21...24).map { VirtualKey.function($0) })
  for gap in gaps {
    #expect(failure(gap) == .noMacOSBaseline)
  }
}

@Test func mappedCodesAreDistinctAndInsideTheSDKKeyCodeRange() {
  let codes = catalogV1Members.compactMap(mapped)
  #expect(codes.count == 78)
  #expect(Set(codes).count == codes.count)
  // The highest code the SDK declares is kVK_UpArrow.
  #expect(codes.allSatisfy { $0 <= sdkCode(kVK_UpArrow) })
}

@Test func catalogMembersNeverMapToKeysOutsideCatalogVersionOne() {
  // Right-side modifiers, Fn, keypad Enter, Help and the ISO/JIS keys are not
  // v1 members, so no member may produce them.
  let excluded: Set<CGKeyCode> = Set(
    [
      kVK_RightShift, kVK_RightControl, kVK_RightOption, kVK_RightCommand,
      kVK_Function, kVK_ANSI_KeypadEnter, kVK_ANSI_Keypad0, kVK_Help,
      kVK_ContextualMenu, kVK_ISO_Section, kVK_JIS_Eisu, kVK_JIS_Kana,
    ].map(sdkCode)
  )
  let codes = Set(catalogV1Members.compactMap(mapped))
  #expect(codes.isDisjoint(with: excluded))
}

@Test func failureReasonsAreClosedAndCarryNoPayload() {
  #expect(
    MacKeyCodeMappingFailure.allCases == [.unknownKey, .payloadOutOfDomain, .noMacOSBaseline])
  #expect(
    MacKeyCodeMappingFailure.allCases.map(\.rawValue) == [
      "unknownKey", "payloadOutOfDomain", "noMacOSBaseline",
    ])
}

// MARK: - Privacy

@Test func rejectionDescriptionsNeverContainTheRawCode() throws {
  let rawCode: UInt32 = 0x0DEC_AFBE
  let reason = try #require(failure(.unknown(rawCode)))
  let rendered = [
    String(describing: reason),
    String(reflecting: reason),
    String(describing: MacKeyCodeMapper.keyCode(for: .unknown(rawCode))),
  ]
  for text in rendered {
    #expect(!text.contains(String(rawCode)))
    #expect(!text.lowercased().contains(String(rawCode, radix: 16)))
  }
  let encoded = try JSONEncoder().encode(reason)
  #expect(String(decoding: encoded, as: UTF8.self) == "\"unknownKey\"")
}

// MARK: - Purity: no state, nothing to cancel or clean up

@Test func mapperHoldsNoStateAndCannotBeInstantiated() {
  // A caseless enum has no instances, so there is no stored state, no
  // lifecycle and no teardown entry point.
  #expect(MemoryLayout<MacKeyCodeMapper>.size == 0)
}

@Test func repeatedAndInterleavedCallsAreDeterministic() {
  let first = catalogV1Members.map { MacKeyCodeMapper.keyCode(for: $0) }
  // A rejection must not latch or poison any later call.
  _ = MacKeyCodeMapper.keyCode(for: .unknown(.max))
  _ = MacKeyCodeMapper.keyCode(for: .letter(.max))
  let second = catalogV1Members.map { MacKeyCodeMapper.keyCode(for: $0) }
  #expect(first == second)
}

@Test func concurrentCallersOffTheMainThreadAgree() async {
  let expected = catalogV1Members.map { MacKeyCodeMapper.keyCode(for: $0) }
  let results = await withTaskGroup(of: [Result<CGKeyCode, MacKeyCodeMappingFailure>].self) {
    group in
    for _ in 0..<8 {
      group.addTask {
        catalogV1Members.map { MacKeyCodeMapper.keyCode(for: $0) }
      }
    }
    var collected: [[Result<CGKeyCode, MacKeyCodeMappingFailure>]] = []
    for await result in group {
      collected.append(result)
    }
    return collected
  }
  #expect(results.count == 8)
  #expect(results.allSatisfy { $0 == expected })
}

@Test func cancelledCallersStillGetTheSameAnswer() async {
  // Mapping is synchronous and allocates nothing that outlives the call, so
  // cancellation has nothing to interrupt and nothing to clean up.
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return (Task.isCancelled, MacKeyCodeMapper.keyCode(for: .enter))
  }
  let (wasCancelled, result) = await task.value
  #expect(wasCancelled)
  #expect(result == .success(0x24))
}

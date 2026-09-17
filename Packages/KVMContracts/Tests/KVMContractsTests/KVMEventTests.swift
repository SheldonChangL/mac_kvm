import Foundation
import Testing
@testable import KVMContracts

private func requireSendableAndEquatable<T: Sendable & Equatable>(_: T) {}

@Test func allKVMEventVariantsRoundTrip() throws {
  let deviceID = DeviceID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  )
  let screenID = ScreenID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  )
  let transactionID = ClipboardTransactionID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  )
  let clipboard = ClipboardPayload(
    transactionID: transactionID,
    origin: .remote(deviceID),
    utf8Text: "fixture",
    contentHash: "sha256:fixture"
  )
  let events: [KVMEvent] = [
    .mouseMove(position: NormalizedPoint(x: 0.25, y: 0.75)),
    .mouseButton(button: .auxiliary, phase: .down),
    .scroll(deltaX: .min, deltaY: .max),
    .key(
      key: .unknown(.max),
      phase: .repeatKey,
      modifiers: ModifierState(
        shift: true,
        control: true,
        option: true,
        command: true,
        capsLock: true
      )
    ),
    .clipboard(clipboard),
    .enterScreen(screen: screenID, position: NormalizedPoint(x: 0, y: 1)),
    .leaveScreen(screen: screenID),
  ]

  for event in events {
    requireSendableAndEquatable(event)
    let encoded = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(KVMEvent.self, from: encoded)
    #expect(decoded == event)
  }
}

@Test func normalizedPointClampsConstructionAndDecoding() throws {
  #expect(NormalizedPoint(x: -.infinity, y: .infinity) == NormalizedPoint(x: 0, y: 1))

  let decoded = try JSONDecoder().decode(
    NormalizedPoint.self,
    from: Data(#"{"x":-4,"y":3}"#.utf8)
  )

  #expect(decoded == NormalizedPoint(x: 0, y: 1))
}

@Test func invalidClosedEnumValueIsRejected() {
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(MouseButton.self, from: Data("99".utf8))
  }
}

@Test func nonFiniteNormalizedPointMaintainsValueSemantics() throws {
  let point = NormalizedPoint(x: .nan, y: 0.5)

  #expect(point == point)
  #expect(point == NormalizedPoint(x: 0, y: 0.5))
  let encoded = try JSONEncoder().encode(point)
  #expect(try JSONDecoder().decode(NormalizedPoint.self, from: encoded) == point)
}

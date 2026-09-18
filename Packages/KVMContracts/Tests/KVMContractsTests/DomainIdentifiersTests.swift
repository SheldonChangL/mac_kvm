import Foundation
import Testing

@testable import KVMContracts

private func requireIdentifierContract<Identifier>(
  _ identifier: Identifier
)
where
  Identifier: RawRepresentable & Codable & Hashable & Sendable,
  Identifier.RawValue == UUID
{}

@Test func domainIdentifiersPreserveTheirUUIDAndRoundTrip() throws {
  let device = DeviceID(
    rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  )
  let screen = ScreenID(
    rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
  )
  let session = SessionID(
    rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
  )

  requireIdentifierContract(device)
  requireIdentifierContract(screen)
  requireIdentifierContract(session)

  #expect(device.rawValue.uuidString == "11111111-1111-1111-1111-111111111111")
  #expect(screen.rawValue.uuidString == "22222222-2222-2222-2222-222222222222")
  #expect(session.rawValue.uuidString == "33333333-3333-3333-3333-333333333333")

  #expect(try roundTrip(device) == device)
  #expect(try roundTrip(screen) == screen)
  #expect(try roundTrip(session) == session)
}

@Test func domainIdentifiersSupportUUIDBoundaryValues() throws {
  let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
  let maximum = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!

  #expect(try roundTrip(DeviceID(rawValue: zero)).rawValue == zero)
  #expect(try roundTrip(ScreenID(rawValue: maximum)).rawValue == maximum)
  #expect(try roundTrip(SessionID(rawValue: zero)).rawValue == zero)
}

@Test func malformedIdentifierPayloadsAreRejected() {
  let malformed = Data(#"{"rawValue":"not-a-uuid"}"#.utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(DeviceID.self, from: malformed)
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(ScreenID.self, from: malformed)
  }
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(SessionID.self, from: malformed)
  }
}

private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
  let encoded = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(Value.self, from: encoded)
}

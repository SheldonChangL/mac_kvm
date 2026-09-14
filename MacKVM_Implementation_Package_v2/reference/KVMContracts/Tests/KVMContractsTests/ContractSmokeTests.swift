import Foundation
import Testing
@testable import KVMContracts

@Test func normalizedPointClamps() {
    let point = NormalizedPoint(x: -1, y: 2)
    #expect(point == NormalizedPoint(x: 0, y: 1))
}

@Test func kvmEventRoundTripsCodable() throws {
    let event = KVMEvent.key(key: .enter, phase: .down, modifiers: ModifierState(command: true))
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(KVMEvent.self, from: data)
    #expect(decoded == event)
}

@Test func idsAreStronglyTyped() {
    #expect(DeviceID() != DeviceID())
    #expect(ScreenID() != ScreenID())
}

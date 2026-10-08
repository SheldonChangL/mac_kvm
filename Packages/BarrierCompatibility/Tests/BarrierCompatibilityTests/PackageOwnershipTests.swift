import Testing
@testable import BarrierCompatibility

@Test func childPackageOwnsBarrierCompatibilityTests() {
  #expect(#fileID == "BarrierCompatibilityTests/PackageOwnershipTests.swift")
}

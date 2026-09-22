import Testing
@testable import MacPlatform

@Test func childPackageOwnsMacPlatformTests() {
  #expect(#fileID == "MacPlatformTests/PackageOwnershipTests.swift")
}

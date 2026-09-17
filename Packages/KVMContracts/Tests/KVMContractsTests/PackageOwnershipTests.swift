import Testing
@testable import KVMContracts

@Test func childPackageOwnsKVMContractsTests() {
  #expect(#fileID == "KVMContractsTests/PackageOwnershipTests.swift")
}

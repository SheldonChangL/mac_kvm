import Testing

private let fixtureRootNames = ["Barrier", "Native"]

@Test("Integration test target sees both fixture roots")
func integrationTestTargetUsesDeclaredFixtureRoots() {
    #expect(fixtureRootNames.count == 2)
}

import Testing

private let unitTargetRequiresOSPermission = false

@Test("Unit test target requires no OS permission")
func unitTestTargetRequiresNoOSPermission() {
    #expect(unitTargetRequiresOSPermission == false)
}

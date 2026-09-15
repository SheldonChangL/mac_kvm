import Testing

@Test(
    "System test target supports explicit opt-in",
    .disabled("Requires explicit system-test opt-in")
)
func systemTestTargetRequiresExplicitOptIn() {}

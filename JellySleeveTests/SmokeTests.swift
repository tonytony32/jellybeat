import Testing
@testable import JellySleeve

/// Smoke test to confirm the test target builds and runs.
/// Real tests for the REST client land alongside `JellyfinClient` itself.
nonisolated struct SmokeTests {
    @Test
    func testTargetCompilesAndExecutes() {
        #expect(1 + 1 == 2)
    }
}

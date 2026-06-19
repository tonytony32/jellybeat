import Foundation
import Testing
@testable import JellyBeat

/// Tests for the JellySleeve → JellyBeat identity migration (`IdentityMigrator`).
/// Uses two throwaway `UserDefaults` suites so it never touches `.standard`; the
/// Keychain path (`includeKeychain: true`) is exercised by the app, not here,
/// because the Keychain is a process-wide shared resource.
@Suite(.serialized)
@MainActor
struct IdentityMigratorTests {

    private func makeSuites(
    ) -> (legacy: UserDefaults, target: UserDefaults, legacyName: String, targetName: String) {
        let legacyName = "test.legacy.\(UUID().uuidString)"
        let targetName = "test.target.\(UUID().uuidString)"
        return (
            UserDefaults(suiteName: legacyName)!,
            UserDefaults(suiteName: targetName)!,
            legacyName,
            targetName
        )
    }

    private func tearDown(_ legacyName: String, _ targetName: String) {
        UserDefaults.standard.removePersistentDomain(forName: legacyName)
        UserDefaults.standard.removePersistentDomain(forName: targetName)
    }

    /// App-owned keys (every `settings.*` / `playerStore.*` and `selectedThemeId`)
    /// are copied; foreign keys are not; the sentinel is set.
    @Test
    func copiesAppOwnedKeysAndSkipsForeignOnes() {
        let s = makeSuites()
        defer { tearDown(s.legacyName, s.targetName) }

        s.legacy.set("https://jelly.example", forKey: "settings.baseURL")
        s.legacy.set("device-uuid-123", forKey: "settings.deviceId")
        s.legacy.set(true, forKey: "settings.storeApiKeyInKeychain")
        s.legacy.set("classic", forKey: "selectedThemeId")
        s.legacy.set("session-42", forKey: "playerStore.selectedSessionId")
        s.legacy.set("nope", forKey: "someForeignKey")

        IdentityMigrator.migrate(from: s.legacy, into: s.target, includeKeychain: false)

        #expect(s.target.string(forKey: "settings.baseURL") == "https://jelly.example")
        #expect(s.target.string(forKey: "settings.deviceId") == "device-uuid-123")
        #expect(s.target.bool(forKey: "settings.storeApiKeyInKeychain") == true)
        #expect(s.target.string(forKey: "selectedThemeId") == "classic")
        #expect(s.target.string(forKey: "playerStore.selectedSessionId") == "session-42")
        #expect(s.target.object(forKey: "someForeignKey") == nil)
        #expect(s.target.bool(forKey: IdentityMigrator.sentinelKey) == true)
    }

    /// copy-if-absent: a value the user already set under the new identity is
    /// never overwritten by the legacy one.
    @Test
    func copyIfAbsentDoesNotOverwriteNewValues() {
        let s = makeSuites()
        defer { tearDown(s.legacyName, s.targetName) }

        s.legacy.set("old-url", forKey: "settings.baseURL")
        s.target.set("new-url", forKey: "settings.baseURL")

        IdentityMigrator.migrate(from: s.legacy, into: s.target, includeKeychain: false)

        #expect(s.target.string(forKey: "settings.baseURL") == "new-url")
    }

    /// The sentinel makes migration one-shot: a second run (after legacy data
    /// changed) copies nothing.
    @Test
    func isIdempotentViaSentinel() {
        let s = makeSuites()
        defer { tearDown(s.legacyName, s.targetName) }

        s.legacy.set("v1", forKey: "settings.baseURL")
        IdentityMigrator.migrate(from: s.legacy, into: s.target, includeKeychain: false)

        s.legacy.set("v2", forKey: "settings.baseURL")
        IdentityMigrator.migrate(from: s.legacy, into: s.target, includeKeychain: false)

        #expect(s.target.string(forKey: "settings.baseURL") == "v1")
    }
}

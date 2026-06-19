import Foundation
import Testing
@testable import JellyBeat

/// Tests for `SettingsStore` API-key storage logic: migration of legacy
/// installs to the new UserDefaults default on first launch, and correct
/// read/write behaviour for each toggle state.
///
/// Hermetic: every test runs against a throwaway `UserDefaults` suite and an
/// in-memory Keychain (`InMemoryKeychain`), torn down with
/// `removePersistentDomain`, so the suite never reads or mutates the user's real
/// `.standard` domain or login Keychain. Serialised because each still builds
/// multiple `SettingsStore`s over one suite to model relaunch.
@Suite(.serialized)
@MainActor
struct SettingsStoreTests {

    // MARK: - Helpers

    /// A per-test pair of throwaway backing stores plus the suite name needed to
    /// remove the persistent domain afterwards.
    private struct Env {
        let defaults: UserDefaults
        let keychain: InMemoryKeychain
        let suiteName: String
    }

    private func makeEnv() -> Env {
        let suiteName = "test.settings.\(UUID().uuidString)"
        return Env(
            defaults: UserDefaults(suiteName: suiteName)!,
            keychain: InMemoryKeychain(),
            suiteName: suiteName
        )
    }

    private func tearDown(_ env: Env) {
        UserDefaults.standard.removePersistentDomain(forName: env.suiteName)
    }

    private func makeStore(_ env: Env) -> SettingsStore {
        SettingsStore(defaults: env.defaults, keychain: env.keychain)
    }

    // MARK: - Migration

    /// Legacy install on the previous default (key in Keychain, old toggle
    /// `storeApiKeyInUserDefaults == false`). After `SettingsStore.init()` the
    /// key must be migrated to UserDefaults, the Keychain entry cleared, and
    /// the new toggle set to false.
    @Test
    func migratesApiKeyFromKeychainToUserDefaults() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let testKey = "migration-test-key-abc123"
        try env.keychain.save(apiKey: testKey)
        env.defaults.set(false, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        let store = makeStore(env)

        #expect(store.apiKey == testKey)
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(env.keychain.load() == nil)
        #expect(store.storeApiKeyInKeychain == false)
    }

    /// Legacy install with the key already in UserDefaults (old toggle
    /// `storeApiKeyInUserDefaults == true`). The key must stay in UserDefaults
    /// and the new toggle must be false.
    @Test
    func keepsApiKeyInUserDefaultsFromLegacyToggle() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let testKey = "ud-legacy-key-456"
        env.defaults.set(testKey, forKey: SettingsStore.Keys.apiKey)
        env.defaults.set(true, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        let store = makeStore(env)

        #expect(store.apiKey == testKey)
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(env.keychain.load() == nil)
        #expect(store.storeApiKeyInKeychain == false)
    }

    /// Idempotency: running migration twice must not corrupt the key.
    @Test
    func migrationIsIdempotent() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let testKey = "idempotency-key-xyz"
        try env.keychain.save(apiKey: testKey)
        env.defaults.set(false, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        _ = makeStore(env)
        let store2 = makeStore(env)

        #expect(store2.apiKey == testKey)
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(env.keychain.load() == nil)
    }

    // MARK: - Setter behaviour

    /// Default toggle (`storeApiKeyInKeychain == false`): setter must write to
    /// UserDefaults and leave the Keychain empty.
    @Test
    func setterWritesToUserDefaultsByDefault() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let store = makeStore(env)
        #expect(store.storeApiKeyInKeychain == false)
        store.apiKey = "ud-key-12345"

        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == "ud-key-12345")
        #expect(env.keychain.load() == nil)
    }

    /// Toggle ON (`storeApiKeyInKeychain = true`): setter must write to the
    /// Keychain and clear the UserDefaults slot.
    @Test
    func setterWritesToKeychainWhenToggleOn() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let store = makeStore(env)
        store.storeApiKeyInKeychain = true
        store.apiKey = "kc-key-67890"

        #expect(env.keychain.load() == "kc-key-67890")
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    /// Flipping the toggle from OFF → ON must move the key from UserDefaults to
    /// the Keychain and not leave a copy in UserDefaults.
    @Test
    func flippingToggleOnMigratesUserDefaultsToKeychain() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let store = makeStore(env)
        store.apiKey = "flip-key-toggle"
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-toggle")

        store.storeApiKeyInKeychain = true

        #expect(env.keychain.load() == "flip-key-toggle")
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    /// Flipping the toggle from ON → OFF must move the key from the Keychain
    /// back to UserDefaults and remove it from the Keychain.
    @Test
    func flippingToggleOffMigratesKeychainToUserDefaults() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let store = makeStore(env)
        store.storeApiKeyInKeychain = true
        store.apiKey = "flip-key-back"
        #expect(env.keychain.load() == "flip-key-back")

        store.storeApiKeyInKeychain = false

        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-back")
        #expect(env.keychain.load() == nil)
    }

    /// Once the new toggle is stored, a subsequent launch must honor it
    /// verbatim without re-running migration.
    @Test
    func honorsStoredKeychainToggleOnRelaunch() throws {
        let env = makeEnv()
        defer { tearDown(env) }

        let store = makeStore(env)
        store.storeApiKeyInKeychain = true
        store.apiKey = "relaunch-key"

        let store2 = makeStore(env)

        #expect(store2.storeApiKeyInKeychain == true)
        #expect(store2.apiKey == "relaunch-key")
        #expect(env.keychain.load() == "relaunch-key")
        #expect(env.defaults.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    // MARK: - Source selection persistence

    /// The stored source selection round-trips through `init` — including a
    /// third-party id (the open id space) — and defaults to `.auto` when absent.
    /// The persisted string equals the source id, so old "jellyfin"/"youtube"/
    /// "auto" values migrate with zero rewrite.
    @Test
    func sourceSelectionPersistsAndRoundTrips() {
        let env = makeEnv()
        defer { tearDown(env) }

        #expect(makeStore(env).sourceSelection == .auto)            // absent → auto

        let store = makeStore(env)
        store.sourceSelection = .youtube
        #expect(env.defaults.string(forKey: SettingsStore.Keys.sourceSelection) == "youtube")
        #expect(makeStore(env).sourceSelection == .youtube)         // reloads the pin

        store.sourceSelection = .forced(SourceID(rawValue: "com.example.spotify"))
        #expect(makeStore(env).sourceSelection.forcedKind == SourceID(rawValue: "com.example.spotify"))
    }
}

import Foundation
import Testing
@testable import JellyBeat

/// Tests for `SettingsStore` API-key storage logic: migration of legacy
/// installs to the new UserDefaults default on first launch, and correct
/// read/write behaviour for each toggle state. Runs serialised because both
/// `UserDefaults.standard` and the Keychain are process-wide shared resources.
@Suite(.serialized)
@MainActor
struct SettingsStoreTests {

    // MARK: - Helpers

    private func resetState() {
        let d = UserDefaults.standard
        d.removeObject(forKey: SettingsStore.Keys.storeApiKeyInKeychain)
        d.removeObject(forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)
        d.removeObject(forKey: SettingsStore.Keys.useKeychain)
        d.removeObject(forKey: SettingsStore.Keys.apiKey)
        d.removeObject(forKey: SettingsStore.Keys.sourceSelection)
        try? KeychainHelper.delete()
    }

    // MARK: - Migration

    /// Legacy install on the previous default (key in Keychain, old toggle
    /// `storeApiKeyInUserDefaults == false`). After `SettingsStore.init()` the
    /// key must be migrated to UserDefaults, the Keychain entry cleared, and
    /// the new toggle set to false.
    @Test
    func migratesApiKeyFromKeychainToUserDefaults() throws {
        resetState()
        defer { resetState() }

        let testKey = "migration-test-key-abc123"
        try KeychainHelper.save(apiKey: testKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        let store = SettingsStore()

        #expect(store.apiKey == testKey)
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(KeychainHelper.load() == nil)
        #expect(store.storeApiKeyInKeychain == false)
    }

    /// Legacy install with the key already in UserDefaults (old toggle
    /// `storeApiKeyInUserDefaults == true`). The key must stay in UserDefaults
    /// and the new toggle must be false.
    @Test
    func keepsApiKeyInUserDefaultsFromLegacyToggle() throws {
        resetState()
        defer { resetState() }

        let testKey = "ud-legacy-key-456"
        UserDefaults.standard.set(testKey, forKey: SettingsStore.Keys.apiKey)
        UserDefaults.standard.set(true, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        let store = SettingsStore()

        #expect(store.apiKey == testKey)
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(KeychainHelper.load() == nil)
        #expect(store.storeApiKeyInKeychain == false)
    }

    /// Idempotency: running migration twice must not corrupt the key.
    @Test
    func migrationIsIdempotent() throws {
        resetState()
        defer { resetState() }

        let testKey = "idempotency-key-xyz"
        try KeychainHelper.save(apiKey: testKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)

        _ = SettingsStore()
        let store2 = SettingsStore()

        #expect(store2.apiKey == testKey)
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == testKey)
        #expect(KeychainHelper.load() == nil)
    }

    // MARK: - Setter behaviour

    /// Default toggle (`storeApiKeyInKeychain == false`): setter must write to
    /// UserDefaults and leave the Keychain empty.
    @Test
    func setterWritesToUserDefaultsByDefault() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        #expect(store.storeApiKeyInKeychain == false)
        store.apiKey = "ud-key-12345"

        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "ud-key-12345")
        #expect(KeychainHelper.load() == nil)
    }

    /// Toggle ON (`storeApiKeyInKeychain = true`): setter must write to the
    /// Keychain and clear the UserDefaults slot.
    @Test
    func setterWritesToKeychainWhenToggleOn() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInKeychain = true
        store.apiKey = "kc-key-67890"

        #expect(KeychainHelper.load() == "kc-key-67890")
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    /// Flipping the toggle from OFF → ON must move the key from UserDefaults to
    /// the Keychain and not leave a copy in UserDefaults.
    @Test
    func flippingToggleOnMigratesUserDefaultsToKeychain() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.apiKey = "flip-key-toggle"
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-toggle")

        store.storeApiKeyInKeychain = true

        #expect(KeychainHelper.load() == "flip-key-toggle")
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    /// Flipping the toggle from ON → OFF must move the key from the Keychain
    /// back to UserDefaults and remove it from the Keychain.
    @Test
    func flippingToggleOffMigratesKeychainToUserDefaults() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInKeychain = true
        store.apiKey = "flip-key-back"
        #expect(KeychainHelper.load() == "flip-key-back")

        store.storeApiKeyInKeychain = false

        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-back")
        #expect(KeychainHelper.load() == nil)
    }

    /// Once the new toggle is stored, a subsequent launch must honor it
    /// verbatim without re-running migration.
    @Test
    func honorsStoredKeychainToggleOnRelaunch() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInKeychain = true
        store.apiKey = "relaunch-key"

        let store2 = SettingsStore()

        #expect(store2.storeApiKeyInKeychain == true)
        #expect(store2.apiKey == "relaunch-key")
        #expect(KeychainHelper.load() == "relaunch-key")
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    // MARK: - Source selection persistence

    /// The stored source selection round-trips through `init` — including a
    /// third-party id (the open id space) — and defaults to `.auto` when absent.
    /// The persisted string equals the source id, so old "jellyfin"/"youtube"/
    /// "auto" values migrate with zero rewrite.
    @Test
    func sourceSelectionPersistsAndRoundTrips() {
        resetState()
        defer { resetState() }

        #expect(SettingsStore().sourceSelection == .auto)          // absent → auto

        let store = SettingsStore()
        store.sourceSelection = .youtube
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.sourceSelection) == "youtube")
        #expect(SettingsStore().sourceSelection == .youtube)        // reloads the pin

        store.sourceSelection = .forced(SourceID(rawValue: "com.example.spotify"))
        #expect(SettingsStore().sourceSelection.forcedKind == SourceID(rawValue: "com.example.spotify"))
    }
}

import Foundation
import Testing
@testable import JellySleeve

/// Tests for `SettingsStore` API-key storage logic: migration from UserDefaults
/// to Keychain on first launch, and correct read/write behaviour for each toggle
/// state. Runs serialised because both `UserDefaults.standard` and the Keychain
/// are process-wide shared resources.
@Suite(.serialized)
@MainActor
struct SettingsStoreTests {

    // MARK: - Helpers

    private func resetState() {
        let d = UserDefaults.standard
        d.removeObject(forKey: SettingsStore.Keys.storeApiKeyInUserDefaults)
        d.removeObject(forKey: SettingsStore.Keys.useKeychain)
        d.removeObject(forKey: SettingsStore.Keys.apiKey)
        try? KeychainHelper.delete()
    }

    // MARK: - Migration

    /// Old install: `useKeychain == false` (pre-v0.2 default) and API key in
    /// UserDefaults. After `SettingsStore.init()` the key must be in the
    /// Keychain and the UserDefaults slot must be empty.
    @Test
    func migratesApiKeyFromUserDefaultsToKeychain() throws {
        resetState()
        defer { resetState() }

        let testKey = "migration-test-key-abc123"
        UserDefaults.standard.set(testKey, forKey: SettingsStore.Keys.apiKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.Keys.useKeychain)

        let store = SettingsStore()

        #expect(store.apiKey == testKey)
        #expect(KeychainHelper.load() == testKey)
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
        #expect(store.storeApiKeyInUserDefaults == false)
    }

    /// Idempotency: running migration twice must not corrupt the key or break anything.
    @Test
    func migrationIsIdempotent() throws {
        resetState()
        defer { resetState() }

        let testKey = "idempotency-key-xyz"
        UserDefaults.standard.set(testKey, forKey: SettingsStore.Keys.apiKey)
        UserDefaults.standard.set(false, forKey: SettingsStore.Keys.useKeychain)

        _ = SettingsStore()
        let store2 = SettingsStore()

        #expect(store2.apiKey == testKey)
        #expect(KeychainHelper.load() == testKey)
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    // MARK: - Setter behaviour

    /// Toggle ON (`storeApiKeyInUserDefaults = true`): setter must write to
    /// UserDefaults and clear the Keychain entry.
    @Test
    func setterWritesToUserDefaultsWhenToggleOn() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInUserDefaults = true
        store.apiKey = "ud-key-12345"

        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "ud-key-12345")
        #expect(KeychainHelper.load() == nil)
    }

    /// Toggle OFF (`storeApiKeyInUserDefaults = false`, the default): setter
    /// must write to Keychain and leave the UserDefaults slot empty.
    @Test
    func setterWritesToKeychainWhenToggleOff() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInUserDefaults = false
        store.apiKey = "kc-key-67890"

        #expect(KeychainHelper.load() == "kc-key-67890")
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }

    /// Flipping the toggle from OFF → ON must move the key from Keychain to
    /// UserDefaults and not leave a copy in the Keychain.
    @Test
    func flippingToggleOnMigratesKeychainToUserDefaults() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.apiKey = "flip-key-toggle"
        #expect(KeychainHelper.load() == "flip-key-toggle")

        store.storeApiKeyInUserDefaults = true

        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-toggle")
        #expect(KeychainHelper.load() == nil)
    }

    /// Flipping the toggle from ON → OFF must move the key from UserDefaults
    /// to Keychain and remove it from UserDefaults.
    @Test
    func flippingToggleOffMigratesUserDefaultsToKeychain() throws {
        resetState()
        defer { resetState() }

        let store = SettingsStore()
        store.storeApiKeyInUserDefaults = true
        store.apiKey = "flip-key-back"
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == "flip-key-back")

        store.storeApiKeyInUserDefaults = false

        #expect(KeychainHelper.load() == "flip-key-back")
        #expect(UserDefaults.standard.string(forKey: SettingsStore.Keys.apiKey) == nil)
    }
}

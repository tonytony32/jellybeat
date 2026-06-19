import Foundation
import os
import Security

/// The pre-rename bundle identifier. JellyBeat shipped as **JellySleeve** through
/// v0.2.x; the v0.3.0 rename changed the bundle id to `software.trypwood.jellybeat`.
/// This is the SINGLE source of truth for the OLD identifier — used to read
/// pre-rename UserDefaults, the legacy Keychain item, and the legacy Sources
/// directory (`SourceManifestLoader.legacyDirectory`). **Do NOT change this value
/// to `jellybeat`**: it is the *address of the old data*, not a name to rebrand —
/// flipping it makes the migrator read the new (empty) identity and every
/// upgrading user appears logged out (and CI would not catch it, since the tests
/// inject their own suites). `nonisolated` immutable `String` so it's readable
/// from both `@MainActor` (`IdentityMigrator`) and `nonisolated`
/// (`SourceManifestLoader`) contexts under Swift 6.
nonisolated enum LegacyIdentity {
    static let bundleID = "software.trypwood.jellysleeve"
}

/// One-time migration from the pre-rename identity to the current one.
///
/// JellyBeat was called **JellySleeve** through v0.2.x. The v0.3.0 rename
/// changed the bundle id from `software.trypwood.jellysleeve` to
/// `software.trypwood.jellybeat`, which silently re-points the two
/// identity-keyed stores: the `UserDefaults.standard` domain (which *is* the
/// bundle id for a non-sandboxed app) and the Keychain generic-password item
/// (keyed by `(service, account)`). Without migration every already-installed
/// user would launch the renamed build logged out and with default settings.
///
/// This copies the old domain's app-owned defaults and the old Keychain API key
/// into the new identity. It only ever **copies** — the old data is left intact
/// so a downgrade to JellySleeve keeps working — and is idempotent via a
/// sentinel written last. Run it before any store reads `UserDefaults.standard`
/// or the Keychain (see `AppDelegate.init`).
@MainActor
enum IdentityMigrator {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
        category: "migration"
    )

    // MARK: Legacy identity (pre-rename)
    //
    // All derived from `LegacyIdentity.bundleID` (the single source of truth for
    // the OLD identifier) — see its doc for why the value must stay `jellysleeve`.
    private static let legacyDomain = LegacyIdentity.bundleID
    private static let legacyKeychainService = LegacyIdentity.bundleID
    private static let legacyKeychainAccount = LegacyIdentity.bundleID + ".apikey"

    /// Marks the migration done. Lives in the new domain, written LAST so a
    /// crash mid-migration re-runs cleanly rather than skipping forever.
    static let sentinelKey = "migration.jellybeatV1Done"

    /// App-owned UserDefaults namespaces. Everything JellyBeat persists is keyed
    /// under one of these, so copying only these avoids dragging the global /
    /// Apple defaults that `dictionaryRepresentation()` also returns into the new
    /// domain. (Confirmed: the app uses no un-namespaced keys.)
    private static let copyPrefixes = ["settings.", "playerStore."]
    private static let copyExactKeys: Set<String> = ["selectedThemeId"]

    /// Run once on launch, before any store reads `UserDefaults.standard` or the
    /// Keychain. Safe (and cheap) to call when there is nothing to migrate.
    static func runIfNeeded() {
        guard let legacy = UserDefaults(suiteName: legacyDomain) else {
            // Can't open the old domain (would only happen for a sandboxed
            // build, where suiteName means an app group). Nothing to migrate.
            UserDefaults.standard.set(true, forKey: sentinelKey)
            return
        }
        migrate(from: legacy, into: .standard, includeKeychain: true)
    }

    /// Testable core. `includeKeychain` is false in unit tests because the
    /// Keychain is a process-wide shared resource we don't want them mutating.
    static func migrate(from legacy: UserDefaults, into target: UserDefaults, includeKeychain: Bool) {
        guard !target.bool(forKey: sentinelKey) else { return }

        let copied = copyDefaults(from: legacy, into: target)
        if includeKeychain { migrateKeychainItem() }

        // Sentinel LAST: if we crash above, the next launch re-runs cleanly.
        target.set(true, forKey: sentinelKey)
        if copied > 0 {
            logger.notice("Identity migration: copied \(copied, privacy: .public) settings from \(legacyDomain, privacy: .public)")
        }
    }

    // MARK: UserDefaults

    private static func copyDefaults(from legacy: UserDefaults, into target: UserDefaults) -> Int {
        var copied = 0
        for (key, value) in legacy.dictionaryRepresentation() where shouldCopy(key) {
            // copy-if-absent: any value the user already set under the new
            // identity wins over the legacy one.
            guard target.object(forKey: key) == nil else { continue }
            target.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func shouldCopy(_ key: String) -> Bool {
        if copyExactKeys.contains(key) { return true }
        return copyPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: Keychain

    private static func migrateKeychainItem() {
        // Only when the new identity has no key yet — never clobber a re-entry.
        guard KeychainHelper.load() == nil else { return }
        guard let legacyKey = legacyKeychainAPIKey(), !legacyKey.isEmpty else { return }
        do {
            try KeychainHelper.save(apiKey: legacyKey)
            logger.notice("Identity migration: copied API key from legacy Keychain item")
        } catch {
            logger.error("Identity migration: legacy Keychain copy failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func legacyKeychainAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }
}

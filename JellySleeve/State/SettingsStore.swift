import Foundation
import Observation
import os

/// User-facing configuration of the Jellyfin connection.
///
/// Storage strategy:
///  - Plain settings (`baseURLString`, `userId`, `allowSelfSigned`,
///    `refreshRate`, `storeApiKeyInUserDefaults`) live in `UserDefaults`.
///  - The API key location is governed by `storeApiKeyInUserDefaults`:
///     * `false` (default) → Keychain via `KeychainHelper` (encrypted at rest).
///     * `true`  → `UserDefaults` plaintext (user-elected; less secure).
///
/// SwiftUI views read this with `@Environment(SettingsStore.self)` and bind
/// to its fields via `@Bindable`. Mutations are persisted synchronously in
/// `didSet`, so closing the Settings window without a "save" button still
/// keeps everything in sync.
@MainActor
@Observable
final class SettingsStore {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellysleeve",
        category: "state"
    )

    // MARK: Persisted scalars

    var baseURLString: String {
        didSet {
            UserDefaults.standard.set(
                baseURLString.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: Keys.baseURL
            )
        }
    }

    var userId: String {
        didSet {
            UserDefaults.standard.set(
                userId.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: Keys.userId
            )
        }
    }

    var allowSelfSigned: Bool {
        didSet {
            UserDefaults.standard.set(allowSelfSigned, forKey: Keys.allowSelfSigned)
        }
    }

    var refreshRate: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshRate, forKey: Keys.refreshRate)
        }
    }

    // MARK: Appearance toggles (apply across themes)

    var windowLevel: OverlayWindowLevel {
        didSet {
            UserDefaults.standard.set(windowLevel.rawValue, forKey: Keys.windowLevel)
        }
    }

    var windowOpacity: Double {
        didSet {
            UserDefaults.standard.set(windowOpacity, forKey: Keys.windowOpacity)
        }
    }

    /// When true the API key is persisted in UserDefaults (cleartext plist)
    /// instead of the Keychain. Default is false (Keychain). Flipping it
    /// migrates the current value between locations atomically.
    var storeApiKeyInUserDefaults: Bool {
        didSet {
            UserDefaults.standard.set(storeApiKeyInUserDefaults, forKey: Keys.storeApiKeyInUserDefaults)
            if oldValue != storeApiKeyInUserDefaults {
                persistAPIKey()
            }
        }
    }

    // MARK: Sensitive (Keychain or UserDefaults depending on `storeApiKeyInUserDefaults`)

    var apiKey: String {
        didSet {
            persistAPIKey()
        }
    }

    // MARK: Derived

    var baseURL: URL? {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil
        else {
            return nil
        }
        return url
    }

    var isFullyConfigured: Bool {
        baseURL != nil && !apiKey.isEmpty && !userId.isEmpty
    }

    var jellyfinConfiguration: JellyfinConfiguration? {
        guard let url = baseURL, !apiKey.isEmpty, !userId.isEmpty else {
            return nil
        }
        return JellyfinConfiguration(
            baseURL: url,
            apiKey: apiKey,
            userId: userId,
            allowSelfSigned: allowSelfSigned
        )
    }

    // MARK: Init

    init() {
        let defaults = UserDefaults.standard

        self.baseURLString = (defaults.string(forKey: Keys.baseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.userId = (defaults.string(forKey: Keys.userId) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowSelfSigned = defaults.bool(forKey: Keys.allowSelfSigned)

        let storedRate = defaults.double(forKey: Keys.refreshRate)
        self.refreshRate = storedRate == 0 ? 1.5 : storedRate

        self.windowLevel = OverlayWindowLevel(rawValue: defaults.string(forKey: Keys.windowLevel) ?? "")
            ?? .alwaysOnTop
        let storedOpacity = defaults.double(forKey: Keys.windowOpacity)
        self.windowOpacity = storedOpacity == 0 ? 1.0 : storedOpacity
        // Decide the storage location for the API key.
        //
        // New default (this version onwards): Keychain.
        // Old default (pre-this-version): UserDefaults (old toggle `useKeychain` == false).
        //
        // Migration rules (idempotent):
        //   1. New toggle (`storeApiKeyInUserDefaults`) already stored → use it directly.
        //   2. Old toggle (`useKeychain`) stored, was false → key is in UserDefaults
        //      → migrate to Keychain, set new toggle to false (default).
        //   3. Old toggle stored, was true → key is already in Keychain → correct.
        //   4. Neither toggle → check for stray key in UserDefaults, migrate if found.
        let newToggleStored = defaults.object(forKey: Keys.storeApiKeyInUserDefaults) != nil

        if newToggleStored {
            let storeInUD = defaults.bool(forKey: Keys.storeApiKeyInUserDefaults)
            self.storeApiKeyInUserDefaults = storeInUD
            self.apiKey = storeInUD
                ? (defaults.string(forKey: Keys.apiKey) ?? "")
                : (KeychainHelper.load() ?? "")
        } else if defaults.object(forKey: Keys.useKeychain) != nil {
            let oldUseKeychain = defaults.bool(forKey: Keys.useKeychain)
            defaults.removeObject(forKey: Keys.useKeychain)
            if oldUseKeychain {
                // Was already using Keychain — desired default, nothing to migrate.
                self.storeApiKeyInUserDefaults = false
                self.apiKey = KeychainHelper.load() ?? ""
            } else {
                // Was using UserDefaults — migrate key to Keychain.
                let plain = defaults.string(forKey: Keys.apiKey) ?? ""
                self.storeApiKeyInUserDefaults = false
                self.apiKey = plain
                if !plain.isEmpty {
                    Self.logger.notice("Migrated API key from UserDefaults to Keychain")
                    do {
                        try KeychainHelper.save(apiKey: plain)
                    } catch {
                        Self.logger.error("Migration to Keychain failed: \(String(describing: error), privacy: .public)")
                    }
                    defaults.removeObject(forKey: Keys.apiKey)
                }
            }
            defaults.set(false, forKey: Keys.storeApiKeyInUserDefaults)
        } else {
            // Fresh install or unknown prior state.
            let plain = defaults.string(forKey: Keys.apiKey)
            let keychainValue = KeychainHelper.load()
            self.storeApiKeyInUserDefaults = false
            if let plain, !plain.isEmpty, (keychainValue == nil || keychainValue!.isEmpty) {
                Self.logger.notice("Migrated API key from UserDefaults to Keychain")
                self.apiKey = plain
                do {
                    try KeychainHelper.save(apiKey: plain)
                } catch {
                    Self.logger.error("Migration to Keychain failed: \(String(describing: error), privacy: .public)")
                }
                defaults.removeObject(forKey: Keys.apiKey)
            } else {
                self.apiKey = keychainValue ?? ""
            }
            defaults.set(false, forKey: Keys.storeApiKeyInUserDefaults)
        }
    }

    // MARK: Persistence helpers

    /// Persist the current `apiKey` value at the location dictated by
    /// `storeApiKeyInUserDefaults` and clear the other location.
    /// Empty keys are treated as "delete from both".
    private func persistAPIKey() {
        let defaults = UserDefaults.standard
        if apiKey.isEmpty {
            try? KeychainHelper.delete()
            defaults.removeObject(forKey: Keys.apiKey)
            return
        }
        if storeApiKeyInUserDefaults {
            defaults.set(apiKey, forKey: Keys.apiKey)
            try? KeychainHelper.delete()
        } else {
            do {
                try KeychainHelper.save(apiKey: apiKey)
            } catch {
                Self.logger.error("Failed to persist API key to Keychain: \(String(describing: error), privacy: .public)")
            }
            defaults.removeObject(forKey: Keys.apiKey)
        }
    }

    enum Keys {
        static let baseURL = "settings.baseURL"
        static let userId = "settings.userId"
        static let allowSelfSigned = "settings.allowSelfSigned"
        static let refreshRate = "settings.refreshRate"
        /// New toggle key (default false = Keychain).
        static let storeApiKeyInUserDefaults = "settings.storeApiKeyInUserDefaults"
        /// Legacy key — read only during one-time migration from pre-v0.2 installs.
        static let useKeychain = "settings.useKeychain"
        /// UserDefaults slot for the API key when `storeApiKeyInUserDefaults == true`.
        static let apiKey = "settings.apiKey"
        static let windowLevel = "settings.windowLevel"
        static let windowOpacity = "settings.windowOpacity"
    }

    // MARK: - Persisted overlay window position (per display)

    /// Saved overlay origin keyed by `CGDirectDisplayID` so multi-monitor
    /// setups remember a separate position per screen (plan §6 Fase 6).
    func overlayPosition(forDisplay displayID: UInt32) -> CGPoint? {
        let key = Self.positionKey(for: displayID)
        guard let array = UserDefaults.standard.array(forKey: key) as? [Double],
              array.count == 2 else { return nil }
        return CGPoint(x: array[0], y: array[1])
    }

    func setOverlayPosition(_ point: CGPoint, forDisplay displayID: UInt32) {
        let key = Self.positionKey(for: displayID)
        UserDefaults.standard.set([Double(point.x), Double(point.y)], forKey: key)
    }

    private static func positionKey(for displayID: UInt32) -> String {
        "settings.overlayPosition.\(displayID)"
    }

    // MARK: - Device identifier (for WebSocket subscription)

    /// Stable UUID that identifies this JellySleeve install to the Jellyfin
    /// server. Required as a query parameter on `/socket` so the server can
    /// track our connection. Generated lazily on first use and persisted.
    var deviceId: String {
        if let stored = UserDefaults.standard.string(forKey: Self.deviceIdKey) {
            return stored
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.deviceIdKey)
        return fresh
    }

    private static let deviceIdKey = "settings.deviceId"
}

/// Cross-theme overlay window placement. Persisted in `SettingsStore`.
nonisolated enum OverlayWindowLevel: String, CaseIterable, Identifiable, Sendable {
    case alwaysOnTop
    case normal
    case behind

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alwaysOnTop: return "Always on top"
        case .normal: return "Normal"
        case .behind: return "Behind other windows"
        }
    }
}

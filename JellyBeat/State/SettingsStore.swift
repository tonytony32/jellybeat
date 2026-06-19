import Foundation
import Observation
import os
import ServiceManagement

/// User-facing configuration of the Jellyfin connection.
///
/// Storage strategy:
///  - Plain settings (`baseURLString`, `userId`, `allowSelfSigned`,
///    `refreshRate`, `storeApiKeyInKeychain`) live in `UserDefaults`.
///  - The API key location is governed by `storeApiKeyInKeychain`:
///     * `false` (default) → `UserDefaults`, alongside every other setting.
///        This is the default because the macOS Keychain re-prompts for
///        access whenever the app binary's signature changes (every local
///        debug build, and sometimes after app updates), which is a constant
///        nuisance for the common case.
///     * `true`  → Keychain via `KeychainHelper` (encrypted at rest;
///        user-elected for stronger privacy).
///
/// SwiftUI views read this with `@Environment(SettingsStore.self)` and bind
/// to its fields via `@Bindable`. Mutations are persisted synchronously in
/// `didSet`, so closing the Settings window without a "save" button still
/// keeps everything in sync.
@MainActor
@Observable
final class SettingsStore {
    private static let logger = Logger(
        subsystem: "software.trypwood.jellybeat",
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

    // MARK: General

    var appPresence: AppPresence {
        didSet {
            UserDefaults.standard.set(appPresence.rawValue, forKey: Keys.appPresence)
        }
    }

    /// Which playback source drives the overlay: `auto` lets the arbiter pick
    /// the active source, `jellyfin` / `youtube` pin one. Persisted so a user's
    /// pick survives relaunch. Mirrors the `appPresence` `@AppStorage` pattern
    /// so the menu-bar binding in `JellyBeatApp` reacts to changes.
    var sourceSelection: SourceSelection {
        didSet {
            UserDefaults.standard.set(sourceSelection.rawValue, forKey: Keys.sourceSelection)
        }
    }

    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Self.logger.warning("Launch at login toggle failed: \(String(describing: error), privacy: .public)")
            }
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

    /// When true the API key is persisted in the macOS Keychain (encrypted at
    /// rest). Default is false → the key lives in UserDefaults alongside the
    /// other settings, which avoids the repeated Keychain authorization
    /// prompts that re-signed (dev) builds trigger. Flipping it migrates the
    /// current value between locations atomically.
    var storeApiKeyInKeychain: Bool {
        didSet {
            UserDefaults.standard.set(storeApiKeyInKeychain, forKey: Keys.storeApiKeyInKeychain)
            if oldValue != storeApiKeyInKeychain {
                persistAPIKey()
            }
        }
    }

    // MARK: Sensitive (UserDefaults or Keychain depending on `storeApiKeyInKeychain`)

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

        self.appPresence = AppPresence(rawValue: defaults.string(forKey: Keys.appPresence) ?? "") ?? .dockAndMenuBar
        self.sourceSelection = SourceSelection(rawValue: defaults.string(forKey: Keys.sourceSelection) ?? "") ?? .auto
        self.launchAtLogin = SMAppService.mainApp.status == .enabled

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
        // New default (this version onwards): UserDefaults, alongside every
        // other setting. This avoids the macOS Keychain authorization prompt
        // that fires whenever the app binary is re-signed (every local debug
        // build, and sometimes after app updates). `storeApiKeyInKeychain`
        // opts back into encrypted-at-rest Keychain storage.
        //
        // Migration (idempotent): once the new toggle key
        // (`storeApiKeyInKeychain`) exists we honor it verbatim. On the first
        // launch of this version it is absent, so we collapse whatever prior
        // installs left behind — key in Keychain (the old default), key in
        // UserDefaults, or the legacy `useKeychain` / `storeApiKeyInUserDefaults`
        // toggles — into the new UserDefaults default. The key is read from
        // wherever it lived and rewritten to UserDefaults; the Keychain entry
        // and legacy toggles are cleared.
        if defaults.object(forKey: Keys.storeApiKeyInKeychain) != nil {
            let inKeychain = defaults.bool(forKey: Keys.storeApiKeyInKeychain)
            self.storeApiKeyInKeychain = inKeychain
            self.apiKey = inKeychain
                ? (KeychainHelper.load() ?? "")
                : (defaults.string(forKey: Keys.apiKey) ?? "")
        } else {
            // First launch on this version — migrate to the UserDefaults default.
            let plain = defaults.string(forKey: Keys.apiKey) ?? ""
            let migrated = plain.isEmpty ? (KeychainHelper.load() ?? "") : plain
            self.storeApiKeyInKeychain = false
            self.apiKey = migrated
            if migrated.isEmpty {
                defaults.removeObject(forKey: Keys.apiKey)
            } else {
                defaults.set(migrated, forKey: Keys.apiKey)
                Self.logger.notice("Migrated API key to UserDefaults (default storage)")
            }
            try? KeychainHelper.delete()
            defaults.removeObject(forKey: Keys.useKeychain)
            defaults.removeObject(forKey: Keys.storeApiKeyInUserDefaults)
            defaults.set(false, forKey: Keys.storeApiKeyInKeychain)
        }
    }

    // MARK: Persistence helpers

    /// Persist the current `apiKey` value at the location dictated by
    /// `storeApiKeyInKeychain` and clear the other location.
    /// Empty keys are treated as "delete from both".
    private func persistAPIKey() {
        let defaults = UserDefaults.standard
        if apiKey.isEmpty {
            try? KeychainHelper.delete()
            defaults.removeObject(forKey: Keys.apiKey)
            return
        }
        if storeApiKeyInKeychain {
            do {
                try KeychainHelper.save(apiKey: apiKey)
            } catch {
                Self.logger.error("Failed to persist API key to Keychain: \(String(describing: error), privacy: .public)")
            }
            defaults.removeObject(forKey: Keys.apiKey)
        } else {
            defaults.set(apiKey, forKey: Keys.apiKey)
            try? KeychainHelper.delete()
        }
    }

    enum Keys {
        static let appPresence = "settings.appPresence"
        static let sourceSelection = "settings.sourceSelection"
        static let baseURL = "settings.baseURL"
        static let userId = "settings.userId"
        static let allowSelfSigned = "settings.allowSelfSigned"
        static let refreshRate = "settings.refreshRate"
        /// Toggle key (default false = UserDefaults; true = Keychain).
        static let storeApiKeyInKeychain = "settings.storeApiKeyInKeychain"
        /// Legacy toggle (default false = Keychain) — read only during the
        /// one-time migration to `storeApiKeyInKeychain`.
        static let storeApiKeyInUserDefaults = "settings.storeApiKeyInUserDefaults"
        /// Even older legacy toggle — read only during one-time migration.
        static let useKeychain = "settings.useKeychain"
        /// UserDefaults slot for the API key when `storeApiKeyInKeychain == false`.
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

    /// Stable UUID that identifies this JellyBeat install to the Jellyfin
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

/// The overlay's playback-source preference, persisted in `SettingsStore`.
/// `auto` defers to the arbiter; a forced selection pins a specific source by
/// id. An **open** value type (not a closed enum) so a third-party source id can
/// be pinned; the two built-ins keep their `.jellyfin` / `.youtube` statics, and
/// the persisted `rawValue` round-trips any id losslessly.
nonisolated struct SourceSelection: Hashable, Sendable, Identifiable {
    enum Mode: Hashable, Sendable {
        case auto
        case forced(SourceID)
    }

    let mode: Mode
    init(mode: Mode) { self.mode = mode }

    static let auto = SourceSelection(mode: .auto)
    static let jellyfin = SourceSelection(mode: .forced(.jellyfin))
    static let youtube = SourceSelection(mode: .forced(.youtube))
    static func forced(_ id: SourceID) -> SourceSelection { .init(mode: .forced(id)) }

    var id: String { rawValue }

    /// The pinned source, or `nil` in `auto` (let the arbiter decide).
    var forcedKind: SourceID? {
        if case .forced(let k) = mode { return k }
        return nil
    }

    /// Persisted string: a forced selection stores its source id; `auto` stores
    /// "auto". Lossless for built-in and third-party ids alike, so the old
    /// persisted "jellyfin"/"youtube"/"auto" values migrate with zero rewrite.
    var rawValue: String {
        if case .forced(let k) = mode { return k.rawValue }
        return "auto"
    }

    init?(rawValue: String) {
        self = (rawValue.isEmpty || rawValue == "auto") ? .auto : .forced(SourceID(rawValue: rawValue))
    }
}

nonisolated enum AppPresence: String, CaseIterable, Identifiable, Sendable {
    case dockAndMenuBar
    case menuBarOnly
    case dockOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dockAndMenuBar: return "Dock & Menu Bar"
        case .menuBarOnly:    return "Menu Bar Only"
        case .dockOnly:       return "Dock Only"
        }
    }

    var showsMenuBar: Bool { self == .menuBarOnly || self == .dockAndMenuBar }
    var showsDock: Bool    { self == .dockOnly    || self == .dockAndMenuBar }
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

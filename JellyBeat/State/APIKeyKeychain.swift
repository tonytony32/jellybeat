import Foundation

/// Abstraction over the secret store that holds the Jellyfin API key, so
/// `SettingsStore` can be exercised by unit tests — and constructed by the
/// hosted test runner — without ever reading or mutating the user's real login
/// Keychain. Production uses `SystemKeychain` (the real `KeychainHelper`); tests
/// and the test host inject `InMemoryKeychain`.
protocol APIKeyKeychain: Sendable {
    /// Insert or overwrite the key. An empty string deletes, mirroring
    /// `KeychainHelper.save(apiKey:)`.
    func save(apiKey: String) throws
    func load() -> String?
    func delete() throws
}

/// Production conformer backed by the macOS Keychain via `KeychainHelper`.
struct SystemKeychain: APIKeyKeychain {
    func save(apiKey: String) throws { try KeychainHelper.save(apiKey: apiKey) }
    func load() -> String? { KeychainHelper.load() }
    func delete() throws { try KeychainHelper.delete() }
}

/// In-memory conformer for unit tests and the hosted test runner. Backed by a
/// single optional string instead of the Security framework, so a test run can
/// neither read nor delete the user's real stored API key. Empty-string save is
/// treated as delete to match `KeychainHelper`/`SystemKeychain` semantics.
final class InMemoryKeychain: APIKeyKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    init(apiKey: String? = nil) { self.stored = apiKey }

    func save(apiKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        stored = apiKey.isEmpty ? nil : apiKey
    }

    func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

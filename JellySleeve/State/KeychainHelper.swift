import Foundation
import Security

/// Thin wrapper around the Security framework for persisting the Jellyfin API
/// key. Used by `SettingsStore` instead of `UserDefaults` (plan §2 / §3 / §6
/// Fase 3 criterion 2: the key must NOT appear in
/// `~/Library/Preferences/software.trypwood.jellysleeve.plist`).
///
/// One slot per app, keyed by `(service, account)`. To clear it manually:
///
/// ```
/// security delete-generic-password \
///     -s software.trypwood.jellysleeve \
///     -a software.trypwood.jellysleeve.apikey
/// ```
nonisolated enum KeychainHelper {
    static let service = "software.trypwood.jellysleeve"
    static let account = "software.trypwood.jellysleeve.apikey"

    enum KeychainError: Error, LocalizedError, Equatable {
        case unhandled(status: OSStatus)
        case malformedData

        var errorDescription: String? {
            switch self {
            case .unhandled(let status):
                let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
                return "Keychain error (OSStatus \(status)): \(message)"
            case .malformedData:
                return "Keychain returned data that is not valid UTF-8."
            }
        }
    }

    /// Insert or overwrite the API key. Empty strings are treated as
    /// `delete()` so the caller does not have to branch.
    static func save(apiKey: String) throws {
        guard !apiKey.isEmpty else {
            try delete()
            return
        }
        let data = Data(apiKey.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try to update an existing entry first; if there isn't one, add.
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(status: addStatus)
            }
        default:
            throw KeychainError.unhandled(status: updateStatus)
        }
    }

    /// Read the API key, returning `nil` if no entry exists.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    /// Remove the API key. Missing entries are treated as success.
    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }
}

import Foundation
import Security
import os

/// Small Keychain wrapper for the sync session. Access and refresh tokens are
/// credentials, not preferences: keeping them in UserDefaults makes them
/// readable from the app's plist backup and from ordinary diagnostics.
enum SyncSessionStore {
    private static let log = Logger(subsystem: "com.enigmadux.knotq", category: "sync-auth")
    private static let service = "com.enigmadux.knotq.sync-session"

    static func load(key: String) -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            logFailure(status, operation: "load", key: key, expected: errSecItemNotFound)
            return nil
        }
        return item as? Data
    }

    /// Returns false when the credential could not be durably protected. Callers
    /// must not fall back to writing the new credential to UserDefaults.
    @discardableResult
    static func save(_ data: Data, key: String) -> Bool {
        let query = baseQuery(key: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            logFailure(status, operation: "save", key: key)
            return false
        }
        return true
    }

    @discardableResult
    static func remove(key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logFailure(status, operation: "remove", key: key)
            return false
        }
        return true
    }

    private static func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Keep background refresh available after the first device unlock,
            // while preventing migration to another device through backups.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func logFailure(_ status: OSStatus, operation: String, key: String, expected: OSStatus? = nil) {
        if let expected, status == expected { return }
        // The key is a storage namespace, never a bearer credential. Logging the
        // numeric status avoids leaking token material or server responses.
        log.error("keychain (operation) failed status=\(status) account=\(key, privacy: .private(mask: .hash))")
    }
}

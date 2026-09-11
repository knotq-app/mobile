import Foundation
import Security
import os

/// Persists the push token independently of the Rust core lifecycle. Firebase
/// can issue a token before AppModel has opened its bridge, so keeping it only
/// in memory loses the registration until Firebase rotates it again.
///
/// The token is not an authentication credential, but it is still a stable
/// install identifier. Keep it device-only and out of UserDefaults/backups.
enum PushTokenStore {
    struct Registration: Codable, Equatable {
        let token: String
        let environment: String
    }

    private static let log = Logger(subsystem: "com.enigmadux.knotq", category: "push-registration")
    private static let service = "com.enigmadux.knotq.push-token"
    private static let account = "registration"

    static func load() -> Registration? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            logFailure(status, operation: "load", expected: errSecItemNotFound)
            return nil
        }
        guard let data = item as? Data,
              let registration = try? JSONDecoder().decode(Registration.self, from: data),
              !registration.token.isEmpty,
              registration.token.count <= 4096
        else {
            log.error("push token keychain payload was invalid")
            return nil
        }
        return registration
    }

    @discardableResult
    static func save(_ registration: Registration) -> Bool {
        guard !registration.token.isEmpty, registration.token.count <= 4096 else {
            return false
        }
        guard let data = try? JSONEncoder().encode(registration) else { return false }
        let query = baseQuery()
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
            logFailure(status, operation: "save")
            return false
        }
        return true
    }

    @discardableResult
    static func remove() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logFailure(status, operation: "remove")
            return false
        }
        return true
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func logFailure(_ status: OSStatus, operation: String, expected: OSStatus? = nil) {
        if let expected, status == expected { return }
        log.error("push token keychain operation=\(operation, privacy: .public) status=\(status)")
    }
}

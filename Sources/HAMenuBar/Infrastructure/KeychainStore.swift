import Foundation
import Security

/// Abstraction over secret storage so the settings logic can be tested without the Keychain.
protocol TokenStore: Sendable {
    func readToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain error \(status): \(message)"
        }
    }
}

/// Stores the HA long-lived access token as a generic password in the login Keychain.
struct KeychainTokenStore: TokenStore {
    var service = "dev.hebert.hamenubar"
    var account = "home-assistant-access-token"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func readToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "HA Menu Bar access token"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

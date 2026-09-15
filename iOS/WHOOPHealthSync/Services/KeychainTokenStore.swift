import Foundation
import Security

struct TokenBundle: Codable, Equatable {
    var email: String
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var tokenType: String
    var expiresAt: Date
}

protocol TokenStoring {
    func load() throws -> TokenBundle?
    func save(_ bundle: TokenBundle) throws
    func delete() throws
}

final class KeychainTokenStore: TokenStoring {
    private let service = "com.whoophealthsync.tokens"
    private let account = "whoop-private-api"

    func load() throws -> TokenBundle? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        guard let data = item as? Data else {
            throw KeychainError.unexpectedData
        }
        return try JSONDecoder().decode(TokenBundle.self, from: data)
    }

    func save(_ bundle: TokenBundle) throws {
        let data = try JSONEncoder().encode(bundle)
        var query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandled(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainError.unhandled(status)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: Error, LocalizedError {
    case unhandled(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case let .unhandled(status):
            return "Keychain error \(status)."
        case .unexpectedData:
            return "Keychain returned unexpected token data."
        }
    }
}

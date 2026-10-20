import Foundation
import Security

/// Host tokens live in the macOS login keychain, separate from exported connection settings.
enum HostCredentialStore {
    private static let service = "xyz.cavi.mlx-workbench.model-host"

    static func token(for id: UUID) throws -> String? {
        var query = identity(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw HostCredentialError.unavailable }
        return token
    }

    static func setToken(_ token: String?, for id: UUID) throws {
        let query = identity(id)
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw HostCredentialError.unavailable }
            return
        }
        guard token.utf8.count <= 16384,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HostCredentialError.invalidToken
        }
        let value = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw HostCredentialError.unavailable }
        } else if status != errSecSuccess { throw HostCredentialError.unavailable }
    }

    private static func identity(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

enum HostCredentialError: LocalizedError {
    case unavailable, invalidToken
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The host token could not be read or saved in Keychain."
        case .invalidToken: return "The host token is invalid."
        }
    }
}

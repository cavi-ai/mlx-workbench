import Foundation
import Security
import CryptoKit

/// Inference credentials are separate from host credentials and exported endpoint settings.
enum EndpointCredentialStore {
    private static let service = "xyz.cavi.mlx-workbench.endpoint"

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WorkflowEvidenceError.invalid("A secure API key could not be generated.")
        }
        return "mlxw_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ token: String) throws {
        guard (32...512).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw WorkflowEvidenceError.invalid("The API key must contain 32–512 printable characters without spaces.")
        }
        let hash = digest(token)
        var item = try identity(hash)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw unavailable }
    }

    static func token(for hash: String) throws -> String {
        var query = try identity(hash)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), digest(token) == hash else {
            throw unavailable
        }
        return token
    }

    static func remove(_ hash: String) throws {
        let result = SecItemDelete(try identity(hash) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw unavailable }
    }

    private static var unavailable: WorkflowEvidenceError {
        .invalid("The endpoint API key could not be read or saved in Keychain.")
    }

    private static func identity(_ hash: String) throws -> [String: Any] {
        guard !WorkbenchStatePaths.isHostedUnitTest(),
              hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw unavailable }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: hash, kSecAttrSynchronizable as String: false]
    }
}

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

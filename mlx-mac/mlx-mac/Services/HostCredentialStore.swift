import Foundation
import Security
import CryptoKit
import LocalAuthentication

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
        try withoutInteraction {
            guard (32...512).contains(token.utf8.count), token.utf8.allSatisfy({ (33...126).contains($0) }) else {
                throw WorkflowEvidenceError.invalid("The API key must contain 32–512 printable characters without spaces.")
            }
            let hash = digest(token)
            var item = try identity(hash)
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw unavailable }
        }
    }

    static func token(for hash: String) throws -> String {
        return try withoutInteraction {
            var query = try identity(hash)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data, let token = String(data: data, encoding: .utf8), digest(token) == hash else {
                throw unavailable
            }
            return token
        }
    }

    static func ensurePrivateKeyFile(for hash: String) throws -> String {
        try materializePrivateKeyFile(token(for: hash)).path
    }

    private static func keyFileURL(for hash: String, directory: URL? = nil) -> URL {
        let base = directory ?? WorkbenchStatePaths.applicationSupport().appendingPathComponent("keys", isDirectory: true)
        return base.appendingPathComponent("\(hash).key")
    }

    /// Use the same path for draft previews and confirmed launches, since the engine hashes it into the plan.
    static func materializePrivateKeyFile(_ token: String, directory: URL? = nil) throws -> (path: String, created: Bool) {
        guard token.range(of: "^[A-Za-z0-9._~-]{32,256}$", options: .regularExpression) == token.startIndex..<token.endIndex else {
            throw WorkflowEvidenceError.invalid("Shared prefix cache needs a 32–256 character URL-safe API key.")
        }
        let file = keyFileURL(for: digest(token), directory: directory)
        let base = file.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(base.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw WorkflowEvidenceError.invalid("The shared prefix cache key directory must be private.")
        }
        let data = Data((token + "\n").utf8)
        var fileInfo = stat()
        if lstat(file.path, &fileInfo) == 0 {
            guard fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_uid == getuid(),
                  fileInfo.st_mode & 0o777 == 0o600, fileInfo.st_nlink == 1, fileInfo.st_size == data.count,
                  try Data(contentsOf: file) == data else {
                throw WorkflowEvidenceError.invalid("The existing shared prefix cache key file is unavailable or not private.")
            }
            return (file.path, false)
        }
        guard errno == ENOENT else {
            throw WorkflowEvidenceError.invalid("The shared prefix cache key file is unavailable.")
        }
        try data.write(to: file, options: .withoutOverwriting)
        do { try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        catch { try? manager.removeItem(at: file); throw error }
        return (file.path, true)
    }

    static func remove(_ hash: String) throws {
        try withoutInteraction {
            let result = SecItemDelete(try identity(hash) as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw unavailable }
        }
        let file = keyFileURL(for: hash)
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }

    private static let interactionLock = NSLock()

    /// Legacy keychains need their own interaction fence; LAContext covers data-protection items.
    private static func withoutInteraction<T>(_ operation: () throws -> T) throws -> T {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw unavailable }
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try operation()
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

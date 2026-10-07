import Foundation
import Security

/// Stores per-server secrets (password or key passphrase) in the login Keychain.
nonisolated enum KeychainStore {
    private static let service = "SSHManager"

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func secret(for id: UUID) -> String? {
        secret(forAccount: id.uuidString)
    }

    static func secret(forAccount account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks for a secret without reading its value (doesn't trigger Keychain access prompts).
    static func hasSecret(for id: UUID) -> Bool {
        var query = baseQuery(for: id.uuidString)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func setSecret(_ secret: String, for id: UUID) throws {
        try setSecret(secret, forAccount: id.uuidString, label: "SSH Manager credential")
    }

    static func setSecret(_ secret: String, forAccount account: String, label: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(for: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(for: account)
            query[kSecValueData as String] = data
            query[kSecAttrLabel as String] = label
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    static func deleteSecret(for id: UUID) {
        SecItemDelete(baseQuery(for: id.uuidString) as CFDictionary)
    }

    private static func keychainError(_ status: OSStatus) -> SSHError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return SSHError("Keychain error: \(message)")
    }
}

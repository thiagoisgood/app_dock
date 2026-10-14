import Foundation
import Security

protocol SecretStorage {
    func read() throws -> String?
    func write(_ value: String) throws
}

struct KeychainSecretStorage: SecretStorage {
    private let service = Bundle.main.bundleIdentifier ?? "org.opendock.audit"
    private let account = "ai.apiKey"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CredentialError.keychainUnavailable
        }
        return value
    }

    func write(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.keychainUnavailable
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError.keychainUnavailable }
    }
}

enum CredentialError: Error, LocalizedError {
    case keychainUnavailable
    var errorDescription: String? { "无法访问钥匙串。设置未保存，请解锁钥匙串后重试。" }
}

struct APIKeyStore {
    let storage: any SecretStorage
    let defaults: UserDefaults

    init(storage: any SecretStorage = KeychainSecretStorage(), defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
    }

    func load() throws -> String {
        if let value = try storage.read() {
            defaults.removeObject(forKey: "ai.apiKey")
            return value
        }
        guard let legacy = defaults.string(forKey: "ai.apiKey"), !legacy.isEmpty else {
            defaults.removeObject(forKey: "ai.apiKey")
            return ""
        }
        // Remove the old value only after Keychain accepts the migration.
        try save(legacy)
        return legacy
    }

    func save(_ value: String) throws {
        try storage.write(value)
        defaults.removeObject(forKey: "ai.apiKey")
    }
}

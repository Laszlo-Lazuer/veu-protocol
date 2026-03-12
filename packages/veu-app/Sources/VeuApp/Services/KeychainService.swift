import Foundation
import Security
import VeuCrypto

/// Secure storage for identity and circle keys using iOS Keychain with Data Protection.
public final class KeychainService {
    
    public static let shared = KeychainService()
    
    private let service = "com.veu.protocol"
    private let identityAccount = "veu-identity"
    private let circleKeyPrefix = "veu-circle-"
    
    private init() {}
    
    // MARK: - Identity Storage
    
    /// Save identity to Keychain. Overwrites existing if present.
    public func saveIdentity(_ identity: Identity) throws {
        let data = try JSONEncoder().encode(identity)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        
        // Try to add; if exists, update
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: identityAccount
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    /// Load identity from Keychain. Returns nil if not found.
    public func loadIdentity() -> Identity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let identity = try? JSONDecoder().decode(Identity.self, from: data) else {
            return nil
        }
        
        return identity
    }
    
    /// Delete identity from Keychain.
    public func deleteIdentity() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    // MARK: - Circle Key Storage
    
    /// Save a circle key to Keychain.
    public func saveCircleKey(_ circleKey: CircleKey, for circleID: String) throws {
        let data = try JSONEncoder().encode(circleKey)
        let account = circleKeyPrefix + circleID
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        
        var status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttrs: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        }
        
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    /// Load a circle key from Keychain.
    public func loadCircleKey(for circleID: String) -> CircleKey? {
        let account = circleKeyPrefix + circleID
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let circleKey = try? JSONDecoder().decode(CircleKey.self, from: data) else {
            return nil
        }
        
        return circleKey
    }
    
    /// Delete a circle key from Keychain.
    public func deleteCircleKey(for circleID: String) {
        let account = circleKeyPrefix + circleID
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    /// Load all circle keys from Keychain (matches prefix).
    public func loadAllCircleKeys() -> [String: CircleKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return [:]
        }
        
        var keys: [String: CircleKey] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(circleKeyPrefix),
                  let data = item[kSecValueData as String] as? Data,
                  let circleKey = try? JSONDecoder().decode(CircleKey.self, from: data) else {
                continue
            }
            let circleID = String(account.dropFirst(circleKeyPrefix.count))
            keys[circleID] = circleKey
        }
        
        return keys
    }
    
    /// Delete all circle keys from Keychain.
    public func deleteAllCircleKeys() {
        // Load all to get accounts, then delete each
        let keys = loadAllCircleKeys()
        for circleID in keys.keys {
            deleteCircleKey(for: circleID)
        }
    }
}

// MARK: - Errors

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed with status \(status)"
        case .loadFailed(let status):
            return "Keychain load failed with status \(status)"
        }
    }
}

import Foundation
import Security
import VeuAuth
import VeuCrypto
import SquirrelyeyeSecurityCore

/// Secure storage for identity, circle keys, peer data, and session state
/// using SquirrelyeyeSecurityCore's KeychainStore.
public final class KeychainService {

    public static let shared = KeychainService()

    /// iCloud-synced store for data that must survive reinstall.
    /// Uses same service/accessibility as the original hand-rolled implementation
    /// so existing Keychain items are readable with zero migration.
    private let syncedStore = KeychainStore(
        serviceName: "com.veu.protocol",
        accessibility: kSecAttrAccessibleWhenUnlocked,
        iCloudSync: true
    )

    /// Device-local store for ephemeral session data (handshake keys must not sync).
    private let localStore = KeychainStore(
        serviceName: "com.veu.protocol.local",
        accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        iCloudSync: false
    )

    // MARK: - Account Keys

    private let identityAccount = "veu-identity"
    private let circleKeyPrefix = "veu-circle-"
    private let circleRegistryAccount = "veu-circle-registry"
    private let activeCircleAccount = "veu-active-circle"
    private let peerMembersPrefix = "veu-peers-"
    private let circleMetaPrefix = "veu-circlemeta-"
    private let handshakeAccount = "veu-handshake-session"

    private init() {}

    // MARK: - Identity Storage

    /// Save identity to Keychain, synced via iCloud Keychain so it survives app
    /// deletion and TestFlight ↔ Xcode switching on the same device.
    public func saveIdentity(_ identity: Identity) throws {
        try syncedStore.save(identity, for: identityAccount)
    }

    /// Load identity from Keychain. Returns nil if not found.
    public func loadIdentity() -> Identity? {
        try? syncedStore.load(Identity.self, for: identityAccount)
    }

    /// Delete identity from Keychain.
    public func deleteIdentity() {
        try? syncedStore.delete(for: identityAccount)
    }

    // MARK: - Circle Key Storage

    /// Save a circle key to Keychain, synced via iCloud Keychain so it survives
    /// app deletion and transfers across the user's devices.
    public func saveCircleKey(_ circleKey: CircleKey, for circleID: String) throws {
        let account = circleKeyPrefix + circleID
        try syncedStore.save(circleKey, for: account)
        // Update registry
        var registry = loadCircleRegistry()
        if !registry.contains(circleID) {
            registry.append(circleID)
            try? syncedStore.save(registry, for: circleRegistryAccount)
        }
    }

    /// Load a circle key from Keychain.
    public func loadCircleKey(for circleID: String) -> CircleKey? {
        let account = circleKeyPrefix + circleID
        return try? syncedStore.load(CircleKey.self, for: account)
    }

    /// Delete a circle key from Keychain.
    public func deleteCircleKey(for circleID: String) {
        let account = circleKeyPrefix + circleID
        try? syncedStore.delete(for: account)
        // Update registry
        var registry = loadCircleRegistry()
        registry.removeAll { $0 == circleID }
        try? syncedStore.save(registry, for: circleRegistryAccount)
    }

    /// Load all circle keys from Keychain using the circle registry.
    public func loadAllCircleKeys() -> [String: CircleKey] {
        let registry = loadCircleRegistry()
        var keys: [String: CircleKey] = [:]
        for circleID in registry {
            if let key = loadCircleKey(for: circleID) {
                keys[circleID] = key
            }
        }
        // Fallback: if registry is empty but we might have legacy items,
        // try the old kSecMatchLimitAll approach for one-time migration.
        if keys.isEmpty {
            let migrated = loadAllCircleKeysLegacy()
            if !migrated.isEmpty {
                // Rebuild registry from legacy items
                let ids = Array(migrated.keys)
                try? syncedStore.save(ids, for: circleRegistryAccount)
            }
            return migrated
        }
        return keys
    }

    /// Delete all circle keys from Keychain.
    public func deleteAllCircleKeys() {
        let registry = loadCircleRegistry()
        for circleID in registry {
            try? syncedStore.delete(for: circleKeyPrefix + circleID)
        }
        try? syncedStore.save([String](), for: circleRegistryAccount)
    }

    // MARK: - Active Circle Persistence

    /// Persist the active circle ID to Keychain.
    public func saveActiveCircleID(_ circleID: String) {
        guard let data = circleID.data(using: .utf8) else { return }
        try? syncedStore.save(data: data, for: activeCircleAccount)
    }

    /// Load the active circle ID from Keychain. Returns nil if not set.
    public func loadActiveCircleID() -> String? {
        guard let data = try? syncedStore.load(for: activeCircleAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the active circle ID from Keychain.
    public func deleteActiveCircleID() {
        try? syncedStore.delete(for: activeCircleAccount)
    }

    // MARK: - Peer Members Backup

    /// Save peer members for a circle (backs up circle_members to Keychain).
    public func savePeerMembers(_ members: [PeerMember], for circleID: String) {
        let account = peerMembersPrefix + circleID
        try? syncedStore.save(members, for: account)
    }

    /// Load peer members for a circle from Keychain backup.
    public func loadPeerMembers(for circleID: String) -> [PeerMember] {
        let account = peerMembersPrefix + circleID
        return (try? syncedStore.load([PeerMember].self, for: account)) ?? []
    }

    /// Delete peer members backup for a circle.
    public func deletePeerMembers(for circleID: String) {
        let account = peerMembersPrefix + circleID
        try? syncedStore.delete(for: account)
    }

    // MARK: - Circle Metadata Backup

    /// Save circle metadata (encrypted name + local alias) to Keychain.
    public func saveCircleMeta(_ meta: CircleMeta, for circleID: String) {
        let account = circleMetaPrefix + circleID
        try? syncedStore.save(meta, for: account)
    }

    /// Load circle metadata from Keychain backup.
    public func loadCircleMeta(for circleID: String) -> CircleMeta? {
        let account = circleMetaPrefix + circleID
        return try? syncedStore.load(CircleMeta.self, for: account)
    }

    /// Delete circle metadata backup.
    public func deleteCircleMeta(for circleID: String) {
        let account = circleMetaPrefix + circleID
        try? syncedStore.delete(for: account)
    }

    // MARK: - Handshake Session Persistence

    /// Save a handshake session snapshot (device-local, not synced).
    public func saveHandshakeSnapshot(_ snapshot: HandshakeSessionSnapshot) {
        try? localStore.save(snapshot, for: handshakeAccount)
    }

    /// Load a saved handshake session snapshot.
    public func loadHandshakeSnapshot() -> HandshakeSessionSnapshot? {
        try? localStore.load(HandshakeSessionSnapshot.self, for: handshakeAccount)
    }

    /// Clear the saved handshake session snapshot.
    public func clearHandshakeSnapshot() {
        try? localStore.delete(for: handshakeAccount)
    }

    // MARK: - Private Helpers

    private func loadCircleRegistry() -> [String] {
        (try? syncedStore.load([String].self, for: circleRegistryAccount)) ?? []
    }

    /// Legacy fallback: load all circle keys using kSecMatchLimitAll (pre-registry migration).
    private func loadAllCircleKeysLegacy() -> [String: CircleKey] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.veu.protocol",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
}

// MARK: - Supporting Models

/// A peer member in a circle (backed up to Keychain for reinstall recovery).
public struct PeerMember: Codable, Equatable, Sendable {
    public let deviceID: String
    public let publicKeyHex: String
    public let callsign: String
    public var localAlias: String?

    public init(deviceID: String, publicKeyHex: String, callsign: String, localAlias: String? = nil) {
        self.deviceID = deviceID
        self.publicKeyHex = publicKeyHex
        self.callsign = callsign
        self.localAlias = localAlias
    }
}

/// Circle metadata (encrypted name + local alias, backed up to Keychain).
public struct CircleMeta: Codable, Equatable, Sendable {
    public let circleID: String
    public var encryptedName: Data
    public var localAlias: String?

    public init(circleID: String, encryptedName: Data, localAlias: String? = nil) {
        self.circleID = circleID
        self.encryptedName = encryptedName
        self.localAlias = localAlias
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

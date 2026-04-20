import Foundation
import VeuAuth
import VeuCrypto
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Central application state managing identity, circles, and the active session.
public final class AppState {

    /// The device identity (persisted across launches).
    public private(set) var identity: Identity

    /// Ledger instance for circle/artifact storage.
    public let ledger: Ledger

    /// Active circle ID (nil if none selected).
    public private(set) var activeCircleID: String? {
        didSet {
            // Persist to both UserDefaults and Keychain so it survives Xcode reinstalls
            // that clear UserDefaults while leaving Keychain intact.
            if let id = activeCircleID {
                UserDefaults.standard.set(id, forKey: Self.activeCircleKey)
                KeychainService.shared.saveActiveCircleID(id)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeCircleKey)
                KeychainService.shared.deleteActiveCircleID()
            }
        }
    }

    /// Cached circle keys keyed by circle ID (backed by Keychain).
    public private(set) var circleKeys: [String: CircleKey] = [:]

    /// All known circle IDs from the Ledger.
    public private(set) var circleIDs: [String] = []
    
    // MARK: - Persistence Keys
    
    private static let activeCircleKey = "veu.activeCircleID"

    // MARK: - Init

    /// Create app state with an existing identity and ledger.
    public init(identity: Identity, ledger: Ledger) throws {
        self.identity = identity
        self.ledger = ledger
        try ledger.initializeMeta(deviceID: identity.deviceID)
        self.circleIDs = try ledger.listCircles()
    }

    /// Bootstrap app state: restore from persistence or create fresh.
    /// - Parameter ledgerPath: Path to SQLite database (defaults to Documents/veu-ledger.db).
    ///   Pass `":memory:"` for tests — this skips Keychain entirely.
    public static func bootstrap(ledgerPath: String? = nil) throws -> AppState {
        let isTestMode = ledgerPath == ":memory:"

        // 1. Resolve identity
        let identity: Identity
        if isTestMode {
            identity = Identity.generate()
        } else {
            let keychain = KeychainService.shared
            if let existing = keychain.loadIdentity() {
                identity = existing
            } else {
                identity = Identity.generate()
                try keychain.saveIdentity(identity)
            }
        }
        
        // 2. Open SQLite
        let path = ledgerPath ?? Self.defaultLedgerPath()
        let ledger = try Ledger(path: path)
        
        // 3. Create AppState
        let state = try AppState(identity: identity, ledger: ledger)
        
        // 4. Restore persisted state (skip in test mode)
        if !isTestMode {
            let keychain = KeychainService.shared
            state.circleKeys = keychain.loadAllCircleKeys()
            // Prefer Keychain for activeCircleID (survives Xcode reinstalls that clear UserDefaults).
            // Fall back to UserDefaults for compatibility.
            let savedActiveID = keychain.loadActiveCircleID()
                ?? UserDefaults.standard.string(forKey: activeCircleKey)
            if let savedActiveID, state.circleKeys[savedActiveID] != nil {
                state.activeCircleID = savedActiveID
            }
            
            // Auto-recover circles from Keychain when Ledger is empty (e.g. app reinstall).
            // Keychain persists across delete/reinstall; the Ledger DB may be recreated fresh.
            let ledgerCircles = (try? ledger.listCircles()) ?? []
            var recoveredCircles = false
            for circleID in state.circleKeys.keys where !ledgerCircles.contains(circleID) {
                recoveredCircles = true
                // Restore circle metadata (name + alias) from Keychain backup
                let meta = keychain.loadCircleMeta(for: circleID)
                let encName = meta?.encryptedName ?? Data(circleID.utf8)
                try? ledger.insertCircle(circleID: circleID, encryptedName: encName)
                if let alias = meta?.localAlias {
                    try? ledger.setCircleAlias(circleID: circleID, alias: alias)
                }
                // Restore self as member
                try? ledger.insertCircleMember(
                    circleID: circleID,
                    deviceID: identity.deviceID,
                    publicKeyHex: identity.publicKeyHex,
                    callsign: identity.callsign
                )
                // Restore peer members from Keychain backup
                let peers = keychain.loadPeerMembers(for: circleID)
                for peer in peers where peer.deviceID != identity.deviceID {
                    try? ledger.insertCircleMember(
                        circleID: circleID,
                        deviceID: peer.deviceID,
                        publicKeyHex: peer.publicKeyHex,
                        callsign: peer.callsign
                    )
                    if let alias = peer.localAlias {
                        try? ledger.setMemberAlias(circleID: circleID, deviceID: peer.deviceID, alias: alias)
                    }
                }
            }

            // Only rebuild members from artifacts when recovering from a reinstall
            // (ledger was recreated). During normal boot, trust the handshake-established members.
            if recoveredCircles {
                for circleID in state.circleKeys.keys {
                    try? state.rebuildMissingMembers(circleID: circleID)
                }
            } else {
                // Clean up any phantom stub members from previous buggy builds
                for circleID in state.circleKeys.keys {
                    let members = (try? ledger.listCircleMembers(circleID: circleID)) ?? []
                    for member in members where member.publicKeyHex == "unknown" {
                        try? ledger.removeCircleMember(circleID: circleID, deviceID: member.deviceID)
                    }
                }
            }

            // If no active circle but Keychain has keys, activate the first one
            if state.activeCircleID == nil, let firstID = state.circleKeys.keys.first {
                state.activeCircleID = firstID
            }

            state.circleIDs = (try? ledger.listCircles()) ?? []
        }
        
        return state
    }
    
    /// Default path for the persistent ledger database.
    ///
    /// Uses an App Group container (`group.com.squirrelyeye.veu`) so the
    /// database persists across app reinstalls and is shared between
    /// development (Xcode) and TestFlight builds signed with the same Team ID.
    public static func defaultLedgerPath() -> String {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let appGroupID = "group.com.squirrelyeye.veu"
        let fm = FileManager.default

        // Prefer App Group container (survives reinstalls)
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let dbURL = groupURL.appendingPathComponent("veu-ledger.db")

            // Migrate from old Documents location if needed
            let oldDocumentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("veu-ledger.db")
            if fm.fileExists(atPath: oldDocumentsURL.path) && !fm.fileExists(atPath: dbURL.path) {
                try? fm.moveItem(at: oldDocumentsURL, to: dbURL)
                // Also migrate WAL and SHM journal files
                for suffix in ["-wal", "-shm"] {
                    let oldJournal = oldDocumentsURL.deletingPathExtension()
                        .appendingPathExtension("db\(suffix)")
                    let newJournal = dbURL.deletingPathExtension()
                        .appendingPathExtension("db\(suffix)")
                    try? fm.moveItem(at: oldJournal, to: newJournal)
                }
                print("[AppState] Migrated ledger from Documents to App Group container")
            }

            // Encryption at rest
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dbURL.path
            )

            return dbURL.path
        }

        // Fallback to Documents if App Group is unavailable
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("veu-ledger.db")
        try? fm.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: dbURL.path
        )
        return dbURL.path
        #else
        // macOS: use Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let veuDir = appSupport.appendingPathComponent("Veu")
        try? FileManager.default.createDirectory(at: veuDir, withIntermediateDirectories: true)
        return veuDir.appendingPathComponent("veu-ledger.db").path
        #endif
    }

    // MARK: - Circle Management

    /// Create a brand-new circle with a random key and set it active.
    /// Returns the generated circle ID.
    @discardableResult
    public func createCircle() throws -> String {
        let circleID = UUID().uuidString
        let key = CircleKey.generate()
        try addCircle(circleID: circleID, circleKey: key)
        try setActiveCircle(circleID)
        return circleID
    }

    /// Register a new circle after a successful handshake.
    public func addCircle(circleID: String, circleKey: CircleKey, encryptedName: Data? = nil) throws {
        let name = encryptedName ?? Data(circleID.utf8)
        try ledger.insertCircle(circleID: circleID, encryptedName: name)

        // Persist to Keychain (skip for in-memory test DBs)
        if ledger.path != ":memory:" {
            try KeychainService.shared.saveCircleKey(circleKey, for: circleID)
            // Back up circle metadata
            let meta = CircleMeta(circleID: circleID, encryptedName: name)
            KeychainService.shared.saveCircleMeta(meta, for: circleID)
        }
        circleKeys[circleID] = circleKey
        circleIDs = try ledger.listCircles()
    }

    /// Switch the active circle.
    public func setActiveCircle(_ circleID: String?) throws {
        if let id = circleID {
            guard circleKeys[id] != nil else {
                throw VeuAppError.noActiveCircle
            }
        }
        activeCircleID = circleID
    }

    /// Get the circle key for the active circle.
    public func activeCircleKey() throws -> CircleKey {
        guard let id = activeCircleID, let key = circleKeys[id] else {
            throw VeuAppError.noActiveCircle
        }
        return key
    }

    /// Remove a circle and its artifacts.
    public func removeCircle(_ circleID: String) throws {
        try ledger.deleteCircle(circleID: circleID)
        KeychainService.shared.deleteCircleKey(for: circleID)
        KeychainService.shared.deletePeerMembers(for: circleID)
        KeychainService.shared.deleteCircleMeta(for: circleID)
        circleKeys.removeValue(forKey: circleID)
        if activeCircleID == circleID {
            activeCircleID = nil
        }
        circleIDs = try ledger.listCircles()
    }

    // MARK: - Circle Member Management

    /// Add a circle member to both the Ledger and Keychain backup.
    /// Use this instead of calling ledger.insertCircleMember() directly.
    public func addCircleMember(
        circleID: String,
        deviceID: String,
        publicKeyHex: String,
        callsign: String,
        localAlias: String? = nil
    ) throws {
        try ledger.insertCircleMember(
            circleID: circleID,
            deviceID: deviceID,
            publicKeyHex: publicKeyHex,
            callsign: callsign
        )
        if let alias = localAlias {
            try? ledger.setMemberAlias(circleID: circleID, deviceID: deviceID, alias: alias)
        }
        // Backup to Keychain (skip in test mode)
        if ledger.path != ":memory:" {
            backupPeerToKeychain(circleID: circleID, deviceID: deviceID,
                                 publicKeyHex: publicKeyHex, callsign: callsign,
                                 localAlias: localAlias)
        }
    }

    /// Update a member's local alias in both the Ledger and Keychain backup.
    public func setMemberAlias(circleID: String, deviceID: String, alias: String?) throws {
        try ledger.setMemberAlias(circleID: circleID, deviceID: deviceID, alias: alias)
        if ledger.path != ":memory:" {
            backupPeerToKeychain(circleID: circleID, deviceID: deviceID,
                                 publicKeyHex: "", callsign: "", localAlias: alias,
                                 updateAliasOnly: true)
        }
    }

    /// Update a circle's local alias in both the Ledger and Keychain backup.
    public func setCircleAlias(circleID: String, alias: String?) throws {
        try ledger.setCircleAlias(circleID: circleID, alias: alias)
        if ledger.path != ":memory:" {
            var meta = KeychainService.shared.loadCircleMeta(for: circleID)
                ?? CircleMeta(circleID: circleID, encryptedName: Data(circleID.utf8))
            meta.localAlias = alias
            KeychainService.shared.saveCircleMeta(meta, for: circleID)
        }
    }

    /// Rebuild missing circle_members from artifact sender_ids after a re-sync.
    public func rebuildMissingMembers(circleID: String) throws {
        let existingMembers = try ledger.listCircleMembers(circleID: circleID)
        let knownDeviceIDs = Set(existingMembers.map(\.deviceID))

        let senderIDs = try ledger.distinctSenderIDs(circleID: circleID)
        let missingIDs = senderIDs.filter { !knownDeviceIDs.contains($0) && !$0.isEmpty }

        guard !missingIDs.isEmpty else { return }

        // Check Keychain backup first
        let backedUpPeers = KeychainService.shared.loadPeerMembers(for: circleID)
        let peerLookup = Dictionary(backedUpPeers.map { ($0.deviceID, $0) },
                                    uniquingKeysWith: { a, _ in a })

        for senderID in missingIDs {
            if let peer = peerLookup[senderID] {
                try? ledger.insertCircleMember(
                    circleID: circleID,
                    deviceID: peer.deviceID,
                    publicKeyHex: peer.publicKeyHex,
                    callsign: peer.callsign
                )
                if let alias = peer.localAlias {
                    try? ledger.setMemberAlias(circleID: circleID, deviceID: peer.deviceID, alias: alias)
                }
            } else {
                // Stub entry: deviceID known from artifacts, derive callsign from prefix
                let stubCallsign = String(senderID.prefix(8)).uppercased()
                try? ledger.insertCircleMember(
                    circleID: circleID,
                    deviceID: senderID,
                    publicKeyHex: "unknown",
                    callsign: stubCallsign
                )
            }
        }
    }

    /// Refresh circle list from ledger.
    public func refreshCircles() throws {
        circleIDs = try ledger.listCircles()
    }

    // MARK: - Private Helpers

    private func backupPeerToKeychain(
        circleID: String,
        deviceID: String,
        publicKeyHex: String,
        callsign: String,
        localAlias: String?,
        updateAliasOnly: Bool = false
    ) {
        var peers = KeychainService.shared.loadPeerMembers(for: circleID)
        if let idx = peers.firstIndex(where: { $0.deviceID == deviceID }) {
            if updateAliasOnly {
                peers[idx].localAlias = localAlias
            } else {
                peers[idx] = PeerMember(deviceID: deviceID, publicKeyHex: publicKeyHex,
                                        callsign: callsign, localAlias: localAlias)
            }
        } else if !updateAliasOnly {
            peers.append(PeerMember(deviceID: deviceID, publicKeyHex: publicKeyHex,
                                    callsign: callsign, localAlias: localAlias))
        }
        KeychainService.shared.savePeerMembers(peers, for: circleID)
    }
}

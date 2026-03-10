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
            // Persist to UserDefaults
            if let id = activeCircleID {
                UserDefaults.standard.set(id, forKey: Self.activeCircleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeCircleKey)
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
    /// - Parameter ledgerPath: Path to SQLite database (defaults to Documents/veu-ledger.db)
    public static func bootstrap(ledgerPath: String? = nil) throws -> AppState {
        let keychain = KeychainService.shared
        
        // 1. Check Keychain for existing identity, or generate fresh
        let identity: Identity
        if let existing = keychain.loadIdentity() {
            identity = existing
        } else {
            identity = Identity.generate()
            try keychain.saveIdentity(identity)
        }
        
        // 2. Open persistent SQLite (or in-memory for testing)
        let path = ledgerPath ?? Self.defaultLedgerPath()
        let ledger = try Ledger(path: path)
        
        // 3. Create AppState
        let state = try AppState(identity: identity, ledger: ledger)
        
        // 4. Reload circle keys from Keychain
        state.circleKeys = keychain.loadAllCircleKeys()
        
        // 5. Restore active circle from UserDefaults
        if let savedActiveID = UserDefaults.standard.string(forKey: activeCircleKey),
           state.circleKeys[savedActiveID] != nil {
            state.activeCircleID = savedActiveID
        }
        
        return state
    }
    
    /// Default path for the persistent ledger database.
    public static func defaultLedgerPath() -> String {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dbURL = documentsURL.appendingPathComponent("veu-ledger.db")
        
        // Set NSFileProtectionComplete for encryption at rest
        try? FileManager.default.setAttributes(
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

    /// Register a new circle after a successful handshake.
    public func addCircle(circleID: String, circleKey: CircleKey) throws {
        // Store encrypted circle name (use circle ID as placeholder name)
        let encryptedName = Data(circleID.utf8)
        try ledger.insertCircle(circleID: circleID, encryptedName: encryptedName)
        
        // Persist to Keychain
        try KeychainService.shared.saveCircleKey(circleKey, for: circleID)
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
        circleKeys.removeValue(forKey: circleID)
        if activeCircleID == circleID {
            activeCircleID = nil
        }
        circleIDs = try ledger.listCircles()
    }

    /// Refresh circle list from ledger.
    public func refreshCircles() throws {
        circleIDs = try ledger.listCircles()
    }
}

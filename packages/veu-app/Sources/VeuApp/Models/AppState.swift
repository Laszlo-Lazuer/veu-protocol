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
    public private(set) var activeCircleID: String?

    /// Cached circle keys keyed by circle ID (in-memory only, never persisted).
    public private(set) var circleKeys: [String: CircleKey] = [:]

    /// All known circle IDs from the Ledger.
    public private(set) var circleIDs: [String] = []

    // MARK: - Init

    /// Create app state with an existing identity and ledger.
    public init(identity: Identity, ledger: Ledger) throws {
        self.identity = identity
        self.ledger = ledger
        try ledger.initializeMeta(deviceID: identity.deviceID)
        self.circleIDs = try ledger.listCircles()
    }

    /// Create app state with a fresh identity and in-memory ledger.
    public static func bootstrap() throws -> AppState {
        let identity = Identity.generate()
        let ledger = try Ledger(path: ":memory:")
        return try AppState(identity: identity, ledger: ledger)
    }

    // MARK: - Circle Management

    /// Register a new circle after a successful handshake.
    public func addCircle(circleID: String, circleKey: CircleKey) throws {
        // Store encrypted circle name (use circle ID as placeholder name)
        let encryptedName = Data(circleID.utf8)
        try ledger.insertCircle(circleID: circleID, encryptedName: encryptedName)
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

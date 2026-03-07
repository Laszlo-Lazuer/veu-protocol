import Foundation
import VeuAuth
import VeuCrypto
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Drives the Emerald Handshake flow, exposing bindable state for UI.
public final class HandshakeViewModel {

    // MARK: - Published state

    /// Current handshake phase (maps to EmeraldView's phase uniform).
    public private(set) var phase: HandshakePhase = .idle

    /// Dead Link URI for QR code display (available after initiate).
    public private(set) var deadLinkURI: String?

    /// 8-digit SAS short code (available after verifying).
    public private(set) var shortCode: String?

    /// Aura color hex "#RRGGBB" (available after verifying).
    public private(set) var auraColorHex: String?

    /// Derived circle key (available after confirmed).
    public private(set) var circleKey: CircleKey?

    /// Circle ID for the new circle.
    public private(set) var circleID: String

    /// Error message if handshake fails.
    public private(set) var errorMessage: String?

    // MARK: - Internal

    private let appState: AppState
    private var session: HandshakeSession

    // MARK: - Init

    public init(appState: AppState, circleID: String? = nil) {
        self.appState = appState
        self.circleID = circleID ?? UUID().uuidString
        self.session = HandshakeSession(circleID: self.circleID)
    }

    /// Reset for a new handshake.
    public func reset() {
        circleID = UUID().uuidString
        session = HandshakeSession(circleID: circleID)
        phase = .idle
        deadLinkURI = nil
        shortCode = nil
        auraColorHex = nil
        circleKey = nil
        errorMessage = nil
    }

    // MARK: - Initiator Flow

    /// Step 1 (Initiator): Generate ephemeral keypair + Dead Link URI.
    public func initiate() throws {
        let deadLink = try session.initiate(ttl: DeadLink.defaultTTL)
        deadLinkURI = deadLink.toURI()
        phase = session.phase
    }

    /// Step 2 (Initiator): Receive responder's public key data (from QR scan or network).
    public func receiveResponse(remotePublicKeyData: Data) throws {
        try session.receiveResponse(remotePublicKeyData: remotePublicKeyData)
        shortCode = session.shortCode
        auraColorHex = session.auraColorHex
        phase = session.phase
    }

    // MARK: - Responder Flow

    /// Step 1 (Responder): Parse Dead Link URI and compute shared secret.
    /// Returns our public key data to send back to initiator.
    public func respond(to uri: String) throws -> Data {
        let publicKeyData = try session.respond(to: uri)
        shortCode = session.shortCode
        auraColorHex = session.auraColorHex
        phase = session.phase
        return publicKeyData
    }

    // MARK: - Verification

    /// Confirm the short codes match — finalize the Circle key.
    public func confirm() throws {
        try session.confirm()
        circleKey = session.circleKey
        phase = session.phase

        // Register the new circle in AppState
        if let key = circleKey {
            try appState.addCircle(circleID: circleID, circleKey: key)
            try appState.setActiveCircle(circleID)
        }
    }

    /// Reject the short code — abort handshake.
    public func reject() {
        session.reject()
        phase = session.phase
        errorMessage = "Handshake rejected: codes did not match"
    }

    /// Mark the Dead Link as expired.
    public func expire() {
        session.expire()
        phase = session.phase
        errorMessage = "Dead Link expired"
    }
}

import Foundation

/// Manages the cryptographic lifecycle of artifact keys — including secure purge ("Burn").
///
/// `BurnEngine` tracks which artifact keys have been burned and provides helpers for
/// zero-filling key material in memory.
///
/// # Production Notes
/// TODO: In production, `burn(artifactKey:)` must also:
///   1. Delete the corresponding key reference from the Secure Enclave.
///   2. Publish a signed **Tombstone Revocation Packet** to the Circle's sync channel
///      so that peer devices can remove their copies of the Artifact Key from their
///      local Circle Ledgers.
public final class BurnEngine {
    private var burnedIDs = Set<UUID>()

    public init() {}

    /// Zero-fill the key material of `artifactKey` in memory and record its ID as burned.
    ///
    /// - Parameters:
    ///   - artifactKey: The key to destroy.
    ///   - artifactID:  The UUID of the artifact whose key is being burned.
    public func burn(artifactKey: ArtifactKey, artifactID: UUID) {
        // Best-effort POC zero-fill: attempt to overwrite the SymmetricKey backing bytes.
        // NOTE: SymmetricKey storage is immutable from Swift's type system; the cast to
        //       UnsafeMutableRawPointer is undefined behaviour and the compiler/runtime
        //       may optimise away the write or operate on a copy.
        // TODO: In production, replace this with Secure Enclave key deletion, which
        //       provides a hardware-guaranteed, non-recoverable purge of key material.
        artifactKey.symmetricKey.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            let mutablePtr = UnsafeMutableRawPointer(mutating: baseAddress)
            memset(mutablePtr, 0, ptr.count)
        }
        burnedIDs.insert(artifactID)
    }

    /// Returns `true` if the artifact with `artifactID` has been burned.
    public func isBurned(artifactID: UUID) -> Bool {
        burnedIDs.contains(artifactID)
    }

    /// Burn all currently tracked artifact keys by ID.
    ///
    /// Because the engine only stores IDs (not the key objects themselves after burn),
    /// this marks every previously burned ID as still burned and makes the set reflect
    /// a "total purge" state.  In a full implementation this would iterate the Circle
    /// Ledger and burn each live artifact key in turn.
    public func burnAll(artifactIDs: [UUID]) {
        for id in artifactIDs {
            burnedIDs.insert(id)
        }
    }
}

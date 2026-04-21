// BLEChunker.swift — Veu Protocol: BLE MTU-Safe Chunking & Reassembly
//
// Splits length-prefixed Ghost frames into BLE-MTU-sized chunks and
// reassembles incoming chunks back into complete frames.  Transparent
// to the layers above — BLEConnection feeds raw bytes in and gets
// complete frames out.

import Foundation

/// Splits and reassembles data frames for BLE characteristic writes.
///
/// BLE MTU is typically 20–512 bytes on iOS (negotiated per connection),
/// but Ghost messages can be up to 10 MB.  This layer handles the mismatch.
///
/// ## Chunk Format
/// ```
/// [1-byte flags][2-byte big-endian sequence][payload]
/// ```
/// - Bit 0 of flags: first chunk (payload starts with 4-byte total length)
/// - Bit 1 of flags: last chunk
///
/// Single-chunk messages have both bits set (0x03).
public struct BLEChunker {

    // MARK: - Constants

    /// Chunk header size: 1 (flags) + 2 (sequence) = 3 bytes.
    static let headerSize = 3

    /// Total-length field in the first chunk's payload.
    static let lengthFieldSize = 4

    // MARK: - Configuration

    /// Negotiated MTU for this connection (includes header overhead).
    public let mtu: Int

    /// Maximum payload bytes per chunk.
    public var payloadCapacity: Int {
        mtu - Self.headerSize
    }

    // MARK: - Init

    /// Create a chunker with the negotiated BLE MTU.
    ///
    /// - Parameter mtu: The ATT MTU minus 3 (GATT overhead), i.e. the max
    ///   characteristic value length.  Defaults to 182 (iOS typical).
    public init(mtu: Int = 182) {
        precondition(mtu > Self.headerSize + Self.lengthFieldSize,
                     "MTU too small for chunking")
        self.mtu = mtu
    }

    // MARK: - Chunking (send path)

    /// Split a complete frame into MTU-sized chunks ready for BLE writes.
    ///
    /// - Parameter data: The full frame (4-byte length prefix + sealed envelope).
    /// - Returns: An ordered array of chunk `Data` values.
    public func chunk(_ data: Data) -> [Data] {
        let totalLength = UInt32(data.count)
        let firstPayloadCap = payloadCapacity - Self.lengthFieldSize

        // Single chunk fast path
        if data.count <= firstPayloadCap {
            var chunk = Data(capacity: Self.headerSize + Self.lengthFieldSize + data.count)
            chunk.append(0x03) // first + last
            chunk.append(contentsOf: [0x00, 0x00]) // seq 0
            chunk.append(contentsOf: bigEndian32(totalLength))
            chunk.append(data)
            return [chunk]
        }

        var chunks: [Data] = []
        var offset = 0
        var seq: UInt16 = 0

        // First chunk
        let firstPayload = data[offset ..< min(offset + firstPayloadCap, data.count)]
        var first = Data(capacity: mtu)
        first.append(0x01) // first flag
        first.append(contentsOf: bigEndian16(seq))
        first.append(contentsOf: bigEndian32(totalLength))
        first.append(firstPayload)
        chunks.append(first)
        offset += firstPayload.count
        seq += 1

        // Middle + last chunks
        while offset < data.count {
            let remaining = data.count - offset
            let chunkPayloadSize = min(remaining, payloadCapacity)
            let isLast = (offset + chunkPayloadSize) >= data.count
            let flags: UInt8 = isLast ? 0x02 : 0x00

            var chunk = Data(capacity: Self.headerSize + chunkPayloadSize)
            chunk.append(flags)
            chunk.append(contentsOf: bigEndian16(seq))
            chunk.append(data[offset ..< offset + chunkPayloadSize])
            chunks.append(chunk)
            offset += chunkPayloadSize
            seq += 1
        }

        return chunks
    }

    // MARK: - Reassembly (receive path)

    /// Accumulated chunks being reassembled.
    private var buffer = Data()
    /// Expected total length from the first chunk's header.
    private var expectedLength: UInt32 = 0
    /// Next expected sequence number.
    private var nextSeq: UInt16 = 0

    /// Feed an incoming chunk.  Returns the reassembled frame when complete,
    /// or `nil` if more chunks are needed.
    ///
    /// - Parameter chunk: Raw chunk data from a BLE characteristic notification.
    /// - Returns: The complete reassembled frame, or `nil`.
    public mutating func feed(_ chunk: Data) -> Data? {
        guard chunk.count >= Self.headerSize else { return nil }

        let flags = chunk[chunk.startIndex]
        let seq = UInt16(chunk[chunk.startIndex + 1]) << 8
                | UInt16(chunk[chunk.startIndex + 2])
        let isFirst = (flags & 0x01) != 0
        let isLast  = (flags & 0x02) != 0

        if isFirst {
            // Reset reassembly state
            buffer = Data()
            nextSeq = 0
            expectedLength = 0

            let payloadStart = chunk.startIndex + Self.headerSize
            guard chunk.count >= Self.headerSize + Self.lengthFieldSize else { return nil }
            expectedLength = UInt32(chunk[payloadStart]) << 24
                           | UInt32(chunk[payloadStart + 1]) << 16
                           | UInt32(chunk[payloadStart + 2]) << 8
                           | UInt32(chunk[payloadStart + 3])
            buffer.reserveCapacity(Int(expectedLength))
            let dataStart = payloadStart + Self.lengthFieldSize
            if dataStart < chunk.endIndex {
                buffer.append(chunk[dataStart...])
            }
        } else {
            // Sequence check — drop out-of-order chunks
            guard seq == nextSeq else {
                reset()
                return nil
            }
            let payloadStart = chunk.startIndex + Self.headerSize
            if payloadStart < chunk.endIndex {
                buffer.append(chunk[payloadStart...])
            }
        }

        nextSeq = seq + 1

        if isLast {
            guard buffer.count == Int(expectedLength) else {
                reset()
                return nil
            }
            let complete = buffer
            reset()
            return complete
        }

        return nil
    }

    /// Reset reassembly state (e.g. after error or completion).
    public mutating func reset() {
        buffer = Data()
        expectedLength = 0
        nextSeq = 0
    }

    // MARK: - Helpers

    private func bigEndian32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8(value & 0xFF)]
    }

    private func bigEndian16(_ value: UInt16) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF),
         UInt8(value & 0xFF)]
    }
}

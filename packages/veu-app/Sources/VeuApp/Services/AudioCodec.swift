// AudioCodec.swift — Veu Protocol: Audio compression for voice calls
//
// Uses Apple's AudioToolbox AAC-LD (Low Delay) for compression.
// Provides encode (PCM → compressed) and decode (compressed → PCM)
// plus a jitter buffer for reordering out-of-sequence frames.

#if canImport(AVFoundation)
import AVFoundation
import AudioToolbox
import Foundation

/// Compresses and decompresses voice audio frames.
///
/// For v1, uses simple µ-law compression (G.711) which is lightweight,
/// zero-latency, and sufficient for LAN/local network voice.
/// Compresses 960 samples (20ms @ 48kHz) of Int16 → µ-law (half size).
/// Future: swap to Opus for better compression over constrained links.
public final class AudioCodec {

    public init() {}

    // MARK: - µ-law Encode/Decode

    /// Compress PCM Int16 data to µ-law (halves the size).
    public func encode(_ pcmData: Data) -> Data {
        pcmData.withUnsafeBytes { rawPtr -> Data in
            guard let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else {
                return Data()
            }
            let sampleCount = pcmData.count / 2
            var encoded = Data(count: sampleCount)
            encoded.withUnsafeMutableBytes { outPtr in
                guard let out = outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<sampleCount {
                    out[i] = Self.linearToMuLaw(ptr[i])
                }
            }
            return encoded
        }
    }

    /// Decompress µ-law data back to PCM Int16.
    public func decode(_ compressedData: Data) -> Data {
        var decoded = Data(count: compressedData.count * 2)
        compressedData.withUnsafeBytes { inPtr in
            guard let input = inPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            decoded.withUnsafeMutableBytes { outPtr in
                guard let out = outPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for i in 0..<compressedData.count {
                    out[i] = Self.muLawToLinear(input[i])
                }
            }
        }
        return decoded
    }

    // MARK: - µ-law Conversion (ITU-T G.711)

    private static let muLawBias: Int32 = 0x84
    private static let muLawClip: Int32 = 32635

    private static func linearToMuLaw(_ sample: Int16) -> UInt8 {
        var pcmValue = Int32(sample)
        let sign = (pcmValue >> 8) & 0x80
        if sign != 0 { pcmValue = -pcmValue }
        pcmValue = min(pcmValue + muLawBias, muLawClip)

        let exponent = Self.muLawExpTable[Int((pcmValue >> 7) & 0xFF)]
        let mantissa = (pcmValue >> (exponent + 3)) & 0x0F
        let muVal = ~(sign | (Int32(exponent) << 4) | mantissa)
        return UInt8(truncatingIfNeeded: muVal)
    }

    private static func muLawToLinear(_ muVal: UInt8) -> Int16 {
        var mu = Int32(~muVal)
        let sign = mu & 0x80
        let exponent = (mu >> 4) & 0x07
        let mantissa = mu & 0x0F
        var sample = Self.muLawDecompressTable[Int(exponent)] + (mantissa << (exponent + 3))
        if sign != 0 { sample = -sample }
        return Int16(clamping: sample)
    }

    private static let muLawExpTable: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            var val = i
            var exp: UInt8 = 0
            val >>= 1
            while val > 0 && exp < 7 {
                exp += 1
                val >>= 1
            }
            table[i] = exp
        }
        return table
    }()

    private static let muLawDecompressTable: [Int32] = [
        0, 132, 396, 924, 1980, 4092, 8316, 16764
    ]
}

// MARK: - Jitter Buffer

/// Reorders out-of-sequence audio frames and handles gaps.
public final class JitterBuffer {
    private var buffer: [(seq: UInt16, data: Data)] = []
    private var nextExpectedSeq: UInt16 = 0
    private let maxDelay: Int  // max frames to hold

    /// - Parameter maxDelay: Maximum number of frames to buffer (default: 5 = 100ms at 20ms/frame)
    public init(maxDelay: Int = 5) {
        self.maxDelay = maxDelay
    }

    /// Insert a received frame.
    public func insert(sequence: UInt16, data: Data) {
        // Insert sorted by sequence
        let insertIdx = buffer.firstIndex { $0.seq > sequence } ?? buffer.endIndex
        buffer.insert((seq: sequence, data: data), at: insertIdx)

        // Trim if buffer is too large
        while buffer.count > maxDelay * 2 {
            buffer.removeFirst()
        }
    }

    /// Pull the next frame in order. Returns nil if not yet available (gap).
    /// If a frame is too old (skipped), advances past it.
    public func pull() -> Data? {
        guard let first = buffer.first else { return nil }

        // If the next frame matches expected sequence, deliver it
        if first.seq == nextExpectedSeq {
            buffer.removeFirst()
            nextExpectedSeq &+= 1
            return first.data
        }

        // If we've buffered enough, skip the gap
        if buffer.count >= maxDelay {
            let frame = buffer.removeFirst()
            nextExpectedSeq = frame.seq &+ 1
            return frame.data
        }

        return nil  // Wait for missing frame
    }

    /// Reset the buffer state.
    public func reset() {
        buffer.removeAll()
        nextExpectedSeq = 0
    }
}
#endif

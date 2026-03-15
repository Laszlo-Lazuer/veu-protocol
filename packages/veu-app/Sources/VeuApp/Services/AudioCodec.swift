// AudioCodec.swift — Veu Protocol: Audio compression for voice calls
//
// Primary: Opus via AudioToolbox AudioConverter (excellent at 32kbps).
// Fallback: µ-law G.711 if Opus is unavailable on the device.
// Auto-detects format on decode based on packet size.

#if os(iOS)
import AVFoundation
import AudioToolbox
import Foundation

/// Compresses and decompresses voice audio frames.
///
/// Uses Opus for relay-quality compression (~32kbps, ~80-160 bytes/frame).
/// Falls back to µ-law G.711 (2:1, 960 bytes/frame) if Opus init fails.
/// Frame size: 960 samples = 20ms @ 48kHz mono.
public final class AudioCodec {

    private var encoder: AudioConverterRef?
    private var decoder: AudioConverterRef?

    /// Target bitrate for Opus (bits/sec). 32kbps is great for voice.
    public static let opusBitrate: UInt32 = 32_000

    private static var pcmASBD: AudioStreamBasicDescription = {
        var d = AudioStreamBasicDescription()
        d.mSampleRate = 48_000
        d.mFormatID = kAudioFormatLinearPCM
        d.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        d.mBytesPerPacket = 2
        d.mFramesPerPacket = 1
        d.mBytesPerFrame = 2
        d.mChannelsPerFrame = 1
        d.mBitsPerChannel = 16
        return d
    }()

    private static var opusASBD: AudioStreamBasicDescription = {
        var d = AudioStreamBasicDescription()
        d.mSampleRate = 48_000
        d.mFormatID = kAudioFormatOpus
        d.mChannelsPerFrame = 1
        d.mFramesPerPacket = 960
        return d
    }()

    /// Whether Opus converters were created successfully.
    public private(set) var opusAvailable: Bool = false

    public init() {
        var pcm = Self.pcmASBD
        var opus = Self.opusASBD

        var enc: AudioConverterRef?
        if AudioConverterNew(&pcm, &opus, &enc) == noErr, let e = enc {
            self.encoder = e
            var br = Self.opusBitrate
            AudioConverterSetProperty(e, kAudioConverterEncodeBitRate,
                                      UInt32(MemoryLayout<UInt32>.size), &br)
        }

        var dec: AudioConverterRef?
        if AudioConverterNew(&opus, &pcm, &dec) == noErr, let d = dec {
            self.decoder = d
        }

        opusAvailable = (encoder != nil && decoder != nil)
        print("[AudioCodec] Opus: \(opusAvailable ? "✅" : "❌ falling back to µ-law")")
    }

    deinit {
        if let e = encoder { AudioConverterDispose(e) }
        if let d = decoder { AudioConverterDispose(d) }
    }

    // MARK: - Public API

    /// Compress PCM Int16 → Opus (or µ-law fallback).
    public func encode(_ pcmData: Data) -> Data {
        if opusAvailable, let result = opusEncode(pcmData) {
            return result
        }
        return muLawEncode(pcmData)
    }

    /// Decompress audio → PCM Int16. Auto-detects Opus vs µ-law.
    /// µ-law frames are exactly 960 bytes; Opus is variable but smaller.
    public func decode(_ compressedData: Data) -> Data {
        if compressedData.count == 960 {
            return muLawDecode(compressedData)
        }
        if opusAvailable, let result = opusDecode(compressedData) {
            return result
        }
        return muLawDecode(compressedData)
    }

    // MARK: - Opus Encode

    private func opusEncode(_ pcmData: Data) -> Data? {
        guard let encoder else { return nil }

        var outData = Data(count: 512)
        var consumed = false

        let status: OSStatus = pcmData.withUnsafeBytes { inRaw in
            outData.withUnsafeMutableBytes { outRaw in
                guard let inBase = inRaw.baseAddress,
                      let outBase = outRaw.baseAddress else { return OSStatus(-1) }

                var ctx = EncodeContext(
                    ptr: UnsafeMutableRawPointer(mutating: inBase),
                    size: UInt32(pcmData.count),
                    frames: UInt32(pcmData.count / 2),
                    done: false
                )

                var outBuf = AudioBuffer(mNumberChannels: 1,
                                         mDataByteSize: UInt32(outData.count),
                                         mData: outBase)
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: outBuf)
                var numPackets: UInt32 = 1

                let res = AudioConverterFillComplexBuffer(
                    encoder, encodeInputProc, &ctx, &numPackets, &outList, nil)

                outData = Data(bytes: outList.mBuffers.mData!,
                               count: Int(outList.mBuffers.mDataByteSize))
                return res
            }
        }
        return (status == noErr && !outData.isEmpty) ? outData : nil
    }

    // MARK: - Opus Decode

    private func opusDecode(_ opusPacket: Data) -> Data? {
        guard let decoder else { return nil }

        let outBytes = 960 * 2 // 960 samples × 2 bytes
        var outData = Data(count: outBytes)

        let status: OSStatus = opusPacket.withUnsafeBytes { inRaw in
            outData.withUnsafeMutableBytes { outRaw in
                guard let inBase = inRaw.baseAddress,
                      let outBase = outRaw.baseAddress else { return OSStatus(-1) }

                var ctx = DecodeContext(
                    ptr: UnsafeRawPointer(inBase),
                    size: UInt32(opusPacket.count),
                    done: false
                )

                var outBuf = AudioBuffer(mNumberChannels: 1,
                                         mDataByteSize: UInt32(outBytes),
                                         mData: outBase)
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: outBuf)
                var numPackets: UInt32 = 960

                let res = AudioConverterFillComplexBuffer(
                    decoder, decodeInputProc, &ctx, &numPackets, &outList, nil)

                let written = Int(outList.mBuffers.mDataByteSize)
                if written > 0 && written <= outBytes {
                    outData = outData.prefix(written)
                }
                return res
            }
        }
        // -1 is returned when input callback signals "no more data" — that's fine
        return (status == noErr || status == -1) && !outData.isEmpty ? outData : nil
    }

    // MARK: - µ-law Fallback (G.711)

    private func muLawEncode(_ pcmData: Data) -> Data {
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

    private func muLawDecode(_ compressedData: Data) -> Data {
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
            while val > 0 && exp < 7 { exp += 1; val >>= 1 }
            table[i] = exp
        }
        return table
    }()

    private static let muLawDecompressTable: [Int32] = [
        0, 132, 396, 924, 1980, 4092, 8316, 16764
    ]
}

// MARK: - AudioConverter Callbacks

private struct EncodeContext {
    var ptr: UnsafeMutableRawPointer?
    var size: UInt32
    var frames: UInt32
    var done: Bool
}

private struct DecodeContext {
    var ptr: UnsafeRawPointer?
    var size: UInt32
    var done: Bool
}

private func encodeInputProc(
    _ converter: AudioConverterRef,
    _ ioNumPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outPacketDesc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let ctx = inUserData?.assumingMemoryBound(to: EncodeContext.self) else { return -1 }
    if ctx.pointee.done {
        ioNumPackets.pointee = 0
        return -1
    }
    ioNumPackets.pointee = ctx.pointee.frames
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mDataByteSize = ctx.pointee.size
    ioData.pointee.mBuffers.mData = ctx.pointee.ptr
    ctx.pointee.done = true
    return noErr
}

private func decodeInputProc(
    _ converter: AudioConverterRef,
    _ ioNumPackets: UnsafeMutablePointer<UInt32>,
    _ ioData: UnsafeMutablePointer<AudioBufferList>,
    _ outPacketDesc: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let ctx = inUserData?.assumingMemoryBound(to: DecodeContext.self) else { return -1 }
    if ctx.pointee.done {
        ioNumPackets.pointee = 0
        return -1
    }
    ioNumPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = 1
    ioData.pointee.mBuffers.mDataByteSize = ctx.pointee.size
    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.pointee.ptr)

    if let desc = outPacketDesc {
        let d = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        d.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: ctx.pointee.size)
        desc.pointee = d
    }
    ctx.pointee.done = true
    return noErr
}
#endif

// MARK: - Jitter Buffer (platform-independent)

import Foundation

/// Reorders out-of-sequence audio frames and handles gaps.
public final class JitterBuffer {
    private var buffer: [(seq: UInt16, data: Data)] = []
    private var nextExpectedSeq: UInt16 = 0
    private let maxDelay: Int

    /// - Parameter maxDelay: Maximum frames to buffer (default: 5 = 100ms at 20ms/frame)
    public init(maxDelay: Int = 5) {
        self.maxDelay = maxDelay
    }

    /// Insert a received frame.
    public func insert(sequence: UInt16, data: Data) {
        let insertIdx = buffer.firstIndex { $0.seq > sequence } ?? buffer.endIndex
        buffer.insert((seq: sequence, data: data), at: insertIdx)
        while buffer.count > maxDelay * 2 {
            buffer.removeFirst()
        }
    }

    /// Pull the next frame in order. Returns nil if not yet available.
    public func pull() -> Data? {
        guard let first = buffer.first else { return nil }
        if first.seq == nextExpectedSeq {
            buffer.removeFirst()
            nextExpectedSeq &+= 1
            return first.data
        }
        if buffer.count >= maxDelay {
            let frame = buffer.removeFirst()
            nextExpectedSeq = frame.seq &+ 1
            return frame.data
        }
        return nil
    }

    /// Reset the buffer state.
    public func reset() {
        buffer.removeAll()
        nextExpectedSeq = 0
    }
}

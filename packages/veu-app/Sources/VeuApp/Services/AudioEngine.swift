// AudioEngine.swift — Veu Protocol: Real-time audio capture and playback
//
// Uses AVAudioEngine for mic input and speaker output.
// Captures via installTap directly on inputNode (works with voice processing).
// Produces 20ms PCM buffers for encoding and accepts decoded PCM for playback.

#if os(iOS)
import AVFoundation
import Foundation

/// Captures microphone audio and plays back received audio.
public final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var isRunning = false

    /// Called with each captured PCM buffer (mono Int16, 48kHz).
    public var onCapturedBuffer: ((Data) -> Void)?

    /// Standard format: mono, 48kHz, 16-bit integer PCM
    public static let sampleRate: Double = 48_000
    public static let channels: UInt32 = 1
    public static let frameDuration: TimeInterval = 0.020  // 20ms
    public static let framesPerBuffer: UInt32 = 960         // 48000 * 0.020

    // Accumulation buffer for assembling 20ms frames from variable-size tap callbacks
    private var accumulator = Data()
    private let targetBytes = Int(framesPerBuffer) * 2  // 960 samples * 2 bytes
    private var captureCount = 0

    public init() {}

    /// Configure the audio session for voice chat.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setPreferredIOBufferDuration(Self.frameDuration)
    }

    /// Activate the audio session explicitly (for non-CallKit scenarios).
    public func activateSession() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    /// Start capturing microphone audio and preparing for playback.
    public func start(activateSession: Bool = false) throws {
        guard !isRunning else { return }
        try configureSession()
        if activateSession {
            try self.activateSession()
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let inputNode = engine.inputNode

        // .voiceChat session mode provides hardware echo cancellation, noise
        // suppression, and AGC — we do not need setVoiceProcessingEnabled(true).
        // Calling it reconfigures the inputNode into a duplex voice I/O unit which
        // silently breaks installTap (the tap registers without error but never fires).
        print("[AudioEngine] Using .voiceChat hardware echo cancellation")

        // Connect player → main mixer for playback
        let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

        // Tap inputNode directly with format:nil (use the node's native format).
        //
        // Despite common misconception, installTap on inputNode works correctly
        // even with voice processing enabled. The tap callback runs on a
        // non-realtime thread — safe for memory allocation, Opus encoding, UDP send.
        //
        // We do NOT need an intermediate mixer node. The inputNode is always
        // active because it's permanently wired to hardware input by the engine.
        // AVAudioSinkNode was the problematic approach (realtime render thread);
        // installTap is safe.
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.framesPerBuffer), format: nil) { [weak self] buffer, _ in
            guard let self = self, !self.isMuted else { return }

            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Convert the buffer's native format to Int16 mono
            var int16Bytes: Data
            if let floatData = buffer.floatChannelData?[0] {
                // Float32 non-interleaved (most common with voice processing)
                int16Bytes = Data(count: frameCount * 2)
                int16Bytes.withUnsafeMutableBytes { rawPtr in
                    guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                    for i in 0..<frameCount {
                        let sample = max(-1.0, min(1.0, floatData[i]))
                        int16Ptr[i] = Int16(sample * 32767.0)
                    }
                }
            } else if let int16Data = buffer.int16ChannelData?[0] {
                // Int16 path (less common but handle gracefully)
                int16Bytes = Data(bytes: int16Data, count: frameCount * 2)
            } else {
                return
            }

            // Accumulate into 20ms frames
            self.accumulator.append(int16Bytes)
            while self.accumulator.count >= self.targetBytes {
                let frame = self.accumulator.prefix(self.targetBytes)
                self.captureCount += 1
                if self.captureCount <= 3 || self.captureCount % 500 == 0 {
                    print("[AudioEngine] 🎤 Capture #\(self.captureCount): \(frame.count) bytes")
                }
                self.onCapturedBuffer?(Data(frame))
                self.accumulator.removeFirst(self.targetBytes)
            }
        }
        print("[AudioEngine] Tap installed on inputNode")

        engine.prepare()
        try engine.start()
        print("[AudioEngine] ✅ Engine started")

        let actualFormat = inputNode.outputFormat(forBus: 0)
        print("[AudioEngine] Input format: \(actualFormat.sampleRate)Hz, \(actualFormat.channelCount)ch, \(actualFormat.commonFormat.rawValue)")

        playerNode.play()
        playerNode.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0

        self.engine = engine
        self.playerNode = playerNode
        isRunning = true
    }

    /// Stop audio engine and release resources.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        accumulator.removeAll()
        captureCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Play received PCM audio data (mono Int16, 48kHz).
    public func playBuffer(_ pcmData: Data) {
        guard isRunning, let playerNode = playerNode else { return }

        let frameCount = UInt32(pcmData.count) / 2
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.sampleRate,
                channels: Self.channels,
                interleaved: false
            )!,
            frameCapacity: frameCount
        ) else { return }

        buffer.frameLength = frameCount
        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self),
                  let floatData = buffer.floatChannelData?[0] else { return }
            let gain: Float = 1.5
            for i in 0..<Int(frameCount) {
                let sample = (Float(int16Ptr[i]) / 32768.0) * gain
                floatData[i] = min(max(sample, -1.0), 1.0)
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Toggle mute state. Frames are not delivered while muted.
    public var isMuted: Bool = false

    /// Toggle speaker output.
    public func setSpeakerEnabled(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }
}
#endif

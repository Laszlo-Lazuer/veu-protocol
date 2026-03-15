// AudioEngine.swift — Veu Protocol: Real-time audio capture and playback
//
// Uses AVAudioEngine for mic input and speaker output.
// Captures via installTap on a mixer node after voice processing.
// Produces 20ms PCM buffers for encoding and accepts decoded PCM for playback.

#if os(iOS)
import AVFoundation
import Foundation

/// Captures microphone audio and plays back received audio.
public final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var captureMixer: AVAudioMixerNode?
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
    /// Sets category/mode/options but does NOT activate — CallKit's
    /// didActivate callback handles activation for 1:1 calls.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setPreferredIOBufferDuration(Self.frameDuration)
    }

    /// Activate the audio session explicitly (for non-CallKit scenarios like rooms).
    public func activateSession() throws {
        try AVAudioSession.sharedInstance().setActive(true)
    }

    /// Start capturing microphone audio and preparing for playback.
    /// Call configureSession() before this, or let CallKit activate the session.
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

        // Enable voice processing: echo cancellation, noise suppression, AGC
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            print("[AudioEngine] ✅ Voice processing enabled")
        } catch {
            print("[AudioEngine] ⚠️ Voice processing failed: \(error)")
        }

        // Connect player → main mixer for playback
        let mixerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: mixerFormat)

        // Use a dedicated mixer node for capture tap.
        // installTap fails on inputNode when voice processing is enabled,
        // but works on a downstream mixer node. The tap callback runs on a
        // non-realtime thread, avoiding all realtime-safety issues.
        //
        // CRITICAL: captureMixer MUST be connected to mainMixerNode (with
        // outputVolume=0) so it sits in an active signal chain. AVAudioEngine
        // only pushes audio through nodes that have a downstream path to the
        // output — an orphaned node's tap callback will never fire.
        let captureMixer = AVAudioMixerNode()
        engine.attach(captureMixer)
        engine.connect(inputNode, to: captureMixer, format: nil)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: mixerFormat)
        captureMixer.outputVolume = 0  // don't feed mic back to speaker
        self.captureMixer = captureMixer

        captureMixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.framesPerBuffer), format: mixerFormat) { [weak self] buffer, _ in
            guard let self = self, !self.isMuted else { return }

            // Convert Float32 → Int16
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let sampleCount = Int(buffer.frameLength)
            var int16Bytes = Data(count: sampleCount * 2)
            int16Bytes.withUnsafeMutableBytes { rawPtr in
                guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, floatData[i]))
                    int16Ptr[i] = Int16(sample * 32767.0)
                }
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
        print("[AudioEngine] Tap installed on capture mixer")

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
        captureMixer?.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        captureMixer = nil
        accumulator.removeAll()
        captureCount = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Play received PCM audio data (mono Int16, 48kHz).
    public func playBuffer(_ pcmData: Data) {
        guard isRunning, let playerNode = playerNode else { return }

        let frameCount = UInt32(pcmData.count) / 2  // 16-bit = 2 bytes per sample
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

        // Convert Int16 → Float32 with slight gain boost
        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let gain: Float = 1.5
            for i in 0..<Int(frameCount) {
                let sample = (Float(int16Ptr[i]) / 32768.0) * gain
                floatData[i] = min(max(sample, -1.0), 1.0)
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Toggle mute state. Audio capture continues but frames are not delivered while muted.
    public var isMuted: Bool = false

    /// Toggle speaker output.
    public func setSpeakerEnabled(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }
}
#endif

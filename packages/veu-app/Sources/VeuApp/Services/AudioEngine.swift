// AudioEngine.swift — Veu Protocol: Real-time audio capture and playback
//
// Uses AVAudioEngine for mic input and speaker output.
// Captures via AVAudioSinkNode (compatible with voice processing).
// Produces 20ms PCM buffers for encoding and accepts decoded PCM for playback.

#if os(iOS)
import AVFoundation
import Foundation

/// Captures microphone audio and plays back received audio.
public final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var sinkNode: AVAudioSinkNode?
    private var isRunning = false

    /// Called with each captured PCM buffer (mono Int16, 48kHz).
    public var onCapturedBuffer: ((Data) -> Void)?

    /// Standard format: mono, 48kHz, 16-bit integer PCM
    public static let sampleRate: Double = 48_000
    public static let channels: UInt32 = 1
    public static let frameDuration: TimeInterval = 0.020  // 20ms
    public static let framesPerBuffer: UInt32 = 960         // 48000 * 0.020

    // Accumulation buffer for assembling 20ms frames from variable-size callbacks
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

        // AVAudioSinkNode captures audio directly from the render chain.
        // This works with voice processing (unlike installTap which silently fails).
        let sink = AVAudioSinkNode { [weak self] timestamp, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let bufferListPtr = UnsafeBufferPointer(
                start: audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float32.self),
                count: Int(audioBufferList.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float32>.size
            )
            guard let baseAddress = bufferListPtr.baseAddress else { return noErr }

            // Convert Float32 → Int16 inline
            let sampleCount = Int(frameCount)
            var int16Bytes = Data(count: sampleCount * 2)
            int16Bytes.withUnsafeMutableBytes { rawPtr in
                guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for i in 0..<sampleCount {
                    let sample = max(-1.0, min(1.0, baseAddress[i]))
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
            return noErr
        }
        engine.attach(sink)
        engine.connect(inputNode, to: sink, format: nil)
        self.sinkNode = sink
        print("[AudioEngine] SinkNode attached to inputNode")

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
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        sinkNode = nil
        accumulator.removeAll()
        captureCount = 0
        isRunning = false
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

    /// Toggle mute state.
    public var isMuted: Bool = false {
        didSet {
            // With SinkNode, mute by zeroing output in the callback
            // For now, just disconnect/reconnect the sink
            guard let engine = engine, let sink = sinkNode else { return }
            if isMuted {
                engine.disconnectNodeInput(sink)
            } else {
                engine.connect(engine.inputNode, to: sink, format: nil)
            }
        }
    }

    /// Toggle speaker output.
    public func setSpeakerEnabled(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }
}
#endif

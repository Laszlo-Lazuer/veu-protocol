// AudioEngine.swift — Veu Protocol: Real-time audio capture and playback
//
// Uses AVAudioEngine for mic input and speaker output.
// Produces 20ms PCM buffers for encoding and accepts decoded PCM for playback.

#if os(iOS)
import AVFoundation
import Foundation

/// Captures microphone audio and plays back received audio.
public final class AudioEngine {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let captureFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Called with each captured 20ms PCM buffer (mono Int16, 48kHz).
    public var onCapturedBuffer: ((Data) -> Void)?

    /// Standard format: mono, 48kHz, 16-bit integer PCM
    public static let sampleRate: Double = 48_000
    public static let channels: UInt32 = 1
    public static let frameDuration: TimeInterval = 0.020  // 20ms
    public static let framesPerBuffer: UInt32 = 960         // 48000 * 0.020

    public init() {
        captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
    }

    /// Configure the audio session for voice chat.
    public func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(Self.sampleRate)
        try session.setPreferredIOBufferDuration(Self.frameDuration)
        try session.setActive(true)
    }

    /// Start capturing microphone audio and preparing for playback.
    public func start() throws {
        guard !isRunning else { return }
        try configureSession()

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Connect player → main mixer for playback
        let mixerFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: false
        )!
        engine.connect(playerNode, to: engine.mainMixerNode, format: mixerFormat)

        // Install tap on input for capture
        let bufferSize = AVAudioFrameCount(Self.framesPerBuffer)

        // Create reusable converter if input format differs from our target
        if inputFormat.sampleRate != Self.sampleRate ||
           inputFormat.channelCount != Self.channels ||
           inputFormat.commonFormat != .pcmFormatInt16 {
            self.converter = AVAudioConverter(from: inputFormat, to: captureFormat)
        } else {
            self.converter = nil
        }

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCapturedBuffer(buffer)
        }

        try engine.start()
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
        engine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
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

        // Convert Int16 → Float32 with gain boost for µ-law's limited dynamic range
        pcmData.withUnsafeBytes { rawPtr in
            guard let int16Ptr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            guard let floatData = buffer.floatChannelData?[0] else { return }
            let gain: Float = 2.0
            for i in 0..<Int(frameCount) {
                floatData[i] = (Float(int16Ptr[i]) / 32768.0) * gain
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Toggle mute state (stops/restarts mic tap).
    public var isMuted: Bool = false {
        didSet {
            guard let engine = engine else { return }
            if isMuted {
                engine.inputNode.removeTap(onBus: 0)
            } else {
                let inputFormat = engine.inputNode.outputFormat(forBus: 0)
                let bufferSize = AVAudioFrameCount(Self.framesPerBuffer)
                engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
                    self?.handleCapturedBuffer(buffer)
                }
            }
        }
    }

    /// Toggle speaker output.
    public func setSpeakerEnabled(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    // MARK: - Private

    private func handleCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = self.converter else {
            // Already in target format
            extractAndDeliver(buffer)
            return
        }

        let targetFrameCount = AVAudioFrameCount(Self.framesPerBuffer)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: targetFrameCount) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if error == nil, outputBuffer.frameLength > 0 {
            extractAndDeliver(outputBuffer)
        }
    }

    private func extractAndDeliver(_ buffer: AVAudioPCMBuffer) {
        let byteCount = Int(buffer.frameLength) * 2  // Int16 = 2 bytes
        guard let int16Data = buffer.int16ChannelData?[0] else { return }
        let data = Data(bytes: int16Data, count: byteCount)
        onCapturedBuffer?(data)
    }
}
#endif

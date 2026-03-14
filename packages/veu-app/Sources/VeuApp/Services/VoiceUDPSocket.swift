// VoiceUDPSocket.swift — Veu Protocol: UDP transport for real-time audio
//
// Sends and receives encrypted audio frames over UDP for low-latency voice.
// Each packet: [2-byte big-endian seq][AES-GCM ciphertext(12 nonce + payload + 16 tag)]
// No JSON wrapping, no GhostMessage overhead — raw encrypted bytes.

#if os(iOS)
import Foundation
import Network
import CryptoKit

/// UDP socket for sending and receiving voice audio frames.
public final class VoiceUDPSocket {
    private var listener: NWListener?
    private var sendConnection: NWConnection?
    private let queue = DispatchQueue(label: "veu.voice.udp", qos: .userInteractive)

    /// The local UDP port the listener is bound to.
    public private(set) var localPort: UInt16 = 0

    /// Called when an encrypted audio frame is received.
    public var onFrameReceived: ((Data) -> Void)?

    /// Symmetric key for per-frame AES-GCM encryption.
    private let encryptionKey: SymmetricKey

    // Diagnostic counters
    private var sendFrameCount = 0
    private var recvFrameCount = 0
    private var decryptFailCount = 0

    public init(circleKey: Data) {
        self.encryptionKey = SymmetricKey(data: circleKey)
    }

    // MARK: - Listener

    /// Start listening for incoming UDP audio frames on a system-assigned port.
    /// Blocks briefly (up to 2s) until the system assigns a port.
    public func startListening() throws {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.any), port: .any)
        params.serviceClass = .interactiveVoice

        let newListener = try NWListener(using: params)
        self.listener = newListener
        let portReady = DispatchSemaphore(value: 0)

        newListener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = newListener.port?.rawValue {
                    self?.localPort = port
                    print("[VoiceUDP] Listening on port \(port)")
                }
                portReady.signal()
            case .failed(let error):
                print("[VoiceUDP] Listener failed: \(error)")
                portReady.signal()
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingConnection(connection)
        }
        newListener.start(queue: queue)
        _ = portReady.wait(timeout: .now() + 2.0)
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        print("[VoiceUDP] 📨 New incoming UDP flow")
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[VoiceUDP] 📨 Incoming flow ready")
            case .failed(let error):
                print("[VoiceUDP] Incoming connection failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveFrames(on: connection)
    }

    private func receiveFrames(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            if let data = content, !data.isEmpty {
                self?.onFrameReceived?(data)
            }
            if error == nil {
                self?.receiveFrames(on: connection)
            }
        }
    }

    // MARK: - Sender

    /// Connect to a peer's UDP audio port for sending frames.
    public func connectToPeer(host: String, port: UInt16) {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[VoiceUDP] Connected to peer \(host):\(port)")
            case .failed(let error):
                print("[VoiceUDP] Send connection failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.sendConnection = connection
    }

    // MARK: - Send/Receive with Encryption

    /// Encrypt and send an audio frame.
    /// Frame format: [2-byte seq][compressed audio]
    /// Wire format:  [12-byte nonce][ciphertext][16-byte tag]
    public func sendFrame(_ frame: Data) {
        guard let connection = sendConnection else {
            if sendFrameCount == 0 { print("[VoiceUDP] ⚠️ No send connection") }
            return
        }
        do {
            let sealedBox = try AES.GCM.seal(frame, using: encryptionKey)
            guard let packet = sealedBox.combined else { return }
            sendFrameCount += 1
            if sendFrameCount <= 3 || sendFrameCount % 100 == 0 {
                print("[VoiceUDP] 📤 Sending frame #\(sendFrameCount) (\(packet.count) bytes)")
            }
            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    print("[VoiceUDP] Send error: \(error)")
                }
            })
        } catch {
            print("[VoiceUDP] Encryption error: \(error)")
        }
    }

    /// Decrypt a received UDP packet back to the audio frame.
    public func decryptFrame(_ packet: Data) -> Data? {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: packet)
            let decrypted = try AES.GCM.open(sealedBox, using: encryptionKey)
            recvFrameCount += 1
            if recvFrameCount <= 3 || recvFrameCount % 100 == 0 {
                print("[VoiceUDP] 📥 Received frame #\(recvFrameCount) (\(decrypted.count) bytes)")
            }
            return decrypted
        } catch {
            decryptFailCount += 1
            if decryptFailCount <= 3 {
                print("[VoiceUDP] ⚠️ Decrypt failed (\(packet.count) bytes): \(error)")
            }
            return nil
        }
    }

    // MARK: - Cleanup

    public func stop() {
        listener?.cancel()
        listener = nil
        sendConnection?.cancel()
        sendConnection = nil
        localPort = 0
        print("[VoiceUDP] Stopped")
    }
}
#endif

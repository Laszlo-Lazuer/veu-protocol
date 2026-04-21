// BLETransport.swift — Veu Protocol: Core Bluetooth Background Mesh Transport
//
// Dual-role BLE transport (central + peripheral) that operates in both
// foreground and background.  Uses GATT characteristics for bidirectional
// message exchange and State Preservation & Restoration for surviving
// app termination.
//
// With `bluetooth-central` and `bluetooth-peripheral` background modes,
// this transport keeps the mesh alive when all other transports (MPC,
// WebSocket) are killed by iOS.

#if canImport(CoreBluetooth) && os(iOS)
import Foundation
import CoreBluetooth
import VeuGhost

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Core Bluetooth mesh transport with background operation support.
///
/// Discovers peers within BLE range using dual-role operation:
/// - **Central**: Scans for peripherals advertising the circle's service UUID
/// - **Peripheral**: Advertises a GATT service for incoming connections
///
/// Each circle gets a deterministic service UUID derived from its key,
/// so devices only discover peers in the same circle.
public final class BLETransport: NSObject, MeshTransportProtocol {

    // MARK: - MeshTransportProtocol

    public let name = "BLE"
    public private(set) var state: MeshTransportState = .disconnected
    public weak var delegate: (any MeshTransportDelegate)?

    public var isAvailable: Bool {
        !connections.isEmpty
    }

    // MARK: - Configuration

    /// Default MTU for new connections before negotiation.
    private static let defaultMTU = 182

    /// Restoration identifiers for background operation.
    private static let centralRestoreID = "veu.ble.central"
    private static let peripheralRestoreID = "veu.ble.peripheral"

    // MARK: - BLE UUIDs (derived from circle key)

    /// The GATT service UUID (deterministic from circle key).
    private let serviceUUID: CBUUID
    /// Write characteristic — peers write chunked frames here.
    private let writeCharUUID: CBUUID
    /// Notify characteristic — subscribe to receive chunked frames.
    private let notifyCharUUID: CBUUID
    /// Identity characteristic — read-only, returns this device's ID.
    private let identityCharUUID: CBUUID

    // MARK: - Core Bluetooth

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    /// GATT service published by this device (as peripheral).
    private var gattService: CBMutableService?
    /// The notify characteristic instance (needed for updateValue).
    private var notifyCharacteristic: CBMutableCharacteristic?

    // MARK: - Connection Tracking

    private let circleKey: Data
    private let deviceID: String
    private let queue: DispatchQueue

    /// Active connections keyed by peer device ID.
    private var connections: [String: BLEConnection] = [:]

    /// Central-side: discovered peripherals we're connecting to or connected with.
    /// Keyed by CBPeripheral identifier UUID string.
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    /// Map from peripheral identifier → resolved peer device ID.
    private var peripheralDeviceIDs: [String: String] = [:]
    /// Central-side: write characteristics discovered on connected peripherals.
    private var peripheralWriteChars: [String: CBCharacteristic] = [:]

    /// Peripheral-side: connected centrals and their subscribed state.
    /// Keyed by CBCentral identifier UUID string.
    private var subscribedCentrals: [String: CBCentral] = [:]
    /// Map from central identifier → resolved peer device ID.
    private var centralDeviceIDs: [String: String] = [:]

    // MARK: - Init

    /// Create a BLE transport for a Circle.
    ///
    /// - Parameters:
    ///   - circleKey: The 32-byte Circle symmetric key.
    ///   - deviceID: This device's unique Veu device ID.
    public init(circleKey: Data, deviceID: String) {
        self.circleKey = circleKey
        self.deviceID = deviceID
        self.queue = DispatchQueue(label: "veu.ble.transport", qos: .userInitiated)

        // Derive deterministic UUIDs from circle key
        let hash = BLETransport.hmacSHA256(key: circleKey, data: "veu-ble-v1".data(using: .utf8)!)
        self.serviceUUID = CBUUID(data: hash.prefix(16))

        // Characteristic UUIDs: take bytes 16-31 and vary the last byte
        var writeBytes = Data(hash[16..<32])
        writeBytes[15] = 0x01
        self.writeCharUUID = CBUUID(data: writeBytes)

        var notifyBytes = Data(hash[16..<32])
        notifyBytes[15] = 0x02
        self.notifyCharUUID = CBUUID(data: notifyBytes)

        var identityBytes = Data(hash[16..<32])
        identityBytes[15] = 0x03
        self.identityCharUUID = CBUUID(data: identityBytes)

        super.init()
    }

    // MARK: - Lifecycle

    public func start() throws {
        // Initialize managers with restoration identifiers for background survival
        centralManager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreID]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: queue,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.peripheralRestoreID]
        )

        state = .connecting
        delegate?.transport(self, didChangeState: .connecting)
        print("[BLE] Transport starting — service UUID: \(serviceUUID.uuidString.prefix(8))…")
    }

    public func stop() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()

        if let service = gattService {
            peripheralManager?.remove(service)
        }

        // Disconnect all central-side peripherals
        for (_, peripheral) in discoveredPeripherals {
            centralManager?.cancelPeripheralConnection(peripheral)
        }

        connections.removeAll()
        discoveredPeripherals.removeAll()
        peripheralDeviceIDs.removeAll()
        peripheralWriteChars.removeAll()
        subscribedCentrals.removeAll()
        centralDeviceIDs.removeAll()

        centralManager = nil
        peripheralManager = nil
        gattService = nil
        notifyCharacteristic = nil

        state = .disconnected
        delegate?.transport(self, didChangeState: .disconnected)
        print("[BLE] Transport stopped")
    }

    // MARK: - GATT Service Setup (Peripheral Role)

    private func publishGATTService() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }

        // Remove old service if re-publishing
        if let existing = gattService {
            pm.remove(existing)
        }

        // Write characteristic: peers write chunked frames to us
        let writeChr = CBMutableCharacteristic(
            type: writeCharUUID,
            properties: [.writeWithoutResponse, .write],
            value: nil,
            permissions: [.writeable]
        )

        // Notify characteristic: we send chunked frames to subscribed peers
        let notifyChr = CBMutableCharacteristic(
            type: notifyCharUUID,
            properties: [.notify],
            value: nil,
            permissions: [.readable]
        )
        self.notifyCharacteristic = notifyChr

        // Identity characteristic: read-only, returns our device ID
        let identityChr = CBMutableCharacteristic(
            type: identityCharUUID,
            properties: [.read],
            value: deviceID.data(using: .utf8),
            permissions: [.readable]
        )

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [writeChr, notifyChr, identityChr]
        self.gattService = service

        pm.add(service)
    }

    private func startAdvertising() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "Veu"
        ])
        print("[BLE] Advertising started")
    }

    // MARK: - Scanning (Central Role)

    private func startScanning() {
        guard let cm = centralManager, cm.state == .poweredOn else { return }
        cm.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("[BLE] Scanning for service: \(serviceUUID.uuidString.prefix(8))���")
    }

    // MARK: - Connection Management

    /// Create or retrieve a BLEConnection for a peer, providing the write closure.
    private func getOrCreateConnection(peerDeviceID: String, writeChunks: @escaping ([Data]) -> Void, mtu: Int) -> BLEConnection {
        if let existing = connections[peerDeviceID] {
            return existing
        }
        let conn = BLEConnection(
            peerDeviceID: peerDeviceID,
            circleKey: circleKey,
            mtu: mtu,
            writeChunks: writeChunks
        )
        connections[peerDeviceID] = conn
        return conn
    }

    private func removeConnection(peerDeviceID: String) {
        guard let conn = connections.removeValue(forKey: peerDeviceID) else { return }
        conn.cancel()
        delegate?.transport(self, didDisconnectPeer: peerDeviceID)
        print("[BLE] Disconnected peer: \(peerDeviceID.prefix(8))…")

        if connections.isEmpty {
            state = .connecting
            delegate?.transport(self, didChangeState: .connecting)
        }
    }

    // MARK: - Sending via Notify (Peripheral-side outbound)

    /// Send chunks to a specific central via notify characteristic updates.
    private func sendChunksTocentral(_ centralID: String, chunks: [Data]) {
        guard let pm = peripheralManager,
              let notifyChr = notifyCharacteristic,
              let central = subscribedCentrals[centralID] else { return }
        for chunk in chunks {
            pm.updateValue(chunk, for: notifyChr, onSubscribedCentrals: [central])
        }
    }

    // MARK: - Sending via Write (Central-side outbound)

    /// Send chunks to a specific peripheral by writing to its write characteristic.
    private func sendChunksToPeripheral(_ peripheralID: String, chunks: [Data]) {
        guard let peripheral = discoveredPeripherals[peripheralID],
              let writeChr = peripheralWriteChars[peripheralID] else { return }
        for chunk in chunks {
            peripheral.writeValue(chunk, for: writeChr, type: .withoutResponse)
        }
    }

    // MARK: - Crypto

    static func hmacSHA256(key: Data, data: Data) -> Data {
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(hmac)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff, .unauthorized, .unsupported:
            state = .failed("Bluetooth \(central.state)")
            delegate?.transport(self, didChangeState: state)
        default:
            break
        }
    }

    /// State Restoration: iOS relaunched the app due to a BLE central event.
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        print("[BLE] Central restoring state…")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                peripheral.delegate = self
                let key = peripheral.identifier.uuidString
                discoveredPeripherals[key] = peripheral
                print("[BLE] Restored peripheral: \(key.prefix(8))…")

                // Re-discover services to re-establish characteristics
                if peripheral.state == .connected {
                    peripheral.discoverServices([serviceUUID])
                }
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let key = peripheral.identifier.uuidString
        guard discoveredPeripherals[key] == nil else { return } // already tracking

        print("[BLE] Discovered peripheral: \(key.prefix(8))… RSSI: \(RSSI)")
        peripheral.delegate = self
        discoveredPeripherals[key] = peripheral
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let key = peripheral.identifier.uuidString
        print("[BLE] Connected to peripheral: \(key.prefix(8))…")
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        print("[BLE] Peripheral disconnected: \(key.prefix(8))… error: \(error?.localizedDescription ?? "none")")

        discoveredPeripherals.removeValue(forKey: key)
        peripheralWriteChars.removeValue(forKey: key)
        if let peerID = peripheralDeviceIDs.removeValue(forKey: key) {
            removeConnection(peerDeviceID: peerID)
        }

        // Auto-reconnect
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let key = peripheral.identifier.uuidString
        print("[BLE] Failed to connect: \(key.prefix(8))… error: \(error?.localizedDescription ?? "unknown")")
        discoveredPeripherals.removeValue(forKey: key)
    }
}

// MARK: - CBPeripheralDelegate (Central-side: interacting with remote peripherals)

extension BLETransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics(
                [writeCharUUID, notifyCharUUID, identityCharUUID],
                for: service
            )
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        let key = peripheral.identifier.uuidString

        for chr in chars {
            if chr.uuid == writeCharUUID {
                peripheralWriteChars[key] = chr
            } else if chr.uuid == notifyCharUUID {
                // Subscribe to receive data from this peripheral
                peripheral.setNotifyValue(true, for: chr)
            } else if chr.uuid == identityCharUUID {
                // Read peer's device ID
                peripheral.readValue(for: chr)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = peripheral.identifier.uuidString

        if characteristic.uuid == identityCharUUID {
            // Peer identity resolved
            guard let data = characteristic.value,
                  let peerID = String(data: data, encoding: .utf8) else { return }

            peripheralDeviceIDs[key] = peerID

            // Negotiate MTU
            let mtu = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 20)

            let conn = getOrCreateConnection(peerDeviceID: peerID, writeChunks: { [weak self] chunks in
                self?.sendChunksToPeripheral(key, chunks: chunks)
            }, mtu: mtu)

            state = .connected
            delegate?.transport(self, didChangeState: .connected)
            delegate?.transport(self, didConnectPeer: conn)
            print("[BLE] Central-side peer resolved: \(peerID.prefix(8))… MTU: \(mtu)")

        } else if characteristic.uuid == notifyCharUUID {
            // Incoming chunk from peripheral's notify characteristic
            guard let data = characteristic.value else { return }
            if let peerID = peripheralDeviceIDs[key],
               let conn = connections[peerID] {
                conn.feedChunk(data)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // Service changed — rediscover
        peripheral.discoverServices([serviceUUID])
    }
}

// MARK: - CBPeripheralManagerDelegate (Peripheral role: serving GATT to connecting centrals)

extension BLETransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            publishGATTService()
            startAdvertising()
        case .poweredOff, .unauthorized, .unsupported:
            state = .failed("Bluetooth \(peripheral.state)")
            delegate?.transport(self, didChangeState: state)
        default:
            break
        }
    }

    /// State Restoration: iOS relaunched the app due to a BLE peripheral event.
    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        print("[BLE] Peripheral restoring state…")
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for service in services where service.uuid == serviceUUID {
                self.gattService = service
                // Find our notify characteristic
                for chr in service.characteristics ?? [] {
                    if let mutable = chr as? CBMutableCharacteristic, mutable.uuid == notifyCharUUID {
                        self.notifyCharacteristic = mutable
                    }
                }
                print("[BLE] Restored GATT service")
            }
        }
        if let advertising = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey] as? [String: Any],
           !advertising.isEmpty {
            print("[BLE] Restored advertising state")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            print("[BLE] Failed to add service: \(error)")
        } else {
            print("[BLE] GATT service published")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == notifyCharUUID else { return }
        let key = central.identifier.uuidString
        subscribedCentrals[key] = central
        print("[BLE] Central subscribed: \(key.prefix(8))… MTU: \(central.maximumUpdateValueLength)")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let key = central.identifier.uuidString
        subscribedCentrals.removeValue(forKey: key)
        if let peerID = centralDeviceIDs.removeValue(forKey: key) {
            removeConnection(peerDeviceID: peerID)
        }
        print("[BLE] Central unsubscribed: \(key.prefix(8))…")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if request.characteristic.uuid == writeCharUUID {
                guard let data = request.value else { continue }
                let centralKey = request.central.identifier.uuidString

                // First write from this central — we need to identify them.
                // The peer device ID is embedded in the first message exchange
                // via GhostMessage sync protocol.  For now, use the central's
                // UUID as a temporary ID until sync resolves it.
                if centralDeviceIDs[centralKey] == nil {
                    let tempID = "ble-\(centralKey.prefix(8))"
                    centralDeviceIDs[centralKey] = tempID
                    subscribedCentrals[centralKey] = request.central

                    let mtu = request.central.maximumUpdateValueLength
                    let conn = getOrCreateConnection(peerDeviceID: tempID, writeChunks: { [weak self] chunks in
                        self?.sendChunksTocentral(centralKey, chunks: chunks)
                    }, mtu: mtu)

                    state = .connected
                    delegate?.transport(self, didChangeState: .connected)
                    delegate?.transport(self, didConnectPeer: conn)
                    print("[BLE] Peripheral-side peer connected: \(tempID) MTU: \(mtu)")
                }

                // Feed chunk to connection
                if let peerID = centralDeviceIDs[centralKey],
                   let conn = connections[peerID] {
                    conn.feedChunk(data)
                }
            }

            // Respond to write request
            if request.characteristic.properties.contains(.write) {
                peripheral.respond(to: request, withResult: .success)
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == identityCharUUID {
            request.value = deviceID.data(using: .utf8)
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // Called when the transmit queue has space again after a failed updateValue.
        // Could implement retry logic here if needed.
    }
}
#endif

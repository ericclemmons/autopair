import Foundation
import IOBluetooth

struct BluetoothDevice: Identifiable, Hashable {
    let address: String
    let name: String
    let isConnected: Bool
    let majorClass: BluetoothDeviceClassMajor
    let minorClass: BluetoothDeviceClassMinor

    var id: String { address }

    var deviceIcon: String {
        let lowercaseName = name.lowercased()

        // Audio devices — match by name for specifics, fall back to generic
        if majorClass == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) {
            if lowercaseName.contains("airpods pro") { return "airpodspro" }
            if lowercaseName.contains("airpods max") { return "airpodsmax" }
            if lowercaseName.contains("airpods") { return "airpods.gen3" }
            return "headphones"
        }

        // Peripheral devices — use minor class bits 4-5 for type
        let peripheralType = minorClass & 0x30
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Keyboard) {
            return "keyboard.fill"
        }
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Pointing) {
            if lowercaseName.contains("trackpad") { return "hand.point.up.left.fill" }
            return "computermouse.fill"
        }
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Combo) {
            return "keyboard.fill"
        }

        return "dot.radiowaves.left.and.right"
    }

    /// Used to display saved devices that are no longer paired (e.g. after unpairing on disconnect).
    init(address: String, name: String, isConnected: Bool = false,
         majorClass: BluetoothDeviceClassMajor, minorClass: BluetoothDeviceClassMinor) {
        self.address = address
        self.name = name
        self.isConnected = isConnected
        self.majorClass = majorClass
        self.minorClass = minorClass
    }

    /// Only show devices relevant for auto-connect (peripherals + audio).
    /// Filters out phones, watches, BLE-only services, etc.
    static let supportedMajorClasses: Set<BluetoothDeviceClassMajor> = [
        BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral),
        BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio),
    ]
}

final class BluetoothManager: NSObject {
    var onConnectionChanged: (() -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []
    // Tracks connection state via IOBluetooth notifications + blueutil checks.
    // IOBluetoothDevice.isConnected() is unreliable for BLE (e.g. Magic Trackpad 2).
    private var connectedAddresses: Set<String> = []

    override init() {
        super.init()
        // Seed from IOBluetooth (classic BT)
        if let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            connectedAddresses = Set(devices.compactMap { $0.isConnected() ? $0.addressString : nil })
        }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        log.info("BluetoothManager initialized, connected=\(self.connectedAddresses)")

        // Async re-check via blueutil — covers BLE devices missed by isConnected()
        let allAddresses = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.compactMap { $0.addressString } ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let connected = Set(allAddresses.filter { Blueutil.isConnected($0) })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard connected != self.connectedAddresses else { return }
                log.info("BluetoothManager: blueutil seed updated connected=\(connected)")
                self.connectedAddresses = connected
                self.onConnectionChanged?()
            }
        }
    }

    func pairedDevices() -> [BluetoothDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log.error("pairedDevices() returned nil")
            return []
        }
        let result = devices
            .filter { BluetoothDevice.supportedMajorClasses.contains($0.deviceClassMajor) }
            .map { device -> BluetoothDevice in
                let addr = device.addressString ?? ""
                let isConnected = device.isConnected() || connectedAddresses.contains(addr)
                return BluetoothDevice(address: addr,
                                       name: device.name ?? addr,
                                       isConnected: isConnected,
                                       majorClass: device.deviceClassMajor,
                                       minorClass: device.deviceClassMinor)
            }
        log.info("pairedDevices: \(result.map { "\($0.name)(\($0.isConnected ? "on" : "off"))" }.joined(separator: ", "))")
        return result
    }

    /// Unpair all addresses sequentially on a single background thread.
    /// --unpair implicitly disconnects.
    func unpairAll(_ addresses: [String], completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for address in addresses {
                Blueutil.run(["--unpair", address])
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Power-cycle Bluetooth, pair via blueutil, connect via IOBluetooth.
    func powerCycleThenPairAndConnect(_ addresses: [String], completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            // Power cycle clears stale pairing cache so devices are discoverable
            Blueutil.run(["--power", "0"])
            Thread.sleep(forTimeInterval: 2.0)
            Blueutil.run(["--power", "1"])
            Thread.sleep(forTimeInterval: 3.0)

            // Pair each device via blueutil (handles pairing dialog suppression)
            for address in addresses {
                for attempt in 1...3 {
                    if Blueutil.run(["--pair", address]) == 0 { break }
                    if attempt < 3 {
                        Thread.sleep(forTimeInterval: Double(attempt) * 2.0)
                    }
                }
            }

            // Connect via IOBluetooth (native API, works with BLE HID)
            Thread.sleep(forTimeInterval: 2.0)
            for address in addresses {
                guard let device = IOBluetoothDevice(addressString: address) else { continue }
                if device.isConnected() { continue }
                for attempt in 1...5 {
                    let result = device.openConnection()
                    if result == kIOReturnSuccess { break }
                    if attempt < 5 {
                        Thread.sleep(forTimeInterval: Double(attempt))
                    }
                }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let addr = device.addressString ?? ""
        log.info("BT event: connected \(device.name ?? "unknown") (\(addr))")
        connectedAddresses.insert(addr)
        let disconnectNote = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        if let disconnectNote { disconnectNotifications.append(disconnectNote) }
        onConnectionChanged?()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let addr = device.addressString ?? ""
        log.info("BT event: disconnected \(device.name ?? "unknown") (\(addr))")
        connectedAddresses.remove(addr)
        onConnectionChanged?()
    }

    deinit {
        connectNotification?.unregister()
        disconnectNotifications.forEach { $0.unregister() }
    }
}

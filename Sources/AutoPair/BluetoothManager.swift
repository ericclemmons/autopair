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

    init(from device: IOBluetoothDevice) {
        address = device.addressString ?? "unknown"
        name = device.name ?? device.addressString ?? "Unknown"
        isConnected = device.isConnected()
        majorClass = device.deviceClassMajor
        minorClass = device.deviceClassMinor
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

    override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        log.info("BluetoothManager initialized")
    }

    func pairedDevices() -> [BluetoothDevice] {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log.error("pairedDevices() returned nil")
            return []
        }
        let result = devices
            .filter { BluetoothDevice.supportedMajorClasses.contains($0.deviceClassMajor) }
            .map { BluetoothDevice(from: $0) }
        log.info("pairedDevices: \(result.map { "\($0.name)(\($0.isConnected ? "on" : "off"))" }.joined(separator: ", "))")
        return result
    }

    func connect(_ address: String, attempts: Int = 5, delay: Double = 2.0) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            log.error("connect: device not found \(address)")
            return
        }
        if device.isConnected() {
            log.info("connect: \(device.name ?? address) already connected")
            return
        }
        log.info("connect: \(device.name ?? address) (attempt \(6 - attempts)/5)")
        let result = device.openConnection()
        if result == kIOReturnSuccess { return }
        guard attempts > 1 else {
            log.error("connect: \(device.name ?? address) failed after all attempts")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect(address, attempts: attempts - 1, delay: min(delay * 1.5, 10))
        }
    }

    func disconnect(_ address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            log.error("disconnect: device not found \(address)")
            return
        }
        log.info("disconnect: \(device.name ?? address)")
        let result = device.closeConnection()
        if result != kIOReturnSuccess {
            log.error("disconnect failed \(address): \(result)")
        }
    }

    func unpair(_ address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            log.error("unpair: device not found \(address)")
            return
        }
        log.info("unpair: \(device.name ?? address)")
        device.perform(Selector(("remove")))
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        log.info("BT event: connected \(device.name ?? "unknown")")
        let disconnectNote = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        if let disconnectNote { disconnectNotifications.append(disconnectNote) }
        onConnectionChanged?()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        log.info("BT event: disconnected \(device.name ?? "unknown")")
        onConnectionChanged?()
    }

    deinit {
        connectNotification?.unregister()
        disconnectNotifications.forEach { $0.unregister() }
    }
}

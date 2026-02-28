import Foundation
import IOBluetooth

struct BluetoothDevice: Identifiable, Hashable {
    let address: String
    let name: String
    let isConnected: Bool
    let majorClass: BluetoothDeviceClassMajor

    var id: String { address }

    var statusIcon: String {
        isConnected ? "bluetooth" : "bluetooth.slash"
    }

    init(from device: IOBluetoothDevice) {
        address = device.addressString ?? "unknown"
        name = device.name ?? device.addressString ?? "Unknown"
        isConnected = device.isConnected()
        majorClass = device.deviceClassMajor
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

    func connect(_ address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            log.error("connect: device not found \(address)")
            return
        }
        log.info("connect: \(device.name ?? address)")
        let result = device.openConnection()
        if result != kIOReturnSuccess {
            log.error("connect failed \(address): \(result)")
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

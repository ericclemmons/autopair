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
    // Keyed by address. Kept alive until pairing completes.
    // Keyed by address. Kept alive until pairing completes or times out.
    private var pendingPairs: [String: (IOBluetoothDevicePair, PairingDelegate)] = [:]

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

    /// Pairs with the device at `address`, suppressing the system pairing dialog.
    /// Everything runs on the main thread (IOBluetooth is not thread-safe).
    /// A 10s timeout cancels via pair.stop() and fires completion(false) as a fallback.
    func pair(_ address: String, completion: @escaping (Bool) -> Void) {
        guard let device = IOBluetoothDevice(addressString: address),
              let pair = IOBluetoothDevicePair(device: device) else {
            log.error("pair: setup failed \(address)")
            completion(false)
            return
        }
        log.info("pair: starting \(device.name ?? address)")

        var finished = false
        let finish: (Bool) -> Void = { [weak self] success in
            guard !finished else { return }
            finished = true
            self?.pendingPairs.removeValue(forKey: address)
            completion(success)
        }

        let delegate = PairingDelegate(address: address, completion: finish)
        pair.delegate = delegate
        pendingPairs[address] = (pair, delegate)

        // 10s timeout — stop() the pair attempt and fall through to connect() retry logic
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            guard !finished else { return }
            log.info("pair: timeout \(address), stopping")
            pair.stop()
            finish(false)
        }

        pair.start()
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

// MARK: - PairingDelegate

private class PairingDelegate: NSObject, IOBluetoothDevicePairDelegate {
    let address: String
    let completion: (Bool) -> Void

    init(address: String, completion: @escaping (Bool) -> Void) {
        self.address = address
        self.completion = completion
    }

    /// Auto-accept "Just Works" numeric confirmation (Magic Keyboard/Trackpad).
    /// This suppresses the system "Connection Request" dialog.
    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        log.info("pair: auto-confirming \(self.address) numericValue=\(numericValue)")
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingConnecting(_ sender: Any!) {
        log.info("pair: connecting \(self.address)")
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let success = error == kIOReturnSuccess
        log.info("pair: finished \(self.address) success=\(success) error=\(error)")
        completion(success)
    }
}

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
        if majorClass == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) {
            if lowercaseName.contains("airpods pro") { return "airpodspro" }
            if lowercaseName.contains("airpods max") { return "airpodsmax" }
            if lowercaseName.contains("airpods") { return "airpods.gen3" }
            return "headphones"
        }
        let peripheralType = minorClass & 0x30
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Keyboard) {
            return "keyboard.fill"
        }
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Pointing) {
            return lowercaseName.contains("trackpad") ? "hand.point.up.left.fill" : "computermouse.fill"
        }
        if peripheralType == BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Combo) {
            return "keyboard.fill"
        }
        return "dot.radiowaves.left.and.right"
    }

    init(address: String, name: String, isConnected: Bool = false,
         majorClass: BluetoothDeviceClassMajor, minorClass: BluetoothDeviceClassMinor) {
        self.address = address
        self.name = name
        self.isConnected = isConnected
        self.majorClass = majorClass
        self.minorClass = minorClass
    }

    static let supportedMajorClasses: Set<BluetoothDeviceClassMajor> = [
        BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral),
        BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio),
    ]
}

protocol BluetoothControlling: AnyObject {
    func acquire(_ addresses: [String], completion: @escaping (Bool) -> Void)
    func release(_ addresses: [String], completion: @escaping (Bool) -> Void)
}

/// Native Apple HID handoff, serialized away from the UI. This deliberately
/// avoids both a global Bluetooth power cycle and an external blueutil process.
final class BluetoothManager: NSObject, BluetoothControlling {
    var onConnectionChanged: (() -> Void)?

    private let queue = DispatchQueue(label: "com.ericclemmons.AutoPair.bluetooth", qos: .userInitiated)
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    override init() {
        super.init()
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
    }

    func pairedDevices() -> [BluetoothDevice] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices
            .filter { BluetoothDevice.supportedMajorClasses.contains($0.deviceClassMajor) }
            .map { device in
                let address = device.addressString ?? ""
                if device.isConnected(), disconnectNotifications[address] == nil {
                    disconnectNotifications[address] = device.register(
                        forDisconnectNotification: self,
                        selector: #selector(deviceDisconnected(_:device:))
                    )
                }
                return BluetoothDevice(
                    address: address, name: device.name ?? address,
                    isConnected: device.isConnected(),
                    majorClass: device.deviceClassMajor, minorClass: device.deviceClassMinor
                )
            }
    }

    func acquire(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        queue.async {
            var success = true
            for address in addresses where !self.acquireSync(address) { success = false }
            DispatchQueue.main.async { completion(success) }
        }
    }

    func release(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        queue.async {
            var success = true
            for address in addresses where !self.releaseSync(address) { success = false }
            DispatchQueue.main.async { completion(success) }
        }
    }

    private func acquireSync(_ address: String) -> Bool {
        guard let initial = IOBluetoothDevice(addressString: address) else {
            log.error("Bluetooth: no device object for \(address)")
            return false
        }
        if initial.isConnected() { return true }

        // Try a retained bond first. If it is stale after another Mac's handoff,
        // remove it before beginning native pairing.
        if initial.isPaired(), connectAndVerify(initial) { return true }
        if initial.isPaired() {
            guard remove(initial) else { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard let device = IOBluetoothDevice(addressString: address), pairSync(device) else {
            log.error("Bluetooth: pairing failed for \(address)")
            return false
        }
        let success = device.isConnected() || connectAndVerify(device)
        if !success { log.error("Bluetooth: connection failed after pairing for \(address)") }
        return success
    }

    private func releaseSync(_ address: String) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return true }
        guard device.isPaired() || device.isConnected() else { return true }
        guard remove(device) else {
            log.error("Bluetooth: native remove unavailable for \(address)")
            return false
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !device.isConnected() && !device.isPaired() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !device.isConnected()
    }

    private func remove(_ device: IOBluetoothDevice) -> Bool {
        let selector = NSSelectorFromString("remove")
        guard device.responds(to: selector) else { return false }
        device.perform(selector)
        return true
    }

    private func connectAndVerify(_ device: IOBluetoothDevice) -> Bool {
        for attempt in 1...3 {
            if device.openConnection() == kIOReturnSuccess {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if device.isConnected() { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            if attempt < 3 { Thread.sleep(forTimeInterval: Double(attempt)) }
        }
        return device.isConnected()
    }

    private func pairSync(_ device: IOBluetoothDevice) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        var retainedPairer: IOBluetoothDevicePair?
        var retainedDelegate: NativePairDelegate?

        DispatchQueue.main.async {
            guard let pairer = IOBluetoothDevicePair(device: device) else {
                semaphore.signal()
                return
            }
            let delegate = NativePairDelegate { success in
                result = success
                semaphore.signal()
            }
            retainedPairer = pairer
            retainedDelegate = delegate
            pairer.delegate = delegate
            if pairer.start() != kIOReturnSuccess { semaphore.signal() }
        }

        let completed = semaphore.wait(timeout: .now() + 15) == .success
        withExtendedLifetime(retainedPairer) {}
        withExtendedLifetime(retainedDelegate) {}
        return completed && result
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification,
                                       device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
        onConnectionChanged?()
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification,
                                          device: IOBluetoothDevice) {
        if let address = device.addressString { disconnectNotifications.removeValue(forKey: address) }
        onConnectionChanged?()
    }

    deinit {
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
    }
}

private final class NativePairDelegate: NSObject, IOBluetoothDevicePairDelegate {
    private let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        (sender as? IOBluetoothDevicePair)?.replyUserConfirmation(true)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        (sender as? IOBluetoothDevicePair)?.replyPINCode(0, pinCode: &pin)
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        completion(error == kIOReturnSuccess)
    }
}

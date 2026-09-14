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
    func cancelPendingOperations()
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
    private let generationLock = NSLock()
    private var operationGeneration = 0

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

    func cancelPendingOperations() {
        generationLock.lock()
        operationGeneration += 1
        generationLock.unlock()
    }

    private func generationSnapshot() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return operationGeneration
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return operationGeneration == generation
    }

    func acquire(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        let generation = generationSnapshot()
        queue.async {
            guard self.isCurrent(generation) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var success = true
            for address in addresses where self.isCurrent(generation) {
                if !self.acquireSync(address, generation: generation) { success = false }
            }
            let current = self.isCurrent(generation)
            DispatchQueue.main.async { completion(success && current) }
        }
    }

    func release(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        let generation = generationSnapshot()
        queue.async {
            guard self.isCurrent(generation) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            var success = true
            for address in addresses where self.isCurrent(generation) {
                if !self.releaseSync(address, generation: generation) { success = false }
            }
            let current = self.isCurrent(generation)
            DispatchQueue.main.async { completion(success && current) }
        }
    }

    private func acquireSync(_ address: String, generation: Int) -> Bool {
        guard let initial = IOBluetoothDevice(addressString: address) else {
            log.error("Bluetooth: no device object for \(address)")
            return false
        }
        Diagnostics.record("Bluetooth acquire: paired=\(initial.isPaired()), connected=\(initial.isConnected())")
        if initial.isConnected() { return true }

        // Try a retained bond first. If it is stale after another Mac's handoff,
        // remove it before beginning native pairing.
        if initial.isPaired(), connectAndVerify(initial, generation: generation) {
            Diagnostics.record("Bluetooth acquire: retained pairing connected")
            return true
        }
        if initial.isPaired() {
            guard remove(initial) else { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }

        guard isCurrent(generation),
              let device = IOBluetoothDevice(addressString: address),
              pairSync(device, generation: generation) else {
            log.error("Bluetooth: pairing failed for \(address)")
            Diagnostics.record("Bluetooth acquire: native pairing failed")
            return false
        }
        let success = device.isConnected() || connectAndVerify(device, generation: generation)
        if !success { log.error("Bluetooth: connection failed after pairing for \(address)") }
        Diagnostics.record("Bluetooth acquire: post-pair connection \(success ? "succeeded" : "failed")")
        return success
    }

    private func releaseSync(_ address: String, generation: Int) -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return true }
        Diagnostics.record("Bluetooth release: paired=\(device.isPaired()), connected=\(device.isConnected())")
        guard device.isPaired() || device.isConnected() else { return true }
        guard remove(device) else {
            log.error("Bluetooth: native remove unavailable for \(address)")
            return false
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            guard isCurrent(generation) else { return false }
            if !device.isConnected() && !device.isPaired() {
                Diagnostics.record("Bluetooth release: disconnected and pairing removed")
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let disconnected = !device.isConnected()
        Diagnostics.record("Bluetooth release: deadline reached, disconnected=\(disconnected), paired=\(device.isPaired())")
        return disconnected
    }

    private func remove(_ device: IOBluetoothDevice) -> Bool {
        let selector = NSSelectorFromString("remove")
        guard device.responds(to: selector) else { return false }
        device.perform(selector)
        return true
    }

    private func connectAndVerify(_ device: IOBluetoothDevice, generation: Int) -> Bool {
        for attempt in 1...2 {
            guard isCurrent(generation) else { return false }
            if device.openConnection() == kIOReturnSuccess {
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    guard isCurrent(generation) else { return false }
                    if device.isConnected() { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 1) }
        }
        return device.isConnected()
    }

    private func pairSync(_ device: IOBluetoothDevice, generation: Int) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var result = false
        var retainedPairer: IOBluetoothDevicePair?
        var retainedDelegate: NativePairDelegate?

        DispatchQueue.main.async {
            guard self.isCurrent(generation) else {
                semaphore.signal()
                return
            }
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

        let deadline = Date().addingTimeInterval(8)
        var completed = false
        while isCurrent(generation), Date() < deadline {
            if semaphore.wait(timeout: .now() + 0.2) == .success {
                completed = true
                break
            }
        }
        if !isCurrent(generation) { retainedPairer?.stop() }
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

import SwiftUI

@Observable
final class AppState {
    var pairedDevices: [BluetoothDevice] = []
    var savedAddresses: Set<String> = []

    private let bluetooth = BluetoothManager()
    private let powerMonitor = PowerMonitor()
    private let sleepWakeMonitor = SleepWakeMonitor()

    private let savedKey = "AutoPairSavedDevices"

    init() {
        loadSaved()
        setupMonitors()
        refreshDevices()
        log.info("AppState: init, saved=\(self.savedAddresses.joined(separator: ", "))")
    }

    func refreshDevices() {
        pairedDevices = bluetooth.pairedDevices()
    }

    func toggleDevice(_ address: String) {
        if savedAddresses.contains(address) {
            savedAddresses.remove(address)
        } else {
            savedAddresses.insert(address)
        }
        persistSaved()
        log.info("AppState: toggled \(address), saved=\(self.savedAddresses.joined(separator: ", "))")
    }

    func isDeviceSaved(_ address: String) -> Bool {
        savedAddresses.contains(address)
    }

    func connectSaved() {
        log.info("AppState: connectSaved (\(self.savedAddresses.count) devices)")
        for address in savedAddresses {
            bluetooth.connect(address)
        }
        refreshDevices()
    }

    func disconnectSaved() {
        log.info("AppState: disconnectSaved (\(self.savedAddresses.count) devices)")
        for address in savedAddresses {
            bluetooth.disconnect(address)
        }
        refreshDevices()
    }

    // MARK: - Private

    private func setupMonitors() {
        bluetooth.onConnectionChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshDevices() }
        }

        powerMonitor.onACPower = { [weak self] in
            log.info("→ AC power: connecting saved devices")
            self?.connectSaved()
        }
        powerMonitor.onBattery = { [weak self] in
            log.info("→ Battery: disconnecting saved devices")
            self?.disconnectSaved()
        }

        sleepWakeMonitor.onSleep = { [weak self] in
            log.info("→ Sleep: disconnecting")
            self?.disconnectSaved()
        }
        sleepWakeMonitor.onWake = { [weak self] in
            guard let self else { return }
            let onAC = self.powerMonitor.isOnAC
            log.info("→ Wake: onAC=\(onAC)")
            if onAC {
                self.connectSaved()
            }
        }
    }

    private func loadSaved() {
        if let arr = UserDefaults.standard.stringArray(forKey: savedKey) {
            savedAddresses = Set(arr)
        }
    }

    private func persistSaved() {
        UserDefaults.standard.set(Array(savedAddresses), forKey: savedKey)
    }
}

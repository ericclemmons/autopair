import SwiftUI

@Observable
final class AppState {
    var pairedDevices: [BluetoothDevice] = []
    var savedAddresses: Set<String> = []
    var displayName: String = ""

    private let bluetooth = BluetoothManager()
    private let displayMonitor = DisplayMonitor()

    private let savedKey = "AutoPairSavedDevices"
    private var refreshWorkItem: DispatchWorkItem?

    init() {
        loadSaved()
        setupMonitors()
        refreshDevices()
        displayName = displayMonitor.currentDisplayName ?? ""
        log.info("AppState: init, saved=\(self.savedAddresses.joined(separator: ", ")), display=\(self.displayName)")
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

    // MARK: - Private

    private func setupMonitors() {
        bluetooth.onConnectionChanged = { [weak self] in
            self?.refreshWorkItem?.cancel()
            let work = DispatchWorkItem { self?.refreshDevices() }
            self?.refreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        displayMonitor.onDisplayConnected = { [weak self] name in
            log.info("→ Display connected: \(name)")
            self?.displayName = name
            // Brief delay lets devices enter pairing mode if previously unpaired
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.pairAndConnectSaved()
            }
        }

        displayMonitor.onDisplayDisconnected = { [weak self] in
            log.info("→ Display disconnected: unpairing saved devices")
            self?.displayName = ""
            self?.disconnectAndUnpairSaved()
        }
    }

    private func pairAndConnectSaved() {
        log.info("AppState: pairAndConnectSaved (\(self.savedAddresses.count) devices)")
        for address in savedAddresses {
            bluetooth.pair(address) { [weak self] success in
                log.info("AppState: pair \(address) success=\(success), connecting...")
                self?.bluetooth.connect(address)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshDevices()
        }
    }

    private func disconnectAndUnpairSaved() {
        log.info("AppState: disconnectAndUnpairSaved (\(self.savedAddresses.count) devices)")
        for address in savedAddresses {
            bluetooth.disconnect(address)
            bluetooth.unpair(address)
        }
        refreshDevices()
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

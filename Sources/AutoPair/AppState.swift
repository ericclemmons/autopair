import IOBluetooth
import SwiftUI

/// Persisted metadata for a saved device so it stays visible in the menu
/// even after being unpaired (e.g. on display disconnect).
struct SavedDeviceInfo: Codable {
    let address: String
    let name: String
    let majorClass: UInt32
    let minorClass: UInt32

    func toBluetoothDevice(isConnected: Bool = false) -> BluetoothDevice {
        BluetoothDevice(address: address, name: name, isConnected: isConnected,
                        majorClass: BluetoothDeviceClassMajor(majorClass),
                        minorClass: BluetoothDeviceClassMinor(minorClass))
    }
}

@Observable
final class AppState {
    var pairedDevices: [BluetoothDevice] = []
    var savedAddresses: Set<String> = []
    var displayName: String = ""

    /// Devices shown in the "saved" section — uses live data when paired,
    /// falls back to stored metadata when device is unpaired.
    var menuSavedDevices: [BluetoothDevice] {
        let liveByAddress = Dictionary(uniqueKeysWithValues: pairedDevices.map { ($0.address, $0) })
        return savedAddresses.sorted().compactMap { address in
            liveByAddress[address] ?? savedDeviceInfo[address]?.toBluetoothDevice()
        }
    }

    private let bluetooth = BluetoothManager()
    private let displayMonitor = DisplayMonitor()

    private let savedKey = "AutoPairSavedDevices"
    private let savedInfoKey = "AutoPairSavedDeviceInfo"
    private var savedDeviceInfo: [String: SavedDeviceInfo] = [:]
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
            savedDeviceInfo.removeValue(forKey: address)
        } else {
            savedAddresses.insert(address)
            if let device = pairedDevices.first(where: { $0.address == address }) {
                savedDeviceInfo[address] = SavedDeviceInfo(
                    address: address,
                    name: device.name,
                    majorClass: device.majorClass,
                    minorClass: device.minorClass
                )
            }
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
            DispatchQueue.main.async { self?.displayName = name }
            // Delay lets unpaired devices enter pairing mode before we attempt openConnection().
            // openConnection() on an unpaired-but-advertising device triggers automatic re-pairing
            // (Just Works) without needing IOBluetoothDevicePair.
            let addresses = self?.savedAddresses ?? []
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) { [weak self] in
                log.info("AppState: connectSaved (\(addresses.count) devices)")
                for address in addresses {
                    self?.bluetooth.connect(address)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self?.refreshDevices() }
            }
        }

        displayMonitor.onDisplayDisconnected = { [weak self] in
            log.info("→ Display disconnected")
            DispatchQueue.main.async { self?.displayName = "" }
            let addresses = self?.savedAddresses ?? []
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                log.info("AppState: disconnectAndUnpairSaved (\(addresses.count) devices)")
                for address in addresses {
                    self?.bluetooth.disconnect(address)
                    self?.bluetooth.unpair(address)
                }
                DispatchQueue.main.async { self?.refreshDevices() }
            }
        }
    }

    private func loadSaved() {
        if let arr = UserDefaults.standard.stringArray(forKey: savedKey) {
            savedAddresses = Set(arr)
        }
        if let data = UserDefaults.standard.data(forKey: savedInfoKey),
           let info = try? JSONDecoder().decode([String: SavedDeviceInfo].self, from: data) {
            savedDeviceInfo = info
        }
    }

    private func persistSaved() {
        UserDefaults.standard.set(Array(savedAddresses), forKey: savedKey)
        if let data = try? JSONEncoder().encode(savedDeviceInfo) {
            UserDefaults.standard.set(data, forKey: savedInfoKey)
        }
    }
}

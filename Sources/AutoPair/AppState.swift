import IOBluetooth
import SwiftUI

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
    var signalName: String = ""
    var peerCount = 0
    var handoffState: HandoffController.State = .idle
    private(set) var triggerKind: OwnershipTriggerKind

    var menuSavedDevices: [BluetoothDevice] {
        let liveByAddress = Dictionary(uniqueKeysWithValues: pairedDevices.map { ($0.address, $0) })
        return savedAddresses.sorted().compactMap { address in
            liveByAddress[address] ?? savedDeviceInfo[address]?.toBluetoothDevice()
        }
    }

    var statusText: String {
        switch handoffState {
        case .releasing: "Releasing devices…"
        case .waitingForRelease: "Waiting for other Mac to release…"
        case .acquiring: "Connecting devices…"
        case .owned: "Devices connected"
        case .failed: "Handoff failed — wake the device and retry"
        case .idle:
            signalName.isEmpty ? triggerKind.inactiveTitle : signalName
        }
    }

    private let bluetooth = BluetoothManager()
    private let peers = PeerManager()
    private var trigger: OwnershipTrigger?
    @ObservationIgnored private lazy var handoff = HandoffController(
        bluetooth: bluetooth,
        peers: peers,
        addresses: { [weak self] in Array(self?.savedAddresses ?? []) }
    )

    private let savedKey = "AutoPairSavedDevices"
    private let savedInfoKey = "AutoPairSavedDeviceInfo"
    private let triggerKey = "AutoPairOwnershipTrigger"
    private var savedDeviceInfo: [String: SavedDeviceInfo] = [:]
    private var refreshWorkItem: DispatchWorkItem?

    init() {
        let rawTrigger = UserDefaults.standard.string(forKey: triggerKey)
        triggerKind = OwnershipTriggerKind(rawValue: rawTrigger ?? "") ?? .externalDisplay
        loadSaved()
        refreshDevices()
        backfillDeviceInfo()
        setupServices()
        configureTrigger(triggerKind)
        log.info("AppState: init, trigger=\(self.triggerKind.rawValue), saved=\(self.savedAddresses.count)")
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
                    address: address, name: device.name,
                    majorClass: device.majorClass, minorClass: device.minorClass
                )
            }
        }
        persistSaved()
    }

    func isDeviceSaved(_ address: String) -> Bool { savedAddresses.contains(address) }

    func setTriggerKind(_ kind: OwnershipTriggerKind) {
        guard triggerKind != kind else { return }
        triggerKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: triggerKey)
        configureTrigger(kind)
    }

    func retryHandoff() {
        handoff.ownershipChanged(isActive: trigger?.isActive == true)
    }

    private func setupServices() {
        bluetooth.onConnectionChanged = { [weak self] in
            self?.refreshWorkItem?.cancel()
            let work = DispatchWorkItem { self?.refreshDevices() }
            self?.refreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        handoff.onStateChange = { [weak self] state in
            self?.handoffState = state
            if state == .owned || state == .failed { self?.refreshDevices() }
        }
        peers.onPeerCountChanged = { [weak self] in self?.peerCount = $0 }
        peers.onReleaseRequest = { [weak self] requested, completion in
            guard let self else { completion(false); return }
            let allowed = requested.filter { self.savedAddresses.contains($0) }
            guard !allowed.isEmpty else { completion(false); return }
            self.handoff.releaseForPeer(allowed) { [weak self] success in
                self?.refreshDevices()
                completion(success)
            }
        }
        peers.start()
    }

    private func configureTrigger(_ kind: OwnershipTriggerKind) {
        trigger?.stop()
        let newTrigger = OwnershipTriggerFactory.make(kind)
        trigger = newTrigger
        newTrigger.onChange = { [weak self, weak newTrigger] active, name in
            guard let self, self.trigger === newTrigger else { return }
            self.signalName = active ? (name ?? kind.title) : ""
            self.handoff.ownershipChanged(isActive: active)
        }
        newTrigger.start()
        signalName = newTrigger.isActive ? (newTrigger.activeName ?? kind.title) : ""

        // Claim on launch/config change if the selected physical signal is present.
        if newTrigger.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak newTrigger] in
                guard let self, self.trigger === newTrigger else { return }
                self.handoff.ownershipChanged(isActive: true)
            }
        } else {
            handoff.ownershipChanged(isActive: false)
        }
    }

    private func backfillDeviceInfo() {
        var changed = false
        for device in pairedDevices where savedAddresses.contains(device.address)
            && savedDeviceInfo[device.address] == nil {
            savedDeviceInfo[device.address] = SavedDeviceInfo(
                address: device.address, name: device.name,
                majorClass: device.majorClass, minorClass: device.minorClass
            )
            changed = true
        }
        if changed { persistSaved() }
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

    deinit {
        trigger?.stop()
        peers.stop()
    }
}

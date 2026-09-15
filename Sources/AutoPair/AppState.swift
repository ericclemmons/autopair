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
    var discoveredComputers: [ComputerInfo] = []
    var trustedComputers: [TrustedComputer] = []
    var handoffState: HandoffController.State = .idle
    var onStatusChange: (() -> Void)?
    private(set) var triggerKind: OwnershipTriggerKind
    private(set) var selectedHardware: HardwareIdentity? = nil

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
    private let sleepMonitor = SleepMonitor()
    private var trigger: OwnershipTrigger?
    @ObservationIgnored private lazy var handoff = HandoffController(
        bluetooth: bluetooth,
        peers: peers,
        addresses: { [weak self] in Array(self?.savedAddresses ?? []) }
    )

    private let savedKey = "AutoPairSavedDevices"
    private let savedInfoKey = "AutoPairSavedDeviceInfo"
    private let triggerKey = "AutoPairOwnershipTrigger"
    private let hardwareKey = "AutoPairOwnershipHardware"
    private var savedDeviceInfo: [String: SavedDeviceInfo] = [:]
    private var refreshWorkItem: DispatchWorkItem?

    init() {
        let rawTrigger = UserDefaults.standard.string(forKey: triggerKey)
        if rawTrigger == "calDigitDock" {
            triggerKind = .connectedHardware
            selectedHardware = HardwareIdentity(
                transport: .usb, vendorID: 0x2188, productID: nil,
                vendorName: "CalDigit", productName: "CalDigit connected hardware",
                serialNumber: nil
            )
            UserDefaults.standard.set(OwnershipTriggerKind.connectedHardware.rawValue,
                                      forKey: "AutoPairOwnershipTrigger")
            if let selectedHardware, let data = try? JSONEncoder().encode(selectedHardware) {
                UserDefaults.standard.set(data, forKey: "AutoPairOwnershipHardware")
            }
        } else {
            triggerKind = OwnershipTriggerKind(rawValue: rawTrigger ?? "") ?? .externalDisplay
            if let data = UserDefaults.standard.data(forKey: hardwareKey) {
                selectedHardware = try? JSONDecoder().decode(HardwareIdentity.self, from: data)
            }
        }
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
        guard kind == .externalDisplay, triggerKind != kind else { return }
        triggerKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: triggerKey)
        configureTrigger(kind)
    }

    func setHardwareTrigger(_ hardware: HardwareIdentity) {
        guard triggerKind != .connectedHardware || selectedHardware != hardware else { return }
        selectedHardware = hardware
        triggerKind = .connectedHardware
        UserDefaults.standard.set(triggerKind.rawValue, forKey: triggerKey)
        if let data = try? JSONEncoder().encode(hardware) {
            UserDefaults.standard.set(data, forKey: hardwareKey)
        }
        configureTrigger(.connectedHardware)
    }

    func availableHardware() -> [HardwareIdentity] { HardwareRegistry.attachedHardware() }

    var thisComputer: ComputerInfo { peers.thisComputer }

    func generatePairingCode() -> String { peers.generatePairingCode() }

    func cancelPairingCode() { peers.cancelPairingCode() }

    func pairComputer(_ id: String, code: String,
                      completion: @escaping (Result<TrustedComputer, ComputerPairingError>) -> Void) {
        peers.pair(with: id, code: code, completion: completion)
    }

    func forgetComputer(_ id: String) { peers.forgetComputer(id) }

    func retryHandoff() {
        handoff.retryOwnership(isActive: trigger?.isActive == true)
    }

    private func setupServices() {
        sleepMonitor.onWillSleep = { [weak self] completion in
            guard let self else { completion(); return }
            // Dock attachment can itself produce a transient sleep notification
            // during clamshell/login transitions. Let IOKit detach events settle,
            // then release only if this Mac has actually lost ownership.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { completion(); return }
                self.handoff.prepareForSleep(
                    isOwnershipActive: self.trigger?.isActive == true,
                    completion: completion
                )
            }
        }
        sleepMonitor.onDidWake = { [weak self] in
            guard let self else { return }
            Diagnostics.record("system woke; reconciling current ownership")
            self.handoff.retryOwnership(isActive: self.trigger?.isActive == true)
        }
        sleepMonitor.start()
        bluetooth.onConnectionChanged = { [weak self] in
            self?.refreshWorkItem?.cancel()
            let work = DispatchWorkItem { self?.refreshDevices() }
            self?.refreshWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        handoff.onStateChange = { [weak self] state in
            self?.handoffState = state
            if state == .owned || state == .failed { self?.refreshDevices() }
            self?.onStatusChange?()
        }
        peers.onComputersChanged = { [weak self] discovered, trusted in
            self?.discoveredComputers = discovered
            self?.trustedComputers = trusted
        }
        peers.onReleaseRequest = { [weak self] requested, completion in
            guard let self else { completion(false); return }
            let allowed = requested.filter { self.savedAddresses.contains($0) }
            guard !allowed.isEmpty else { completion(false); return }
            self.handoff.releaseForPeer(
                allowed, isOwnershipActive: self.trigger?.isActive == true
            ) { [weak self] success in
                self?.refreshDevices()
                completion(success)
            }
        }
        peers.start()
    }

    private func configureTrigger(_ kind: OwnershipTriggerKind) {
        trigger?.stop()
        guard let newTrigger = OwnershipTriggerFactory.make(kind, hardware: selectedHardware) else {
            trigger = nil
            signalName = "Choose connected hardware"
            handoff.ownershipChanged(isActive: false)
            return
        }
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
        sleepMonitor.stop()
        trigger?.stop()
        peers.stop()
    }
}

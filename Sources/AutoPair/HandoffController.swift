import Foundation

protocol PeerCoordinating: AnyObject {
    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void)
    func peerWantsDevices(completion: @escaping (Bool) -> Void)
}

/// Coordinates the ordered release -> acquire transaction. Trigger monitors,
/// peer transport, and Bluetooth are deliberately separate dependencies.
final class HandoffController {
    enum State: Equatable {
        case idle
        case releasing
        case waitingForRelease
        case acquiring
        case owned
        case failed
    }

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// True once a handoff cycle cannot reach the devices. An idle Magic peripheral
    /// answers pages again after a click, or after a power cycle if it was released.
    var onDevicesUnreachableChange: ((Bool) -> Void)?
    private(set) var devicesUnreachable = false {
        didSet {
            guard devicesUnreachable != oldValue else { return }
            onDevicesUnreachableChange?(devicesUnreachable)
        }
    }

    private let bluetooth: BluetoothControlling
    private let peers: PeerCoordinating
    private let addresses: () -> [String]
    private var operationID = UUID()
    private var retryWorkItem: DispatchWorkItem?
    private let retryDelays: [TimeInterval]
    private let recoveryDelay: TimeInterval
    private let maximumRecoveryDelay: TimeInterval
    private let unreachableAfterFailedCycles: Int
    private var failedCycles = 0
    private let now: () -> Date
    private let sleepRetentionGrace: TimeInterval
    private let acquisitionSettleDelay: TimeInterval
    private var desiredOwnership: Bool?
    private var ownershipEstablishedAt: Date?

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String],
         retryDelays: [TimeInterval] = [2, 5],
         recoveryDelay: TimeInterval = 5,
         maximumRecoveryDelay: TimeInterval = 15,
         unreachableAfterFailedCycles: Int = 1,
         now: @escaping () -> Date = Date.init,
         sleepRetentionGrace: TimeInterval = 10,
         acquisitionSettleDelay: TimeInterval = 0) {
        self.bluetooth = bluetooth
        self.peers = peers
        self.addresses = addresses
        self.retryDelays = retryDelays
        self.recoveryDelay = recoveryDelay
        self.maximumRecoveryDelay = maximumRecoveryDelay
        self.unreachableAfterFailedCycles = unreachableAfterFailedCycles
        self.now = now
        self.sleepRetentionGrace = sleepRetentionGrace
        self.acquisitionSettleDelay = acquisitionSettleDelay
    }

    func ownershipChanged(isActive: Bool) {
        guard desiredOwnership != isActive else {
            Diagnostics.record("duplicate ownership=\(isActive) ignored")
            return
        }
        desiredOwnership = isActive
        resetRecovery(clearUnreachable: !isActive)
        beginOwnershipChange(isActive: isActive)
    }

    /// Wake and manual retries restart the backoff but keep the unreachable hint
    /// until the devices actually connect.
    func retryOwnership(isActive: Bool) {
        desiredOwnership = isActive
        resetRecovery(clearUnreachable: !isActive)
        beginOwnershipChange(isActive: isActive)
    }

    private func resetRecovery(clearUnreachable: Bool) {
        failedCycles = 0
        if clearUnreachable { devicesUnreachable = false }
    }

    /// Reconciles native Bluetooth connection notifications with the handoff state.
    /// A reconnect can complete recovery without waiting for the next timer, while a
    /// disconnect from a stable owner starts the existing bounded recovery loop.
    func selectedDevicesConnectivityChanged(allConnected: Bool) {
        guard desiredOwnership == true, !addresses().isEmpty else { return }

        if allConnected {
            guard state != .owned else { return }
            retryWorkItem?.cancel()
            bluetooth.cancelPendingOperations()
            operationID = UUID()
            ownershipEstablishedAt = now()
            resetRecovery(clearUnreachable: true)
            Diagnostics.record("selected devices connected; ownership recovered automatically")
            state = .owned
            return
        }

        guard state == .owned else { return }
        operationID = UUID()
        ownershipEstablishedAt = nil
        state = .failed
        Diagnostics.record("selected device disconnected while trigger is active; scheduling recovery")
        scheduleAutomaticRecovery(for: operationID)
    }

    private func beginOwnershipChange(isActive: Bool) {
        retryWorkItem?.cancel()
        bluetooth.cancelPendingOperations()
        operationID = UUID()
        let targets = addresses()
        guard !targets.isEmpty else {
            state = .idle
            return
        }

        guard isActive else {
            ownershipEstablishedAt = nil
            releaseIfPeerWants(targets, context: "trigger inactive", operation: operationID) {}
            return
        }

        let currentOperation = operationID
        state = .waitingForRelease
        Diagnostics.record("trigger active; requesting peer release for \(targets.count) device(s)")
        peers.requestRelease(of: targets) { [weak self] released in
            guard let self, self.operationID == currentOperation else { return }
            Diagnostics.record("peer release acknowledged=\(released)")
            if !released {
                log.warning("Handoff: a peer did not acknowledge release; attempting acquisition")
            }
            guard self.acquisitionSettleDelay > 0 else {
                self.acquire(targets, operation: currentOperation, attempt: 0)
                return
            }

            Diagnostics.record(
                "release request finished; waiting \(self.acquisitionSettleDelay)s for Bluetooth to settle"
            )
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.operationID == currentOperation else { return }
                self.acquire(targets, operation: currentOperation, attempt: 0)
            }
            self.retryWorkItem = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + self.acquisitionSettleDelay, execute: work
            )
        }
    }

    private func acquire(_ targets: [String], operation: UUID, attempt: Int) {
        guard operationID == operation else { return }
        state = .acquiring
        Diagnostics.record("acquisition attempt \(attempt + 1)")
        bluetooth.acquire(targets) { [weak self] success in
            guard let self, self.operationID == operation else { return }
            if success {
                Diagnostics.record("acquisition succeeded")
                self.ownershipEstablishedAt = self.now()
                self.resetRecovery(clearUnreachable: true)
                self.state = .owned
            } else if attempt < self.retryDelays.count {
                let delay = self.retryDelays[attempt]
                Diagnostics.record("acquisition failed; retrying in \(Int(delay))s")
                let work = DispatchWorkItem { [weak self] in
                    self?.acquire(targets, operation: operation, attempt: attempt + 1)
                }
                self.retryWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                Diagnostics.record("acquisition failed after \(attempt + 1) attempts")
                self.ownershipEstablishedAt = nil
                self.failedCycles += 1
                if self.failedCycles >= self.unreachableAfterFailedCycles, !self.devicesUnreachable {
                    Diagnostics.record(
                        "devices unreachable after \(self.failedCycles) handoff cycle(s); asking user to click or power-cycle them"
                    )
                    self.devicesUnreachable = true
                }
                self.state = .failed
                self.scheduleAutomaticRecovery(for: operation)
            }
        }
    }

    private func scheduleAutomaticRecovery(for operation: UUID) {
        guard desiredOwnership == true else { return }
        let backoff = pow(2, Double(max(failedCycles - 1, 0)))
        let delay = min(recoveryDelay * backoff, maximumRecoveryDelay)
        Diagnostics.record("automatic recovery scheduled in \(Int(delay))s")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == operation,
                  self.desiredOwnership == true else { return }
            Diagnostics.record("automatic recovery restarting handoff")
            self.beginOwnershipChange(isActive: true)
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func prepareForSleep(isOwnershipActive: Bool = false,
                         isExternallyPowered: Bool? = nil,
                         completion: @escaping () -> Void) {
        let acquisitionInProgress = state == .waitingForRelease || state == .acquiring
        let ownershipAge = ownershipEstablishedAt.map { now().timeIntervalSince($0) }
        let recentlyAcquired = ownershipAge.map { $0 < sleepRetentionGrace } == true
        let shouldRetain: Bool
        switch isExternallyPowered {
        case true?: shouldRetain = true
        case false?: shouldRetain = false
        case nil: shouldRetain = acquisitionInProgress || recentlyAcquired
        }
        guard !(isOwnershipActive && shouldRetain) else {
            let reason: String
            if isExternallyPowered == true {
                reason = "external power is still connected"
            } else if acquisitionInProgress {
                reason = "acquisition is in progress"
            } else if recentlyAcquired {
                reason = "ownership was established \(Int(ownershipAge ?? 0))s ago"
            } else {
                reason = "ownership remains local"
            }
            Diagnostics.record("sleep announced while trigger is active; retaining devices because \(reason)")
            completion()
            return
        }
        if isOwnershipActive {
            let reason = isExternallyPowered == false ? "battery power" : "unconfirmed dock power"
            Diagnostics.record("sleep announced with \(reason); checking whether a trusted Mac wants the devices")
        }
        retryWorkItem?.cancel()
        bluetooth.cancelPendingOperations()
        operationID = UUID()
        ownershipEstablishedAt = nil
        resetRecovery(clearUnreachable: true)
        let targets = addresses()
        guard !targets.isEmpty else { completion(); return }
        releaseIfPeerWants(targets, context: "pre-sleep", operation: operationID, completion: completion)
    }

    /// Hands retained devices to a peer that wants them, e.g. when a peer reappears on
    /// the network while this Mac is in a background wake. Never interrupts work in flight.
    func peersChanged() {
        guard desiredOwnership == false, state == .idle else { return }
        let targets = addresses()
        guard !targets.isEmpty else { return }
        releaseIfPeerWants(targets, context: "peer update", operation: operationID) {}
    }

    /// Releasing with no Mac ready to claim the devices strands Magic peripherals:
    /// unpaired and idle, they stop answering pages until power-cycled. A retained
    /// bond instead reconnects on a click. So release proactively only when a trusted
    /// peer's trigger is active; otherwise keep the bond and let a peer's release
    /// request, or a later wake, hand the devices over.
    private func releaseIfPeerWants(_ targets: [String], context: String, operation: UUID,
                                    completion: @escaping () -> Void) {
        peers.peerWantsDevices { [weak self] wanted in
            guard let self, self.operationID == operation else { completion(); return }
            guard wanted else {
                Diagnostics.record("\(context): no trusted Mac wants \(targets.count) device(s); keeping them paired")
                self.state = .idle
                completion()
                return
            }
            Diagnostics.record("\(context): a trusted Mac wants \(targets.count) device(s); releasing")
            self.state = .releasing
            self.bluetooth.release(targets) { [weak self] success in
                Diagnostics.record("\(context) release \(success ? "succeeded" : "failed")")
                if let self, self.operationID == operation {
                    self.state = success ? .idle : .failed
                }
                completion()
            }
        }
    }

    func releaseForPeer(_ addresses: [String], isOwnershipActive: Bool,
                        completion: @escaping (Bool) -> Void) {
        guard !isOwnershipActive else {
            Diagnostics.record("peer release refused because local ownership trigger is active")
            completion(false)
            return
        }
        retryWorkItem?.cancel()
        bluetooth.cancelPendingOperations()
        operationID = UUID() // cancel a local acquisition before releasing
        ownershipEstablishedAt = nil
        resetRecovery(clearUnreachable: true)
        bluetooth.release(addresses, completion: completion)
        state = .idle
    }
}

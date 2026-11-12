import Foundation

protocol PeerCoordinating: AnyObject {
    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void)
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

    /// True once repeated handoff cycles cannot reach the devices. A released Magic
    /// peripheral that idles without a host stops answering pages until it is
    /// turned off and on, so retries alone cannot recover it.
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
    private let isLidOpen: () -> Bool
    private var desiredOwnership: Bool?
    private var ownershipEstablishedAt: Date?

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String],
         retryDelays: [TimeInterval] = [2, 5],
         recoveryDelay: TimeInterval = 5,
         maximumRecoveryDelay: TimeInterval = 60,
         unreachableAfterFailedCycles: Int = 2,
         now: @escaping () -> Date = Date.init,
         sleepRetentionGrace: TimeInterval = 10,
         acquisitionSettleDelay: TimeInterval = 0,
         isLidOpen: @escaping () -> Bool = { false }) {
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
        self.isLidOpen = isLidOpen
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
            // An open-lid Mac stays awake and reachable, so it can release when a
            // peer asks or before it sleeps. Removing the bond now would leave an
            // unclaimed Magic peripheral unpaired until it deep-sleeps and stops
            // answering pages, which then requires a manual power cycle.
            guard !isLidOpen() else {
                Diagnostics.record(
                    "trigger inactive with lid open; retaining \(targets.count) device(s) until a peer requests release or this Mac sleeps"
                )
                state = .idle
                return
            }
            // The dock may provide the losing Mac's network and power while its
            // lid is closed. Release immediately, before detach puts it to sleep;
            // the destination's peer request is only a secondary safety net.
            let currentOperation = operationID
            state = .releasing
            Diagnostics.record("trigger inactive; releasing \(targets.count) device(s)")
            bluetooth.release(targets) { [weak self] success in
                guard let self, self.operationID == currentOperation else { return }
                self.state = success ? .idle : .failed
            }
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
                        "devices unreachable after \(self.failedCycles) handoff cycles; asking user to power-cycle them"
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
            Diagnostics.record("sleep announced with \(reason); releasing before sleep despite active trigger")
        }
        retryWorkItem?.cancel()
        bluetooth.cancelPendingOperations()
        operationID = UUID()
        ownershipEstablishedAt = nil
        resetRecovery(clearUnreachable: true)
        let targets = addresses()
        guard !targets.isEmpty else { completion(); return }
        state = .releasing
        bluetooth.release(targets) { [weak self] success in
            Diagnostics.record("pre-sleep release \(success ? "succeeded" : "failed")")
            self?.state = success ? .idle : .failed
            completion()
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

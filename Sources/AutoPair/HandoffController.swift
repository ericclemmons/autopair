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

    private let bluetooth: BluetoothControlling
    private let peers: PeerCoordinating
    private let addresses: () -> [String]
    private var operationID = UUID()
    private var retryWorkItem: DispatchWorkItem?
    private let retryDelays: [TimeInterval]
    private let recoveryDelay: TimeInterval
    private let now: () -> Date
    private let sleepRetentionGrace: TimeInterval
    private let acquisitionSettleDelay: TimeInterval
    private var desiredOwnership: Bool?
    private var ownershipEstablishedAt: Date?

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String],
         retryDelays: [TimeInterval] = [2, 5],
         recoveryDelay: TimeInterval = 5,
         now: @escaping () -> Date = Date.init,
         sleepRetentionGrace: TimeInterval = 10,
         acquisitionSettleDelay: TimeInterval = 0) {
        self.bluetooth = bluetooth
        self.peers = peers
        self.addresses = addresses
        self.retryDelays = retryDelays
        self.recoveryDelay = recoveryDelay
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
        beginOwnershipChange(isActive: isActive)
    }

    func retryOwnership(isActive: Bool) {
        desiredOwnership = isActive
        beginOwnershipChange(isActive: isActive)
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
            // The dock may provide the losing Mac's network and power while its
            // lid is closed. Release immediately, before detach puts it to sleep;
            // the destination's peer request is only a secondary safety net.
            let currentOperation = operationID
            ownershipEstablishedAt = nil
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
            guard released, self.acquisitionSettleDelay > 0 else {
                self.acquire(targets, operation: currentOperation, attempt: 0)
                return
            }

            Diagnostics.record(
                "peer released; waiting \(self.acquisitionSettleDelay)s for Bluetooth to settle"
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
                self.state = .failed
                self.scheduleAutomaticRecovery(for: operation)
            }
        }
    }

    private func scheduleAutomaticRecovery(for operation: UUID) {
        guard desiredOwnership == true else { return }
        Diagnostics.record("automatic recovery scheduled in \(Int(recoveryDelay))s")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == operation,
                  self.desiredOwnership == true else { return }
            Diagnostics.record("automatic recovery restarting handoff")
            self.beginOwnershipChange(isActive: true)
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + recoveryDelay, execute: work)
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
        bluetooth.release(addresses, completion: completion)
        state = .idle
    }
}

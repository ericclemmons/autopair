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
    private let now: () -> Date
    private let sleepRetentionGrace: TimeInterval
    private var desiredOwnership: Bool?
    private var ownershipEstablishedAt: Date?

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String],
         retryDelays: [TimeInterval] = [2, 5],
         now: @escaping () -> Date = Date.init,
         sleepRetentionGrace: TimeInterval = 10) {
        self.bluetooth = bluetooth
        self.peers = peers
        self.addresses = addresses
        self.retryDelays = retryDelays
        self.now = now
        self.sleepRetentionGrace = sleepRetentionGrace
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
            self.acquire(targets, operation: currentOperation, attempt: 0)
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
            }
        }
    }

    func prepareForSleep(isOwnershipActive: Bool = false, completion: @escaping () -> Void) {
        let acquisitionInProgress = state == .waitingForRelease || state == .acquiring
        let ownershipAge = ownershipEstablishedAt.map { now().timeIntervalSince($0) }
        let recentlyAcquired = ownershipAge.map { $0 < sleepRetentionGrace } == true
        guard !(isOwnershipActive && (acquisitionInProgress || recentlyAcquired)) else {
            let reason = acquisitionInProgress ? "acquisition is in progress" :
                "ownership was established \(Int(ownershipAge ?? 0))s ago"
            Diagnostics.record("sleep announced while trigger is active; retaining devices because \(reason)")
            completion()
            return
        }
        if isOwnershipActive {
            Diagnostics.record("sleep announced for stable owner; releasing before sleep despite active trigger")
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

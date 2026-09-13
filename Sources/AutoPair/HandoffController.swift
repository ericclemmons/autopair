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

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String],
         retryDelays: [TimeInterval] = [2, 5, 10, 15]) {
        self.bluetooth = bluetooth
        self.peers = peers
        self.addresses = addresses
        self.retryDelays = retryDelays
    }

    func ownershipChanged(isActive: Bool) {
        retryWorkItem?.cancel()
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
                self.state = .failed
            }
        }
    }

    func prepareForSleep(isOwnershipActive: Bool = false, completion: @escaping () -> Void) {
        guard !isOwnershipActive else {
            Diagnostics.record("sleep announced while ownership trigger is active; retaining devices")
            completion()
            return
        }
        retryWorkItem?.cancel()
        operationID = UUID()
        let targets = addresses()
        guard !targets.isEmpty else { completion(); return }
        state = .releasing
        bluetooth.release(targets) { [weak self] success in
            Diagnostics.record("pre-sleep release \(success ? "succeeded" : "failed")")
            self?.state = success ? .idle : .failed
            completion()
        }
    }

    func releaseForPeer(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        retryWorkItem?.cancel()
        operationID = UUID() // cancel a local acquisition before releasing
        bluetooth.release(addresses, completion: completion)
        state = .idle
    }
}

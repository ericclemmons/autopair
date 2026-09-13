import Foundation

protocol PeerCoordinating: AnyObject {
    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void)
}

/// Coordinates the ordered release -> acquire transaction. Trigger monitors,
/// peer transport, and Bluetooth are deliberately separate dependencies.
final class HandoffController {
    enum State: Equatable {
        case idle
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

    init(bluetooth: BluetoothControlling, peers: PeerCoordinating,
         addresses: @escaping () -> [String]) {
        self.bluetooth = bluetooth
        self.peers = peers
        self.addresses = addresses
    }

    func ownershipChanged(isActive: Bool) {
        operationID = UUID()
        guard isActive else {
            state = .idle
            return
        }
        let targets = addresses()
        guard !targets.isEmpty else {
            state = .idle
            return
        }

        let currentOperation = operationID
        state = .waitingForRelease
        peers.requestRelease(of: targets) { [weak self] released in
            guard let self, self.operationID == currentOperation else { return }
            if !released {
                log.warning("Handoff: a peer did not acknowledge release; attempting acquisition")
            }
            self.state = .acquiring
            self.bluetooth.acquire(targets) { [weak self] success in
                guard let self, self.operationID == currentOperation else { return }
                self.state = success ? .owned : .failed
            }
        }
    }

    func releaseForPeer(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        operationID = UUID() // cancel a local acquisition before releasing
        bluetooth.release(addresses, completion: completion)
        state = .idle
    }
}

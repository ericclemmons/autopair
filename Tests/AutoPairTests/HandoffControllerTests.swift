import XCTest
@testable import AutoPair

final class HandoffControllerTests: XCTestCase {
    func testActiveTriggerWaitsForPeerReleaseBeforeAcquire() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers,
            addresses: { ["AA:BB"] }
        )

        controller.ownershipChanged(isActive: true)

        XCTAssertEqual(controller.state, .waitingForRelease)
        XCTAssertEqual(peers.requested, [["AA:BB"]])
        XCTAssertTrue(bluetooth.acquired.isEmpty)

        peers.releaseCompletion?(true)
        XCTAssertEqual(controller.state, .acquiring)
        XCTAssertEqual(bluetooth.acquired, [["AA:BB"]])

        bluetooth.acquireCompletion?(true)
        XCTAssertEqual(controller.state, .owned)
    }

    func testInactiveTriggerNeverReleasesDevicesIndependently() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })

        controller.ownershipChanged(isActive: false)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(bluetooth.released.isEmpty)
        XCTAssertTrue(peers.requested.isEmpty)
    }

    func testDeactivationCancelsPendingAcquisition() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })

        controller.ownershipChanged(isActive: true)
        controller.ownershipChanged(isActive: false)
        peers.releaseCompletion?(true)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(bluetooth.acquired.isEmpty)
    }

    func testPeerReleaseUsesBluetoothAndAcknowledgesResult() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { [] })
        var result: Bool?

        controller.releaseForPeer(["AA"], completion: { result = $0 })
        XCTAssertEqual(bluetooth.released, [["AA"]])
        bluetooth.releaseCompletion?(true)

        XCTAssertEqual(result, true)
    }
}

private final class BluetoothMock: BluetoothControlling {
    var acquired: [[String]] = []
    var released: [[String]] = []
    var acquireCompletion: ((Bool) -> Void)?
    var releaseCompletion: ((Bool) -> Void)?

    func acquire(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        acquired.append(addresses)
        acquireCompletion = completion
    }

    func release(_ addresses: [String], completion: @escaping (Bool) -> Void) {
        released.append(addresses)
        releaseCompletion = completion
    }
}

private final class PeerMock: PeerCoordinating {
    var requested: [[String]] = []
    var releaseCompletion: ((Bool) -> Void)?

    func requestRelease(of addresses: [String], completion: @escaping (Bool) -> Void) {
        requested.append(addresses)
        releaseCompletion = completion
    }
}

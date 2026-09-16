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

    func testInactiveTriggerProactivelyReleasesBeforeClosedLidMacSleeps() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })

        controller.ownershipChanged(isActive: false)

        XCTAssertEqual(controller.state, .releasing)
        XCTAssertEqual(bluetooth.released, [["AA"]])
        XCTAssertTrue(peers.requested.isEmpty)

        bluetooth.releaseCompletion?(true)
        XCTAssertEqual(controller.state, .idle)
    }

    func testDeactivationCancelsPendingAcquisition() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })

        controller.ownershipChanged(isActive: true)
        controller.ownershipChanged(isActive: false)
        peers.releaseCompletion?(true)

        XCTAssertEqual(controller.state, .releasing)
        XCTAssertTrue(bluetooth.acquired.isEmpty)
    }

    func testPeerReleaseUsesBluetoothAndAcknowledgesResult() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { [] })
        var result: Bool?

        controller.releaseForPeer(["AA"], isOwnershipActive: false, completion: { result = $0 })
        XCTAssertEqual(bluetooth.released, [["AA"]])
        bluetooth.releaseCompletion?(true)

        XCTAssertEqual(result, true)
    }

    func testDuplicateActiveSignalDoesNotRestartHandoff() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })

        controller.ownershipChanged(isActive: true)
        controller.ownershipChanged(isActive: true)

        XCTAssertEqual(peers.requested, [["AA"]])
        XCTAssertEqual(bluetooth.cancellationCount, 1)
    }

    func testPeerCannotReleaseWhileLocalOwnershipTriggerIsActive() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })
        var result: Bool?

        controller.releaseForPeer(["AA"], isOwnershipActive: true) { result = $0 }

        XCTAssertEqual(result, false)
        XCTAssertTrue(bluetooth.released.isEmpty)
    }

    func testWillSleepWaitsForBluetoothReleaseBeforeAcknowledging() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })
        var acknowledged = false

        controller.prepareForSleep { acknowledged = true }

        XCTAssertEqual(controller.state, .releasing)
        XCTAssertEqual(bluetooth.released, [["AA"]])
        XCTAssertFalse(acknowledged)
        bluetooth.releaseCompletion?(true)
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(controller.state, .idle)
    }

    func testWillSleepRetainsDevicesDuringFreshClamshellAcquisition() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(bluetooth: bluetooth, peers: peers, addresses: { ["AA"] })
        var acknowledged = false

        controller.ownershipChanged(isActive: true)
        controller.prepareForSleep(
            isOwnershipActive: true, isExternallyPowered: false
        ) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertTrue(bluetooth.released.isEmpty)
    }

    func testWillSleepRetainsDevicesImmediatelyAfterClamshellAcquisition() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] },
            now: { now }, sleepRetentionGrace: 10
        )
        var acknowledged = false

        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(true)
        bluetooth.acquireCompletion?(true)
        now.addTimeInterval(9)
        controller.prepareForSleep(isOwnershipActive: true) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(controller.state, .owned)
        XCTAssertTrue(bluetooth.released.isEmpty)
    }

    func testWillSleepReleasesStableOwnerEvenWhenDisplayStillReportsActive() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] },
            now: { now }, sleepRetentionGrace: 10
        )
        var acknowledged = false

        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(true)
        bluetooth.acquireCompletion?(true)
        now.addTimeInterval(11)
        controller.prepareForSleep(isOwnershipActive: true) { acknowledged = true }

        XCTAssertEqual(controller.state, .releasing)
        XCTAssertEqual(bluetooth.released, [["AA"]])
        XCTAssertFalse(acknowledged)
        bluetooth.releaseCompletion?(true)
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(controller.state, .idle)
    }

    func testWillSleepRetainsStableOwnerWhileDockStillProvidesPower() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        var now = Date(timeIntervalSince1970: 1_000)
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] },
            now: { now }, sleepRetentionGrace: 10
        )
        var acknowledged = false

        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(true)
        bluetooth.acquireCompletion?(true)
        now.addTimeInterval(11)
        controller.prepareForSleep(
            isOwnershipActive: true, isExternallyPowered: true
        ) { acknowledged = true }

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(controller.state, .owned)
        XCTAssertTrue(bluetooth.released.isEmpty)
    }

    func testFailedAcquisitionRetriesWhileOwnershipRemainsActive() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] }, retryDelays: [0]
        )
        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(false)
        bluetooth.acquireCompletion?(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(bluetooth.acquired, [["AA"], ["AA"]])
        bluetooth.acquireCompletion?(true)
        XCTAssertEqual(controller.state, .owned)
    }

    func testFailedAcquisitionStartsANewHandoffCycleWhileTriggerRemainsActive() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] },
            retryDelays: [], recoveryDelay: 0
        )

        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(false)
        bluetooth.acquireCompletion?(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(peers.requested, [["AA"], ["AA"]])
        XCTAssertEqual(controller.state, .waitingForRelease)
        peers.releaseCompletion?(true)
        bluetooth.acquireCompletion?(true)
        XCTAssertEqual(controller.state, .owned)
    }

    func testOwnershipLossCancelsScheduledAutomaticRecovery() {
        let bluetooth = BluetoothMock()
        let peers = PeerMock()
        let controller = HandoffController(
            bluetooth: bluetooth, peers: peers, addresses: { ["AA"] },
            retryDelays: [], recoveryDelay: 0.05
        )

        controller.ownershipChanged(isActive: true)
        peers.releaseCompletion?(false)
        bluetooth.acquireCompletion?(false)
        controller.ownershipChanged(isActive: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(peers.requested, [["AA"]])
        XCTAssertEqual(bluetooth.released, [["AA"]])
    }
}

private final class BluetoothMock: BluetoothControlling {
    var cancellationCount = 0
    var acquired: [[String]] = []
    var released: [[String]] = []
    var acquireCompletion: ((Bool) -> Void)?
    var releaseCompletion: ((Bool) -> Void)?

    func cancelPendingOperations() { cancellationCount += 1 }

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

import IOBluetooth
import XCTest
@testable import AutoPair

final class BluetoothPairingVerifierTests: XCTestCase {
    func testTransientConnectedStateDoesNotCompletePendingPairing() {
        let verifier = BluetoothPairingVerifier()

        XCTAssertEqual(
            verifier.observe(
                pairingResult: nil, isPaired: true
            ),
            .observing
        )
        XCTAssertEqual(
            verifier.observe(
                pairingResult: nil, isPaired: false
            ),
            .observing
        )
    }

    func testCompletedPairingDoesNotRequireImmediateWirelessConnection() {
        let verifier = BluetoothPairingVerifier()

        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true
            ),
            .succeeded
        )
    }

    func testConnectionMustRemainStableBeforeAcquisitionSucceeds() {
        var verifier = BluetoothConnectionVerifier(stabilityInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(verifier.observe(isConnected: true, at: start))
        XCTAssertFalse(verifier.observe(isConnected: false, at: start.addingTimeInterval(0.75)))
        XCTAssertFalse(verifier.observe(isConnected: true, at: start.addingTimeInterval(1.25)))
        XCTAssertTrue(verifier.observe(isConnected: true, at: start.addingTimeInterval(2.25)))
    }

    func testPairingDelegateFailureFailsImmediately() {
        let verifier = BluetoothPairingVerifier()

        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnError, isPaired: true
            ),
            .failed
        )
    }

    func testConnectionTimeoutRetainsExistingPairingForLaterRetry() {
        let result = BluetoothConnectionResult.failure(for: kIOReturnTimeout)

        XCTAssertEqual(result, .unavailable)
        XCTAssertFalse(result.shouldReplacePairing)
    }

    func testNonTimeoutConnectionFailureCanReplaceStalePairing() {
        let result = BluetoothConnectionResult.failure(for: kIOReturnError)

        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(result.shouldReplacePairing)
    }

    func testWiredPairingTraceEstablishesBondWithoutReplacingItAfterTimeout() {
        let pairing = BluetoothPairingVerifier().observe(
            pairingResult: kIOReturnSuccess, isPaired: true
        )
        let connection = BluetoothConnectionResult.failure(for: kIOReturnTimeout)

        XCTAssertEqual(pairing, .succeeded)
        XCTAssertEqual(connection, .unavailable)
        XCTAssertFalse(connection.shouldReplacePairing)
    }
}

import IOBluetooth
import XCTest
@testable import AutoPair

final class BluetoothPairingVerifierTests: XCTestCase {
    func testTransientConnectedStateDoesNotCompletePendingPairing() {
        var verifier = BluetoothPairingVerifier(stabilityInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            verifier.observe(
                pairingResult: nil, isPaired: true, isConnected: true, at: start
            ),
            .observing
        )
        XCTAssertEqual(
            verifier.observe(
                pairingResult: nil, isPaired: false, isConnected: false,
                at: start.addingTimeInterval(1)
            ),
            .observing
        )
    }

    func testCompletedPairingMustRemainPairedAndConnected() {
        var verifier = BluetoothPairingVerifier(stabilityInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true, at: start
            ),
            .observing
        )
        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true,
                at: start.addingTimeInterval(0.9)
            ),
            .observing
        )
        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true,
                at: start.addingTimeInterval(1)
            ),
            .succeeded
        )
    }

    func testDisconnectResetsStabilityWindow() {
        var verifier = BluetoothPairingVerifier(stabilityInterval: 1)
        let start = Date(timeIntervalSince1970: 1_000)

        _ = verifier.observe(
            pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true, at: start
        )
        _ = verifier.observe(
            pairingResult: kIOReturnSuccess, isPaired: true, isConnected: false,
            at: start.addingTimeInterval(0.75)
        )

        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true,
                at: start.addingTimeInterval(1.25)
            ),
            .observing
        )
        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnSuccess, isPaired: true, isConnected: true,
                at: start.addingTimeInterval(2.25)
            ),
            .succeeded
        )
    }

    func testPairingDelegateFailureFailsImmediately() {
        var verifier = BluetoothPairingVerifier(stabilityInterval: 1)

        XCTAssertEqual(
            verifier.observe(
                pairingResult: kIOReturnError, isPaired: true, isConnected: true, at: Date()
            ),
            .failed
        )
    }
}

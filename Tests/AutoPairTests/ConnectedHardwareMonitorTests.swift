import XCTest
@testable import AutoPair

final class ConnectedHardwareMonitorTests: XCTestCase {
    func testSerialNumberIsStrongestIdentity() {
        let selected = hardware(serial: "ABC", productID: 1)
        XCTAssertTrue(selected.matches(hardware(serial: "ABC", productID: 99)))
        XCTAssertFalse(selected.matches(hardware(serial: "XYZ", productID: 1)))
    }

    func testVendorAndProductMatchWithoutSerial() {
        let selected = hardware(serial: nil, productID: 10)
        XCTAssertTrue(selected.matches(hardware(serial: nil, productID: 10)))
        XCTAssertFalse(selected.matches(hardware(serial: nil, productID: 11)))
    }

    func testDifferentTransportDoesNotMatch() {
        let selected = hardware(serial: nil, productID: 10)
        let candidate = HardwareIdentity(
            transport: .thunderbolt, vendorID: 0x2188, productID: 10,
            vendorName: "CalDigit", productName: "Dock", serialNumber: nil
        )
        XCTAssertFalse(selected.matches(candidate))
    }

    func testVendorLevelChoiceMatchesAnyProductFromVendor() {
        let selected = HardwareIdentity(
            transport: .usb, vendorID: 0x2188, productID: nil,
            vendorName: "CalDigit", productName: "CalDigit connected hardware",
            serialNumber: nil
        )
        XCTAssertTrue(selected.matches(hardware(serial: nil, productID: 10)))
        XCTAssertTrue(selected.matches(hardware(serial: nil, productID: 11)))
    }

    private func hardware(serial: String?, productID: Int) -> HardwareIdentity {
        HardwareIdentity(
            transport: .usb, vendorID: 0x2188, productID: productID,
            vendorName: "CalDigit", productName: "Dock", serialNumber: serial
        )
    }
}

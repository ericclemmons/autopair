import XCTest
@testable import AutoPair

final class CalDigitDockMonitorTests: XCTestCase {
    func testMatchesOfficialCalDigitVendorID() {
        XCTAssertTrue(CalDigitDockMonitor.matches(.init(
            registryID: 1, vendorID: 0x2188, vendorName: nil, productName: "USB Hub"
        )))
    }

    func testMatchesCalDigitManufacturerWhenVendorIDIsBridged() {
        XCTAssertTrue(CalDigitDockMonitor.matches(.init(
            registryID: 1, vendorID: 0x05ac, vendorName: "CalDigit, Inc.", productName: "TS4"
        )))
    }

    func testDoesNotMatchUnrelatedDock() {
        XCTAssertFalse(CalDigitDockMonitor.matches(.init(
            registryID: 1, vendorID: 0x05ac, vendorName: "Apple Inc.", productName: "USB Hub"
        )))
    }
}

import IOBluetooth
import XCTest
@testable import AutoPair

final class DeviceSelectionTests: XCTestCase {
    func testLastSeenHintUsesHumanRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(
            LastSeenFormatter.string(
                lastSeenAt: now.addingTimeInterval(-3 * 86_400), isConnected: false, now: now
            ),
            "3 days ago"
        )
        XCTAssertEqual(
            LastSeenFormatter.string(lastSeenAt: nil, isConnected: false, now: now),
            "Unknown"
        )
        XCTAssertEqual(
            LastSeenFormatter.string(lastSeenAt: nil, isConnected: true, now: now),
            "Now"
        )
    }

    func testSavedAddressWithoutMetadataRemainsVisibleForRemoval() {
        let address = "AA-BB-CC-DD-EE-FF"

        let devices = DeviceSelection.menuDevices(
            addresses: [address], liveDevices: [], savedInfo: [:]
        )

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].address, address)
        XCTAssertEqual(devices[0].name, "Unknown Saved Device")
    }

    func testLiveDeviceTakesPrecedenceOverSavedMetadata() {
        let address = "AA-BB-CC-DD-EE-FF"
        let live = BluetoothDevice(
            address: address, name: "Live Trackpad",
            majorClass: BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral),
            minorClass: BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorPeripheral1Pointing)
        )
        let saved = SavedDeviceInfo(
            address: address, name: "Old Name",
            majorClass: UInt32(kBluetoothDeviceClassMajorPeripheral),
            minorClass: UInt32(kBluetoothDeviceClassMinorPeripheral1Pointing)
        )

        let devices = DeviceSelection.menuDevices(
            addresses: [address], liveDevices: [live], savedInfo: [address: saved]
        )

        XCTAssertEqual(devices.map(\.name), ["Live Trackpad"])
    }
}

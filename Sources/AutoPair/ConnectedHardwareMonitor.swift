import Foundation
import IOKit

struct HardwareIdentity: Codable, Hashable {
    enum Transport: String, Codable { case usb, thunderbolt }

    let transport: Transport
    let vendorID: Int?
    let productID: Int?
    let vendorName: String
    let productName: String
    let serialNumber: String?

    var title: String {
        let vendor = vendorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let product = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        if product.localizedCaseInsensitiveContains(vendor), !product.isEmpty { return product }
        return [vendor, product].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    func matches(_ candidate: HardwareIdentity) -> Bool {
        guard transport == candidate.transport else { return false }
        if let serialNumber, !serialNumber.isEmpty {
            return serialNumber == candidate.serialNumber
        }
        if let vendorID, let productID {
            return vendorID == candidate.vendorID && productID == candidate.productID
        }
        if let vendorID { return vendorID == candidate.vendorID }
        return vendorName.caseInsensitiveCompare(candidate.vendorName) == .orderedSame
            && productName.caseInsensitiveCompare(candidate.productName) == .orderedSame
    }
}

enum HardwareRegistry {
    static let serviceClasses: [(String, HardwareIdentity.Transport)] = [
        ("IOUSBHostDevice", .usb),
        ("IOThunderboltDevice", .thunderbolt),
    ]

    static func attachedHardware() -> [HardwareIdentity] {
        var devices: Set<HardwareIdentity> = []
        for (serviceClass, transport) in serviceClasses {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                if let identity = identity(for: service, transport: transport), isMeaningful(identity) {
                    devices.insert(identity)
                }
            }
        }
        var choices = devices
        let groups = Dictionary(grouping: devices) { "\($0.transport.rawValue)|\($0.vendorID ?? -1)|\($0.vendorName)" }
        for group in groups.values where group.count > 1 {
            guard let first = group.first, !first.vendorName.isEmpty else { continue }
            choices.insert(HardwareIdentity(
                transport: first.transport, vendorID: first.vendorID, productID: nil,
                vendorName: first.vendorName,
                productName: "\(first.vendorName) connected hardware", serialNumber: nil
            ))
        }
        return choices.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func identity(for service: io_service_t,
                         transport: HardwareIdentity.Transport) -> HardwareIdentity? {
        func property(_ keys: [String]) -> AnyObject? {
            for key in keys {
                if let value = IORegistryEntryCreateCFProperty(
                    service, key as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() { return value }
            }
            return nil
        }
        var entryName = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &entryName)
        let registryName = String(cString: entryName)
        let vendorName = property(["USB Vendor Name", "kUSBVendorString", "Vendor Name", "vendor-name"])
            as? String ?? ""
        let productName = property(["USB Product Name", "kUSBProductString", "Device Name", "device-name"])
            as? String ?? registryName
        guard !productName.isEmpty else { return nil }
        return HardwareIdentity(
            transport: transport,
            vendorID: (property(["idVendor", "vendor-id"]) as? NSNumber)?.intValue,
            productID: (property(["idProduct", "device-id"]) as? NSNumber)?.intValue,
            vendorName: vendorName,
            productName: productName,
            serialNumber: property(["USB Serial Number", "kUSBSerialNumberString", "Serial Number"])
                as? String
        )
    }

    static func isMeaningful(_ identity: HardwareIdentity) -> Bool {
        let title = identity.title.lowercased()
        guard !title.isEmpty else { return false }
        let generic = ["root hub", "host controller", "appleusb", "thunderbolt bus"]
        return !generic.contains { title.contains($0) }
    }
}

final class ConnectedHardwareMonitor: OwnershipTrigger {
    let kind: OwnershipTriggerKind = .connectedHardware
    let identity: HardwareIdentity
    var onChange: ((Bool, String?) -> Void)?

    private(set) var matchingRegistryIDs: Set<UInt64> = []
    private var notificationPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(identity: HardwareIdentity) { self.identity = identity }

    var isActive: Bool { !matchingRegistryIDs.isEmpty }
    var activeName: String? { isActive ? identity.title : nil }

    func start() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()

        for (serviceClass, transport) in HardwareRegistry.serviceClasses where transport == identity.transport {
            for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                let callback: IOServiceMatchingCallback = notification == kIOFirstMatchNotification
                    ? hardwareAdded : hardwareRemoved
                let result = IOServiceAddMatchingNotification(
                    port, notification, IOServiceMatching(serviceClass), callback,
                    context, &iterator
                )
                guard result == KERN_SUCCESS else { continue }
                iterators.append(iterator)
                drain(iterator, added: notification == kIOFirstMatchNotification)
            }
        }
        log.info("ConnectedHardwareMonitor: \(self.identity.title), active=\(self.isActive)")
    }

    func stop() {
        iterators.forEach { IOObjectRelease($0) }
        iterators = []
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        matchingRegistryIDs = []
    }

    fileprivate func drain(_ iterator: io_iterator_t, added: Bool) {
        let wasActive = isActive
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            if added {
                if HardwareRegistry.identity(for: service, transport: identity.transport)
                    .map(identity.matches) == true {
                    matchingRegistryIDs.insert(registryID)
                }
            } else {
                matchingRegistryIDs.remove(registryID)
            }
        }
        if wasActive != isActive {
            Diagnostics.record("hardware trigger \(identity.title) is \(isActive ? "active" : "inactive")")
            onChange?(isActive, activeName)
        }
    }

    deinit { stop() }
}

private func hardwareAdded(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<ConnectedHardwareMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .drain(iterator, added: true)
}

private func hardwareRemoved(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<ConnectedHardwareMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .drain(iterator, added: false)
}

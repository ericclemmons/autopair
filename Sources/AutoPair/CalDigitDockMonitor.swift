import Foundation
import IOKit

/// Event-driven CalDigit detection. Matching IOUSBHostDevice means a dock is
/// observed even when its display is off or connected through another output.
final class CalDigitDockMonitor: OwnershipTrigger {
    let kind: OwnershipTriggerKind = .calDigitDock
    var onChange: ((Bool, String?) -> Void)?

    private(set) var attachedRegistryIDs: Set<UInt64> = []
    private var namesByRegistryID: [UInt64: String] = [:]
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    var isActive: Bool { !attachedRegistryIDs.isEmpty }
    var activeName: String? { namesByRegistryID.values.sorted().first }

    func start() {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            log.error("CalDigitDockMonitor: could not create IOKit notification port")
            return
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)

        let context = Unmanaged.passUnretained(self).toOpaque()
        let addResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification,
            IOServiceMatching("IOUSBHostDevice"), dockAdded, context, &addedIterator
        )
        let removeResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification,
            IOServiceMatching("IOUSBHostDevice"), dockRemoved, context, &removedIterator
        )
        guard addResult == KERN_SUCCESS, removeResult == KERN_SUCCESS else {
            log.error("CalDigitDockMonitor: could not register IOKit notifications")
            stop()
            return
        }

        drainAdded(addedIterator) // arms notification and seeds state
        drainRemoved(removedIterator)
        log.info("CalDigitDockMonitor: initialized, attached=\(self.attachedRegistryIDs.count)")
    }

    func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notificationPort { IONotificationPortDestroy(port) }
        notificationPort = nil
    }

    fileprivate func drainAdded(_ iterator: io_iterator_t) {
        let wasActive = isActive
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let identity = Self.identity(for: service), Self.matches(identity) else { continue }
            attachedRegistryIDs.insert(identity.registryID)
            namesByRegistryID[identity.registryID] = identity.productName ?? "CalDigit Dock"
        }
        publishIfNeeded(previouslyActive: wasActive)
    }

    fileprivate func drainRemoved(_ iterator: io_iterator_t) {
        let wasActive = isActive
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            attachedRegistryIDs.remove(registryID)
            namesByRegistryID.removeValue(forKey: registryID)
        }
        publishIfNeeded(previouslyActive: wasActive)
    }

    private func publishIfNeeded(previouslyActive: Bool) {
        guard previouslyActive != isActive else { return }
        log.info("CalDigitDockMonitor: active=\(self.isActive), device=\(self.activeName ?? "none")")
        onChange?(isActive, activeName)
    }

    struct USBIdentity: Equatable {
        let registryID: UInt64
        let vendorID: Int?
        let vendorName: String?
        let productName: String?
    }

    static func matches(_ identity: USBIdentity) -> Bool {
        if identity.vendorID == 0x2188 { return true }
        let text = [identity.vendorName, identity.productName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("caldigit")
    }

    private static func identity(for service: io_service_t) -> USBIdentity? {
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { return nil }

        func property(_ key: String) -> AnyObject? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        }
        let vendorID = (property("idVendor") as? NSNumber)?.intValue
        let vendorName = (property("USB Vendor Name") as? String)
            ?? (property("kUSBVendorString") as? String)
        let productName = (property("USB Product Name") as? String)
            ?? (property("kUSBProductString") as? String)
        return USBIdentity(registryID: registryID, vendorID: vendorID,
                           vendorName: vendorName, productName: productName)
    }

    deinit { stop() }
}

private func dockAdded(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<CalDigitDockMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .drainAdded(iterator)
}

private func dockRemoved(_ refcon: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let refcon else { return }
    Unmanaged<CalDigitDockMonitor>.fromOpaque(refcon).takeUnretainedValue()
        .drainRemoved(iterator)
}

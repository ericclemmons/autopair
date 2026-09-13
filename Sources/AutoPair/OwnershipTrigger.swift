import Foundation

enum OwnershipTriggerKind: String, CaseIterable, Identifiable {
    case externalDisplay
    case connectedHardware

    var id: String { rawValue }

    var title: String {
        switch self {
        case .externalDisplay: "External Display"
        case .connectedHardware: "Connected Hardware"
        }
    }

    var inactiveTitle: String {
        switch self {
        case .externalDisplay: "No external display"
        case .connectedHardware: "Selected hardware disconnected"
        }
    }
}

/// A physical signal that decides whether this Mac should own the saved devices.
/// Implementations publish transitions; Bluetooth handoff remains independent of
/// the concrete signal so new triggers can be added without changing it.
protocol OwnershipTrigger: AnyObject {
    var kind: OwnershipTriggerKind { get }
    var isActive: Bool { get }
    var activeName: String? { get }
    var onChange: ((Bool, String?) -> Void)? { get set }
    func start()
    func stop()
}

enum OwnershipTriggerFactory {
    static func make(_ kind: OwnershipTriggerKind,
                     hardware: HardwareIdentity? = nil) -> OwnershipTrigger? {
        switch kind {
        case .externalDisplay: DisplayMonitor()
        case .connectedHardware:
            hardware.map(ConnectedHardwareMonitor.init)
        }
    }
}

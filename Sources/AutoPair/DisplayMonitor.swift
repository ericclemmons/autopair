import AppKit
import CoreGraphics

/// Tracks online external displays from CoreGraphics. The CG callback is the
/// authoritative event source; AppKit remains a fallback for session changes.
final class DisplayMonitor: OwnershipTrigger {
    let kind: OwnershipTriggerKind = .externalDisplay
    var onChange: ((Bool, String?) -> Void)?

    private var previousExternalIDs: Set<CGDirectDisplayID> = []
    private var started = false
    private var reconcileWorkItem: DispatchWorkItem?

    init() {
        previousExternalIDs = Self.externalDisplayIDs()
        Diagnostics.record(Self.snapshotDescription(prefix: "display monitor initialized"))
    }

    var isActive: Bool { !previousExternalIDs.isEmpty }
    var activeName: String? {
        firstExternalDisplayName() ?? (isActive ? "External display" : nil)
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigured, Unmanaged.passUnretained(self).toOpaque()
        )
        scheduleReconciliation(reason: "start")
    }

    func stop() {
        guard started else { return }
        started = false
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigured, Unmanaged.passUnretained(self).toOpaque()
        )
    }

    @objc private func screensChanged() {
        scheduleReconciliation(reason: "AppKit screen parameters changed")
    }

    fileprivate func displayConfigurationChanged(
        id: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags
    ) {
        scheduleReconciliation(reason: "CoreGraphics display \(id) flags=\(flags.rawValue)")
    }

    private func scheduleReconciliation(reason: String) {
        reconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile(reason: reason) }
        reconcileWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func reconcile(reason: String) {
        let wasActive = isActive
        previousExternalIDs = Self.externalDisplayIDs()
        Diagnostics.record(Self.snapshotDescription(prefix: reason))
        guard wasActive != isActive else { return }
        Diagnostics.record("display trigger is \(isActive ? "active" : "inactive")")
        onChange?(isActive, activeName)
    }

    private func firstExternalDisplayName() -> String? {
        NSScreen.screens.first { screen in
            guard let id = Self.displayID(for: screen) else { return false }
            return previousExternalIDs.contains(id)
        }?.localizedName
    }

    private static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func externalDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(onlineDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 })
    }

    private static func snapshotDescription(prefix: String) -> String {
        let displays = onlineDisplayIDs().map {
            "\($0):builtin=\(CGDisplayIsBuiltin($0)),online=\(CGDisplayIsOnline($0)),active=\(CGDisplayIsActive($0))"
        }.joined(separator: ",")
        return "\(prefix); displays=[\(displays)]"
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    deinit { stop() }
}

private func displayReconfigured(_ display: CGDirectDisplayID,
                                 _ flags: CGDisplayChangeSummaryFlags,
                                 _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DisplayMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.displayConfigurationChanged(id: display, flags: flags)
    }
}

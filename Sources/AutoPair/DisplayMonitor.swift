import AppKit
import CoreGraphics

final class DisplayMonitor: OwnershipTrigger {
    let kind: OwnershipTriggerKind = .externalDisplay
    var onChange: ((Bool, String?) -> Void)?

    private var previousExternalIDs: Set<CGDirectDisplayID> = []

    init() {
        previousExternalIDs = externalDisplayIDs()
        log.info("DisplayMonitor: initialized, external=\(self.previousExternalIDs.count)")
    }

    var isActive: Bool { !previousExternalIDs.isEmpty }

    var activeName: String? {
        firstExternalDisplayName()
    }

    func start() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screensChanged() {
        let wasActive = isActive
        let current = externalDisplayIDs()
        let added = current.subtracting(previousExternalIDs)
        let removed = previousExternalIDs.subtracting(current)
        previousExternalIDs = current

        if (!removed.isEmpty || !added.isEmpty), wasActive != isActive {
            let name = firstExternalDisplayName()
            log.info("DisplayMonitor: active=\(self.isActive), display=\(name ?? "none")")
            onChange?(isActive, name)
        }
    }

    private func firstExternalDisplayName() -> String? {
        NSScreen.screens.first { screen in
            guard let id = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }?.localizedName
    }

    private func externalDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            guard let id = displayID(for: screen), CGDisplayIsBuiltin(id) == 0 else { return nil }
            return id
        })
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(num.uint32Value)
    }

    deinit {
        stop()
    }
}

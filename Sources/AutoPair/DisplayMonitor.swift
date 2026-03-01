import AppKit
import CoreGraphics

final class DisplayMonitor {
    var onDisplayConnected: ((String) -> Void)?
    var onDisplayDisconnected: (() -> Void)?

    private var previousExternalIDs: Set<CGDirectDisplayID> = []

    init() {
        previousExternalIDs = externalDisplayIDs()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        log.info("DisplayMonitor: initialized, external=\(self.previousExternalIDs.count)")
    }

    var currentDisplayName: String? {
        firstExternalDisplayName()
    }

    @objc private func screensChanged() {
        let current = externalDisplayIDs()
        let added = current.subtracting(previousExternalIDs)
        let removed = previousExternalIDs.subtracting(current)
        previousExternalIDs = current

        if !removed.isEmpty {
            log.info("DisplayMonitor: external display removed")
            onDisplayDisconnected?()
        }
        if !added.isEmpty {
            let name = firstExternalDisplayName() ?? "External Display"
            log.info("DisplayMonitor: external display connected: \(name)")
            onDisplayConnected?(name)
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
        NotificationCenter.default.removeObserver(self)
    }
}

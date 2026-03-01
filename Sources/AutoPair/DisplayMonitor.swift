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
        NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) == 0
        })?.localizedName
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
            let name = NSScreen.screens.first(where: {
                guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                return added.contains(id)
            })?.localizedName ?? "External Display"
            log.info("DisplayMonitor: external display connected: \(name)")
            onDisplayConnected?(name)
        }
    }

    private func externalDisplayIDs() -> Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) == 0 else { return nil }
            return id
        })
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
